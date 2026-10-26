import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../agent_response.dart';
import '../database_service.dart';
import '../memory_service.dart';
import '../tool_runtime.dart';
import 'provider_config.dart';
import 'remote_agent.dart';

class _ToolCall {
  String id;
  String name;
  final StringBuffer arguments = StringBuffer();

  _ToolCall({required this.id, required this.name});

  Map<String, dynamic>? get parsedArgs {
    final raw = arguments.toString().trim();
    if (raw.isEmpty) return const {};
    // Models occasionally wrap JSON in markdown fences.
    final cleaned = raw
        .replaceAll(RegExp(r'^```(?:json)?', multiLine: true), '')
        .replaceAll('```', '')
        .trim();
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }
}

class _Completion {
  final String text;
  final List<_ToolCall> toolCalls;
  final String? finishReason;
  const _Completion(this.text, this.toolCalls, this.finishReason);
}

class _ApiError implements Exception {
  final int status;
  final String message;

  /// The provider refused the *model* (403/404, or "model does not support
  /// tools"), not the key. Worth retrying with the next model in the chain.
  final bool modelLevel;

  const _ApiError(this.status, this.message, {this.modelLevel = false});

  bool get retryable => status == 429 || status >= 500;

  @override
  String toString() => message;
}

/// OpenAI-compatible chat client with streaming and tool calling.
///
/// Works with Groq, DeepSeek, OpenRouter, Ollama, vLLM and anything else that
/// implements `POST /chat/completions` with `tools`. The important details for
/// reliable tool use:
///
/// - `tool_calls` arrive as **deltas**: each chunk carries a fragment of
///   `function.arguments`, keyed by `index`. They are reassembled before
///   execution; parsing a single chunk would give truncated JSON.
/// - The loop is multi-hop (up to [_maxToolHops]). A model may call
///   `search_contacts` and then `send_whatsapp`; the intermediate results are
///   appended as `role: tool` messages with the matching `tool_call_id`.
/// - Some models emit a JSON tool call as *text* instead of a tool call. That
///   is recovered once per turn, because a silently unexecuted tool is the
///   single most common "the API model ignored my tools" failure.
/// - 429/5xx are retried only when nothing has been emitted yet, so the user
///   never sees a duplicated half-answer.
class OpenAiCompatibleService implements RemoteAgent {
  OpenAiCompatibleService(this._config) {
    _models = _config.modelChain;
  }

  final ProviderConfig _config;

  /// Models to try, primary first. The index only moves forward when the
  /// provider says this account cannot use the current model — once a working
  /// model is found it is remembered for the rest of the session.
  late final List<String> _models;
  int _modelIndex = 0;

  final DatabaseService _db = DatabaseService();

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<String> _tokenStreamController =
      StreamController<String>.broadcast();

  @override
  Stream<String> get statusStream => _statusController.stream;

  @override
  Stream<String> get tokenStream => _tokenStreamController.stream;

  @override
  bool get isReady => _config.apiKey.isNotEmpty && _config.baseUrl.isNotEmpty;

  @override
  String get activeModelLabel => _models[_modelIndex];

  /// True when this turn rides on the shared demo key (quota applies).
  bool get isDemo => _config.isDemo;

  @override
  bool get supportsVision => _config.provider == LlmProvider.openrouter;

  /// DeepSeek's vision model on OpenRouter. Used transparently when an image
  /// is attached and the active model is text-only.
  static const String _visionModel = 'deepseek/deepseek-v4-flash-vision-exp';

  final List<Map<String, dynamic>> _history = [];

  bool _stopRequested = false;
  http.Client? _activeClient;

  static const int _maxToolHops = 4;
  static const int _maxHistoryMessages = 20;
  // Kept short on purpose: a phone answer should be 1–2 sentences, and a
  // smaller budget cuts the tail latency the user actually feels.
  static const int _maxOutputTokens = 512;

  @override
  Future<void> initialize() async {
    if (_config.apiKey.isEmpty) {
      throw StateError(
        'No API key for ${_config.label}. Add one in Settings → AI provider.',
      );
    }
    if (_config.baseUrl.isEmpty) {
      throw StateError('No endpoint configured for ${_config.label}.');
    }
    _history.clear();
    _statusController.add('');
  }

