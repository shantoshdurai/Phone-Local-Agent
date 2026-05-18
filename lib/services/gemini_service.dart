import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_generative_ai/google_generative_ai.dart';

import 'agent_response.dart';
import 'agent_mode.dart';
import 'database_service.dart';
import 'tool_runtime.dart';

/// Cloud-mode agent. Mirrors the surface of [AgentService] (initialize,
/// loadSession, sendMessage, stopGeneration, statusStream, tokenStream) so
/// the chat UI can swap between the two without caring which backend is live.
class GeminiService {
  static final GeminiService _instance = GeminiService._internal();
  factory GeminiService() => _instance;
  GeminiService._internal();

  static const String modelName = 'Gemini 2.5 Flash';
  static const String _modelId = 'gemini-2.5-flash';

  final DatabaseService _dbService = DatabaseService();
  final ToolRuntime _tools = ToolRuntime.instance;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _tokenStreamController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenStreamController.stream;

  GenerativeModel? _model;
  ChatSession? _chat;
  String? _apiKey;
  bool _stopRequested = false;

  bool get isReady => _model != null && _chat != null;

  Future<void> initialize() async {
    final key = await AgentModeStore.readApiKey();
    if (key == null) {
      throw StateError('No Gemini API key configured.');
    }
    // Re-init if the key changed since last boot.
    if (_model != null && _apiKey == key) {
      _statusController.add('');
      return;
    }
    _apiKey = key;
    _model = GenerativeModel(
      model: _modelId,
      apiKey: key,
      systemInstruction: Content.system(_systemPrompt),
      tools: [Tool(functionDeclarations: _functionDeclarations())],
      generationConfig: GenerationConfig(
        temperature: 0.7,
        maxOutputTokens: 1024,
      ),
    );
    _chat = _model!.startChat();
    _statusController.add('');
  }

  Future<void> loadSession(int sessionId) async {
    if (_model == null) return;
    final history = await _dbService.getChatHistory(sessionId);
    final replay = <Content>[];
    for (final msg in history) {
      final role = msg['role'] as String;
      final text = (msg['content'] as String?)?.trim() ?? '';
      if (text.isEmpty) continue;
      if (role == 'user') {
        replay.add(Content.text(text));
      } else if (role == 'assistant') {
        replay.add(Content.model([TextPart(text)]));
      }
    }
    _chat = _model!.startChat(history: replay);
  }

  Future<void> stopGeneration() async {
    _stopRequested = true;
    _statusController.add('');
  }

  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
  }) async {
    if (_chat == null) throw Exception('Gemini not initialized');
    _statusController.add('Thinking...');
    _stopRequested = false;

    final parts = <Part>[];
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final Uint8List bytes = await File(imagePath).readAsBytes();
        parts.add(DataPart(_mimeFromPath(imagePath), bytes));
      } catch (_) {
        // fall through to text-only
      }
    }
    parts.add(TextPart(text));

    final userMessage = Content('user', parts);
    final result = await _runWithTools(userMessage, sessionId);

    _statusController.add('');
    return result;
  }

  /// Send one Content into the chat, stream text out token-by-chunk, and if
  /// the model emits a function call, execute it and re-enter with the
  /// tool response. Returns the final assistant turn.
  Future<AgentResponse> _runWithTools(Content message, int sessionId) async {
    String fullText = '';
    bool streamStarted = false;
    FunctionCall? toolCall;
    int tokenCount = 0;
    final startTime = DateTime.now();
    String? toolNameForReturn;

    try {
      await for (final chunk in _chat!.sendMessageStream(message)) {
        if (_stopRequested) break;

        final calls = chunk.functionCalls.toList();
        if (calls.isNotEmpty) {
          // The chat session has already appended this model turn to history,
          // so just capture the first call and exit the loop.
          toolCall = calls.first;
          if (streamStarted) {
            _tokenStreamController.add('\x02');
            streamStarted = false;
          }
          fullText = '';
          break;
        }

        final t = chunk.text;
        if (t == null || t.isEmpty) continue;
        if (!streamStarted) {
          streamStarted = true;
          _tokenStreamController.add('\x00');
        }
        fullText += t;
        tokenCount += t.length ~/ 4; // rough chars→tokens estimate for TPS
        _tokenStreamController.add(t);
      }
    } on GenerativeAIException catch (e) {
      if (streamStarted) {
        _tokenStreamController.add('\x02');
        streamStarted = false;
      }
      final friendly = _friendly(e);
      await _dbService.saveMessage('assistant', friendly, sessionId);
      return AgentResponse(friendly, modelName, 0);
    } catch (e) {
      if (streamStarted) {
        _tokenStreamController.add('\x02');
        streamStarted = false;
      }
      final friendly = 'Cloud request failed: ${e.toString()}';
      await _dbService.saveMessage('assistant', friendly, sessionId);
      return AgentResponse(friendly, modelName, 0);
    }

    final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;
    final double tps = evalTimeMs > 0 && tokenCount > 0
        ? tokenCount / (evalTimeMs / 1000.0)
        : 0;

    if (streamStarted) {
      _tokenStreamController.add('\x01');
    }

    if (_stopRequested) {
      final partial = fullText.trim();
      final stoppedText = partial.isEmpty ? '[Stopped]' : partial;
      await _dbService.saveMessage('assistant', stoppedText, sessionId);
      return AgentResponse(stoppedText, modelName, 0,
          tps: tps, evalTime: evalTimeMs / 1000.0);
    }

    if (toolCall != null) {
      toolNameForReturn = toolCall.name;
      _statusController.add('Running ${toolCall.name}...');
      final args = Map<String, dynamic>.from(toolCall.args);
      final toolResult = await _tools.execute(toolCall.name, args);

      // Direct templated reply for trivial tools — skip the model summary
      // round-trip but still feed the result into chat history so multi-turn
      // stays coherent.
      final direct = _tools.formatDirect(toolCall.name, args, toolResult);
      if (direct != null) {
        // Append the function response to history without streaming.
        try {
          await _chat!.sendMessage(
              Content.functionResponse(toolCall.name, toolResult));
        } catch (_) {
          // History append failed (network blip etc.) — we still have the
          // direct reply, so just surface that.
        }
        await _dbService.saveMessage('assistant', direct, sessionId);
        return AgentResponse(direct, modelName, 0,
            tps: tps,
            evalTime: evalTimeMs / 1000.0,
            toolName: toolNameForReturn);
      }

      // Complex tool — re-enter with the function response and let Gemini
      // summarize naturally.
      _statusController.add('Summarizing...');
      final followUp = await _runWithTools(
        Content.functionResponse(toolCall.name, toolResult),
        sessionId,
      );
      return AgentResponse(
        followUp.text,
        modelName,
        0,
        tps: followUp.tps ?? tps,
        evalTime: followUp.evalTime ?? evalTimeMs / 1000.0,
        toolName: toolNameForReturn,
      );
    }

    final trimmed = fullText.trim();
    final finalText = trimmed.isEmpty
        ? "Gemini returned an empty response. Try rephrasing."
        : trimmed;
    await _dbService.saveMessage('assistant', finalText, sessionId);
    return AgentResponse(finalText, modelName, 0,
        tps: tps, evalTime: evalTimeMs / 1000.0);
  }