  @override
  Future<void> loadSession(int sessionId) async {
    _history.clear();
    try {
      final rows = await _db.getChatHistory(sessionId);
      for (final row in rows) {
        final role = row['role'] as String?;
        final content = (row['content'] as String?)?.trim() ?? '';
        if (content.isEmpty) continue;
        if (role == 'user' || role == 'assistant') {
          _history.add({'role': role, 'content': content});
        }
      }
    } catch (_) {}
    if (_history.length > _maxHistoryMessages) {
      _history.removeRange(0, _history.length - _maxHistoryMessages);
    }
  }

  @override
  Future<void> stopGeneration() async {
    _stopRequested = true;
    try {
      _activeClient?.close();
    } catch (_) {}
    _statusController.add('');
  }

  @override
  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
    String? forceTool,
  }) async {
    if (!isReady) {
      throw StateError('${_config.label} is not configured.');
    }

    if (_config.isDemo) {
      final allowed = await ProviderStore.consumeDemoUse();
      if (!allowed) {
        final msg = 'The shared demo key is used up for today '
            '(${ProviderStore.demoDailyLimit} messages). Add your own '
            '${_config.label} key in Settings → AI provider to keep going.';
        await _db.saveMessage('assistant', msg, sessionId);
        return AgentResponse(msg, activeModelLabel, 0);
      }
    }

    _stopRequested = false;
    _statusController.add('Thinking...');

    final memory = await MemoryService.instance.promptBlock();
    final system = memory.isEmpty ? _systemPrompt : '$_systemPrompt\n\n$memory';

    // Vision: OpenRouter exposes DeepSeek's vision model. If the user attached
    // an image while on a text model, this request transparently uses the
    // vision variant instead of pretending the image was not there.
    final bool hasImage = imagePath != null && imagePath.isNotEmpty;
    Map<String, dynamic>? imagePart;
    String? visionModel;
    if (hasImage) {
      imagePart = await _imagePart(imagePath);
      if (imagePart != null &&
          _config.provider == LlmProvider.openrouter &&
          !activeModelLabel.contains('vision')) {
        visionModel = _visionModel;
      }
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
      ..._history,
      {
        'role': 'user',
        'content': imagePart != null
            ? [
                {'type': 'text', 'text': text},
                imagePart,
              ]
            : (hasImage
                ? '$text\n\n[The attached image could not be read. Ask the user '
                    'to re-share it.]'
                : text),
      },
    ];

    final started = DateTime.now();
    var totalChars = 0;
    var recoveredCall = false;

    try {
      for (var hop = 0; hop < _maxToolHops; hop++) {
        final completion = await _streamCompletion(
          messages,
          modelOverride: visionModel,
          forceTool: hop == 0 ? forceTool : null,
        );
        totalChars += completion.text.length;

        if (_stopRequested) {
          final partial = completion.text.trim();
          final stopped = partial.isEmpty ? '[Stopped]' : partial;
          await _db.saveMessage('assistant', stopped, sessionId);
          return AgentResponse(stopped, activeModelLabel, 0);
        }

        var calls = completion.toolCalls;

        // Recovery: model printed a JSON tool call instead of using the API.
        if (calls.isEmpty && !recoveredCall) {
          recoveredCall = true;
          final recovered = _recoverToolCall(completion.text);
          if (recovered != null) calls = [recovered];
        }

        if (calls.isEmpty) {
          final finalText = completion.text.trim();
          final answer = finalText.isEmpty
              ? 'The model returned an empty response. Try rephrasing.'
              : finalText;
          _history.add({'role': 'user', 'content': text});
          _history.add({'role': 'assistant', 'content': answer});
          await _db.saveMessage('assistant', answer, sessionId);
          final elapsed = DateTime.now().difference(started).inMilliseconds;
          return AgentResponse(
            answer,
            activeModelLabel,
            0,
            tps: elapsed > 0 ? (totalChars / 4) / (elapsed / 1000.0) : 0,
            evalTime: elapsed / 1000.0,
          );
        }

        // From here on the turn is a tool turn: tell the UI to clear any
        // half-streamed preamble so it doesn't sit next to the final answer.
        if (completion.text.trim().isNotEmpty) {
          _tokenStreamController.add('\x02');
        }

        messages.add({
          'role': 'assistant',
          'content': completion.text.trim().isEmpty
              ? null
              : completion.text.trim(),
          'tool_calls': calls
              .map((c) => {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': c.arguments.toString().isEmpty
                          ? '{}'
                          : c.arguments.toString(),
                    },
                  })
              .toList(),
        });

        for (final call in calls) {
          final args = call.parsedArgs;
          if (args == null) {
            messages.add({
              'role': 'tool',
              'tool_call_id': call.id,
              'name': call.name,
              'content': jsonEncode({
                'error': 'Arguments were not valid JSON. Call the tool again '
                    'with a single JSON object.'
              }),
            });
            continue;
          }

          _statusController.add('Running ${call.name}...');
          final result = await ToolRuntime.instance.execute(call.name, args);
          messages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'name': call.name,
            'content': jsonEncode(result),
          });
        }
        _statusController.add('Thinking...');
      }

      const guard = 'I stopped after several tool steps to avoid a loop. '
          'Ask me again with a narrower request.';
      await _db.saveMessage('assistant', guard, sessionId);
      return AgentResponse(guard, activeModelLabel, 0);
    } on RemoteUnavailable {
      // Handled one level up: AgentService may retry on another configured
      // provider, or turn it into a normal assistant message.
      rethrow;
    } catch (e) {
      final friendly = 'Request failed: $e';
      await _db.saveMessage('assistant', friendly, sessionId);
      return AgentResponse(friendly, activeModelLabel, 0);
    } finally {
      _activeClient = null;
      _statusController.add('');
    }
  }

  // ── Streaming ───────────────────────────────────────────────────────────

  Future<_Completion> _streamCompletion(
    List<Map<String, dynamic>> messages, {
    String? modelOverride,
    String? forceTool,
  }) async {
    var transientAttempts = 0;
    while (true) {
      try {
        return await _streamOnce(messages, modelOverride, forceTool);
      } on _ApiError catch (e) {
        // The account cannot use this model (Groq returns 403 with an empty
        // body for models outside the plan). Move down the chain once.
        if (e.modelLevel && _modelIndex + 1 < _models.length) {
          _modelIndex++;
          _statusController.add('Trying ${_models[_modelIndex]}…');
          continue;
        }
        // Rate limit or server hiccup on the same model.
        if (e.retryable && transientAttempts < 2) {
          transientAttempts++;
          await Future.delayed(
              Duration(milliseconds: 500 * transientAttempts));
          continue;
        }
        // Still rate-limited: another model may have its own quota.
        if (e.status == 429 && _modelIndex + 1 < _models.length) {
          _modelIndex++;
          transientAttempts = 0;
          _statusController.add('Rate limited — trying ${_models[_modelIndex]}…');
          continue;
        }
        throw RemoteUnavailable(
          _friendlyError(e),
          authFailure: e.status == 401,
        );
      }
    }
  }

  Future<_Completion> _streamOnce(
      List<Map<String, dynamic>> messages, String? modelOverride,
      String? forceTool) async {
    final uri = Uri.parse(_endpoint());
    final model = modelOverride ?? _models[_modelIndex];
    final allTools = _toolsPayload();
    final tools = forceTool == null
        ? allTools
        : allTools
            .where((t) =>
                (t['function'] as Map<String, dynamic>)['name'] == forceTool)
            .toList();
    final payload = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'temperature': 0.3,
      'max_tokens': _maxOutputTokens,
      'tools': tools,
      // "Search" toggle: force the web tool on the first hop, then go back to
      // auto for the summary hop.
      'tool_choice': forceTool == null ? 'auto' : 'required',
    };

    // Measured against a live Groq key: gpt-oss streams chain-of-thought
    // before acting, and `reasoning_effort: low` cut time-to-tool-call from
    // ~814ms to ~217ms with the same tool choice. Other providers reject the
    // field, so it is only sent where it is known to work.
    if (_config.provider == LlmProvider.groq && model.contains('gpt-oss')) {
      payload['reasoning_effort'] = 'low';
    }

    final client = http.Client();
    _activeClient = client;

    final http.StreamedResponse response;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(_headers(stream: true))
        ..body = jsonEncode(payload);
      response = await client.send(request);
    } catch (e) {
      client.close();
      throw _ApiError(0, 'Could not reach ${_config.label}: $e');
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      client.close();
      final lower = body.toLowerCase();
      final status = response.statusCode;
      // 403 with an empty body is what Groq returns for a model outside the
      // account's plan; 404 is a bad id; some providers use 400 for both.
      final modelLevel = status == 403 ||
          status == 404 ||
          (status == 400 &&
              (lower.contains('model') ||
                  lower.contains('tool') ||
                  lower.contains('decommission')));
      throw _ApiError(
        status,
        _extractError(body),
        modelLevel: modelLevel,
      );
    }

    final text = StringBuffer();
    final calls = <int, _ToolCall>{};
    String? finishReason;
    var buffer = '';

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      if (_stopRequested) {
        client.close();
        break;
      }
      buffer += chunk;
      var newline = buffer.indexOf('\n');
      while (newline >= 0) {
        final line = buffer.substring(0, newline).trim();
        buffer = buffer.substring(newline + 1);
        newline = buffer.indexOf('\n');

        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;

        Map<String, dynamic> json;
        try {
          final decoded = jsonDecode(data);
          if (decoded is! Map) continue;
          json = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue; // keep-alive or provider-specific noise
        }

        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map) continue;
        finishReason = choice['finish_reason']?.toString() ?? finishReason;

        final delta = choice['delta'];
        if (delta is! Map) continue;

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          if (text.isEmpty) _tokenStreamController.add('\x00');
          text.write(content);
          _tokenStreamController.add(content);
        }

        final rawCalls = delta['tool_calls'];
        if (rawCalls is List) {
          for (final raw in rawCalls) {
            if (raw is! Map) continue;
            final index = (raw['index'] as num?)?.toInt() ?? calls.length;
            final builder = calls.putIfAbsent(
              index,
              () => _ToolCall(
                id: raw['id']?.toString() ?? 'call_$index',
                name: '',
              ),
            );
            if (raw['id'] != null) builder.id = raw['id'].toString();
            final fn = raw['function'];
            if (fn is Map) {
              // `name` is sent whole on the first delta; overwrite rather than
              // append so a repeated name can't become "search_websearch_web".
              if (fn['name'] != null) builder.name = fn['name'].toString();
              final args = fn['arguments'];
              if (args is String) builder.arguments.write(args);
            }
          }
        }
      }
    }

    client.close();
    _activeClient = null;

    return _Completion(
      text.toString(),
      calls.values.where((c) => c.name.isNotEmpty).toList(),
      finishReason,
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Encode a local image as an OpenAI-style content part. Returns null when
  /// the file is missing or too large to send economically.
  Future<Map<String, dynamic>?> _imagePart(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      // Base64 inflates by ~33%; keep the request under ~5 MB.
      if (bytes.length > 4 * 1024 * 1024) return null;
      final lower = path.toLowerCase();
      final mime = lower.endsWith('.png')
          ? 'image/png'
          : lower.endsWith('.webp')
              ? 'image/webp'
              : lower.endsWith('.gif')
                  ? 'image/gif'
                  : 'image/jpeg';
      return {
        'type': 'image_url',
        'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers({bool stream = false}) => {        'Authorization': 'Bearer ${_config.apiKey}',
        'Content-Type': 'application/json',
        if (stream) 'Accept': 'text/event-stream',
        // OpenRouter uses these for attribution/rate-limit tiers.
        if (_config.provider == LlmProvider.openrouter) ...{
          'HTTP-Referer': 'https://localagent.app',
          'X-Title': 'Agent',
        },
      };

  /// Silent capability probe, run once per session right after connecting.
  ///
  /// Sends the smallest possible request that proves the model can emit a
  /// native tool call (`get_date_time` is free and has no arguments). This is
  /// the check that would have caught the "provider ignores tools" class of
  /// failure before the user ever typed anything.
  ///
  /// It costs a few dozen tokens, is not shown in the chat, and only surfaces
  /// a small warning strip if it fails.
  bool? _toolsWork;
  bool? get toolsWork => _toolsWork;

  Future<bool> probeToolCalling() async {
    for (final choice in ['required', 'auto']) {
      try {
        final payload = <String, dynamic>{
          'model': _models[_modelIndex],
          'messages': [
            {
              'role': 'system',
              'content': 'Call the provided tool. Do not answer with text.',
            },
            {'role': 'user', 'content': 'Call get_date_time now.'},
          ],
          'tools': [
            {
              'type': 'function',
              'function': {
                'name': 'get_date_time',
                'description': 'Get the current date and time.',
                'parameters': {'type': 'object', 'properties': {}},
              },
            },
          ],
          'tool_choice': choice,
          'max_tokens': 48,
          'temperature': 0,
          'stream': false,
        };
        final response = await http
            .post(
              Uri.parse(_endpoint()),
              headers: _headers(),
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode == 400 && choice == 'required') {
          continue; // provider does not support tool_choice=required
        }
        if (response.statusCode != 200) {
          _toolsWork = false;
          return false;
        }
        final decoded = jsonDecode(response.body);
        final choices = decoded is Map ? decoded['choices'] : null;
        if (choices is! List || choices.isEmpty) {
          _toolsWork = false;
          return false;
        }
        final message = (choices.first as Map)['message'];
        final calls = message is Map ? message['tool_calls'] : null;
        final ok = calls is List && calls.isNotEmpty;
        _toolsWork = ok;
        return ok;
      } catch (_) {
        // Try the next tool_choice mode, then report failure.
      }
    }
    _toolsWork = false;
    return false;
  }

  String _endpoint() {
    final base = _config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  List<Map<String, dynamic>> _toolsPayload() {
    return kToolCatalog
        .map((entry) => {
              'type': 'function',
              'function': {
                'name': entry['name'],
                'description': entry['description'],
                'parameters': entry['parameters'],
              },
            })
        .toList();
  }

  /// Recover a tool call the model printed as text, e.g.
  /// `{"name":"search_web","arguments":{"query":"…"}}`.
  _ToolCall? _recoverToolCall(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    final end = raw.lastIndexOf('}');
    if (end <= start) return null;
    final slice = raw.substring(start, end + 1);
    try {
      final decoded = jsonDecode(slice);
      if (decoded is! Map) return null;
      final name = (decoded['name'] ?? decoded['tool'] ?? decoded['function'])
          ?.toString();
      if (name == null || name.isEmpty) return null;
      if (!kToolCatalog.any((t) => t['name'] == name)) return null;
      final args = decoded['arguments'] ??
          decoded['parameters'] ??
          decoded['args'] ??
          const <String, dynamic>{};
      return _ToolCall(
        id: 'recovered_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
      )..arguments.write(jsonEncode(args));
    } catch (_) {
      return null;
    }
  }

  String _extractError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) {
          return err['message'].toString();
        }
        if (err is String && err.isNotEmpty) return err;
        if (decoded['message'] != null) return decoded['message'].toString();
      }
    } catch (_) {}
    final trimmed = body.trim();
    return trimmed.length > 240 ? '${trimmed.substring(0, 240)}…' : trimmed;
  }

  String _friendlyError(_ApiError e) {
    final model = _models[_modelIndex];
    final tried = _models.length > 1
        ? ' Tried: ${_models.join(', ')}.'
        : '';
    switch (e.status) {
      case 401:
        return '${_config.label} rejected the API key. Check it in '
            'Settings → AI provider.';
      case 403:
        // Groq returns 403 (empty body) for models outside the account's
        // plan — this is not a bad key.
        return 'This key cannot use “$model” on ${_config.label}.$tried '
            'Pick another model in Settings.';
      case 402:
        return '${_config.label} says the account has no credit left.';
      case 404:
        return 'The model “$model” was not found on ${_config.label}.$tried '
            'Change the model name in Settings.';
      case 429:
        return '${_config.label} is rate-limiting requests. Wait a moment and '
            'try again.';
      case 0:
        return e.message;
      default:
        if (e.status >= 500) {
          return '${_config.label} had a server error (${e.status}). Try again.';
        }
        return '${_config.label} error ${e.status}: ${e.message}';
    }
  }

  static const String _systemPrompt = '''
You are Agent — a fast assistant living on the user's Android phone.

IDENTITY:
- You are "Agent". Never mention the underlying model, vendor, parameter count, provider, or whether you are cloud or on-device.
- If asked what you are, say you are Agent, their phone assistant.
- Never claim to be GPT, Gemini, Llama, DeepSeek, or any other product.

TOOLS — read carefully:
- You have function tools. When the user asks you to do something on the phone, or asks for a fact about this device, you MUST call the matching tool instead of answering from memory.
- Never say "I can't access your device" or "I don't have permission". Call the tool; if it fails, report the tool's error honestly.
- Use exactly one tool call per step, then wait for its result before deciding the next step. Chain tools for multi-step requests (e.g. search_contacts → send_whatsapp).
- Never invent phone numbers, package names, file paths or device values. Only use values returned by a tool or given by the user.

STYLE:
- One or two short sentences. The user is on a phone and is waiting.
- No preamble, no restating the question, no lists unless asked.
- If an image was attached, say in one short sentence that you cannot view it
  on the current setup, then answer the text.
''';
}