String _mimeFromPath(String path) {
    final ext = path.toLowerCase().split('.').last;
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'gif':
        return 'image/gif';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  String _friendly(GenerativeAIException e) {
    final m = e.message;
    if (m.contains('API key') || m.contains('400')) {
      return 'Your Gemini API key was rejected. Check it in Settings.';
    }
    if (m.contains('quota') || m.contains('429')) {
      return 'Gemini rate-limited that request. Free tier resets daily; try again shortly.';
    }
    if (m.contains('SAFETY') || m.contains('blocked')) {
      return 'Gemini blocked that response for safety reasons. Try rephrasing.';
    }
    return 'Gemini error: $m';
  }

  // ─── Function declarations (translated from kToolCatalog) ───

  List<FunctionDeclaration> _functionDeclarations() {
    return kToolCatalog.map((entry) {
      final params = entry['parameters'] as Map<String, dynamic>;
      return FunctionDeclaration(
        entry['name'] as String,
        entry['description'] as String,
        _schemaFor(params),
      );
    }).toList();
  }

  Schema? _schemaFor(Map<String, dynamic> spec) {
    final type = spec['type'] as String?;
    final description = spec['description'] as String?;
    switch (type) {
      case 'object':
        final props =
            (spec['properties'] as Map<String, dynamic>? ?? const {});
        if (props.isEmpty) return null;
        final required = (spec['required'] as List?)?.cast<String>();
        return Schema.object(
          properties: props.map((k, v) =>
              MapEntry(k, _schemaFor(v as Map<String, dynamic>)!)),
          requiredProperties: required,
          description: description,
        );
      case 'string':
        return Schema.string(description: description);
      case 'integer':
        return Schema.integer(description: description);
      case 'number':
        return Schema.number(description: description);
      case 'boolean':
        return Schema.boolean(description: description);
      default:
        return Schema.string(description: description);
    }
  }

  static const String _systemPrompt = '''
You are Local Agent — an on-device-style AI assistant running through the Gemini API for the user's Android phone. You have function tools for device control, app launching, files, contacts, calendar, web search, and clipboard.

Behavior:
- For any actionable request (turn flashlight on, open an app, vibrate, set volume, list files, search the web, look up a contact, schedule something), CALL THE MATCHING TOOL. Do not say "I'll do that" — emit the call.
- After a tool returns, summarize the result in one or two short sentences.
- Chain tools when a request needs more than one step. Example: "message Sarah on WhatsApp" → search_contacts("Sarah") → send_whatsapp(<number>, message).
- For greetings, definitions, and general knowledge already in your training, reply directly without a tool — one or two sentences.

Hard rules:
- NEVER fabricate phone numbers, emails, contact names, file paths, or app package names. If a lookup returns nothing, say so honestly.
- When the user asks what to uninstall or by app size, use list_apps and present name + sizeMB, biggest first.
- When opening an app by display name, prefer launch_app_by_name over guessing a package name.
- Stay concise. The user is on a phone screen.
''';
}
