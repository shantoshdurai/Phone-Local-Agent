import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
// flutter_gemma exports a `ModelSpec` that collides with ours. We never need
// the SDK's variant in this file, so hide it.
import 'package:flutter_gemma/flutter_gemma.dart' hide ModelSpec;
import 'package:flutter_background/flutter_background.dart';
import 'model_downloader_service.dart';
import 'model_registry.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'database_service.dart';
import 'app_service.dart';
import 'utility_service.dart';
import 'personal_service.dart';
import 'search_service.dart';

class AgentResponse {
  final String text;
  final String modelName;
  final int retryCount;
  final double? tps;
  final double? evalTime;
  final String? toolName;
  AgentResponse(this.text, this.modelName, this.retryCount,
      {this.tps, this.evalTime, this.toolName});
}

class AgentService {
  static final AgentService _instance = AgentService._internal();
  factory AgentService() => _instance;
  AgentService._internal();

  ModelSpec _activeSpec = ModelRegistry.gemma3_1bLite;
  ModelSpec get activeSpec => _activeSpec;
  String get _modelName => _activeSpec.displayName;

  final DeviceService _deviceService = DeviceService();
  final FileService _fileService = FileService();
  final DatabaseService _dbService = DatabaseService();
  final AppService _appService = AppService();
  final UtilityService _utilityService = UtilityService();
  final PersonalService _personalService = PersonalService();
  final SearchService _searchService = SearchService();

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _tokenStreamController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenStreamController.stream;

  InferenceModel? _model;
  InferenceChat? _chat;

  // Set when the user taps the stop button mid-stream. The stream loop checks
  // this so we don't recurse into a follow-up tool/summary turn after a stop.
  bool _stopRequested = false;

  static bool _gemmaReady = false;
  static bool _backgroundReady = false;

  Future<void> _ensureNativeReady() async {
    if (!_gemmaReady) {
      await FlutterGemma.initialize();
      _gemmaReady = true;
    }
    if (!_backgroundReady) {
      try {
        const androidConfig = FlutterBackgroundAndroidConfig(
          notificationTitle: "Local Agent",
          notificationText: "Background processing active",
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon:
              AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        );
        await FlutterBackground.initialize(androidConfig: androidConfig);
      } catch (_) {}
      _backgroundReady = true;
    }
  }

  Future<void> initialize(String modelFileName) async {
    // Idempotent — splash + chat both end up calling this on the same model;
    // we don't want to re-map the .task / .litertlm file each time.
    if (_model != null && _activeSpec.fileName == modelFileName) {
      _statusController.add('');
      return;
    }

    _activeSpec = ModelRegistry.byFileName(modelFileName);
    _statusController.add('Initializing ${_activeSpec.displayName}...');

    await _ensureNativeReady();

    final downloader = ModelDownloaderService();
    final dir = await downloader.getModelsDirectory();
    final modelPath = '$dir/$modelFileName';

    if (!await File(modelPath).exists()) {
      throw Exception('Model file not found at $modelPath');
    }

    await FlutterGemma.installModel(
      modelType: _activeSpec.modelType,
      fileType: _activeSpec.fileType,
    ).fromFile(modelPath).install();

    _model = await FlutterGemma.getActiveModel(
      maxTokens: _activeSpec.maxTokens,
      preferredBackend: _activeSpec.preferredBackend,
      supportImage: _activeSpec.supportsVision,
      maxNumImages: _activeSpec.supportsVision ? 1 : 0,
    );

    _statusController.add('');
  }

  Future<void> loadSession(int sessionId) async {
    final history = await _dbService.getChatHistory(sessionId);
    final replay = <Message>[];
    for (final msg in history) {
      final role = msg['role'] as String;
      if (role != 'user' && role != 'assistant') continue;
      replay.add(Message.text(
        text: msg['content'] as String,
        isUser: role == 'user',
      ));
    }
    await _rebuildChat(replay);
  }

  Future<void> _rebuildChat(List<Message> replay) async {
    if (_model == null) return;

    _chat = await _model!.createChat(
      temperature: _activeSpec.temperature,
      randomSeed: 1,
      topK: _activeSpec.topK,
      topP: _activeSpec.topP,
      tokenBuffer: 256,
      supportsFunctionCalls: _activeSpec.supportsTools,
      tools: _activeSpec.supportsTools ? _tools : const [],
      modelType: _activeSpec.modelType,
      // Gemma 4 emits `<|channel>thought\n…<channel|>` reasoning tokens; the
      // filter routes them to ThinkingResponse events. Smaller models (1B,
      // Qwen3) don't have that channel — leaving the flag on for them strips
      // legitimate output.
      isThinking: _activeSpec.isThinking,
    );

    // Seed the new chat with a system instruction. Kept short so we don't
    // burn KV budget — Gemma 4 already understands its role from training.
    await _chat!.addQuery(Message.text(
      text: _getSystemPrompt(),
      isUser: true,
    ));
    await _chat!.addQuery(Message.text(
      text: "Understood. I'm ready to help.",
      isUser: false,
    ));

    for (final m in replay) {
      await _chat!.addQuery(m);
    }
  }

  String _getSystemPrompt() {
    // Per-model prompts. The 1B model treats long agentic instructions as
    // content to echo back ("Okay! Let's focus on building an effective
    // response system…"), and it skips function calling when given a wall
    // of natural-language guidance. Keep its prompt minimal and rule-based.
    // E2B has the capacity for the full agentic framing.
    if (_activeSpec.id == 'gemma3-1b-lite') {
      return '''You are a helpful on-device assistant on the user's phone.

For any request that maps to an available tool — turn on flashlight, vibrate, set volume, open an app, list files, search the web, check time/battery/connectivity, read or copy clipboard, etc. — CALL THE TOOL. Do not say "I will" or "let me" — emit the function call.

For greetings, small talk, and general knowledge, reply in one short sentence. No JSON, no preambles, no apologies.

Never invent phone numbers, contacts, or file paths.''';
    }

    return '''You are an on-device AI agent running on the user's Android phone. You are agentic: you chain tools to actually accomplish what the user asks, and you don't stop at half a step.

RESPOND DIRECTLY. For greetings, names, chit-chat, basic questions, and anything you already know — answer in one or two short sentences immediately. Skip internal reasoning for simple requests; only think when a task genuinely needs multi-step planning. Long deliberation on simple questions is wrong.

Decision flow:
1. If the user attached an image, that image is in this message — look at it directly. Do NOT call get_recent_screenshots or list_files for an attached image; those tools are only for files already on the device.
2. If the request needs current/device-specific data (apps, files, contacts, clipboard, weather, news, what's on the screen), call the right tool — don't guess from memory.
3. If a request needs more than one step, chain tools. Examples:
   - "message Sarah on WhatsApp" → search_contacts("Sarah") → send_whatsapp(<found-number>, message).
   - "open the biggest app" → list_apps → launch_app_by_name with the top result.
   - "copy current time to clipboard" → get_date_time → copy_to_clipboard(text=that time).
   - "find APK files" → list_files(extension="apk").
   - "what was the last file I modified" → list_files(sortBy="modified").
4. For chit-chat, greetings, definitions, and general knowledge already in your training, reply directly without a tool.

Hard rules:
- NEVER fabricate phone numbers, emails, contact names, addresses, or any personal data. If a lookup returns nothing, say so.
- When listing apps to uninstall or by size, use the sizeMB field from list_apps and present name + size, biggest first.
- When opening an app by its display name, prefer launch_app_by_name over guessing the package name.
- After a tool runs, summarize the result in one or two short sentences. Be concise.''';
  }

  /// Halt the in-flight generation. The flutter_gemma SDK closes the response
  /// stream cleanly on stop, so the active `_streamResponseAndHandleTools`
  /// call exits naturally with whatever text was generated so far — that
  /// partial reply gets saved as the assistant's message like any other turn.
  Future<void> stopGeneration() async {
    if (_chat == null) return;
    _stopRequested = true;
    try {
      await _chat!.stopGeneration();
    } catch (_) {
      // stop_not_supported or already-stopped — the stream still ends on its
      // own when the model finishes, so nothing else to do here.
    }
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
    _statusController.add('');
  }

  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
  }) async {
    if (_chat == null) throw Exception('Model not initialized');

    try {
      await FlutterBackground.enableBackgroundExecution();
    } catch (_) {}
    _statusController.add('Thinking...');

    Message userMessage;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final Uint8List bytes = await File(imagePath).readAsBytes();
        userMessage = Message.withImage(
          text: text,
          imageBytes: bytes,
          isUser: true,
        );
      } catch (_) {
        userMessage = Message.text(text: text, isUser: true);
      }
    } else {
      userMessage = Message.text(text: text, isUser: true);
    }

    await _chat!.addQuery(userMessage);

    _stopRequested = false;
    final result = await _streamResponseAndHandleTools(sessionId);

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
    _statusController.add('');

    return result;
  }

  // Stream the model's response. If it emits a function call, execute the
  // tool and either short-circuit with a templated reply (simple commands)
  // or feed the result back and stream the model's natural-language summary.
  Future<AgentResponse> _streamResponseAndHandleTools(int sessionId) async {
    String fullText = '';
    String? toolName;
    Map<String, dynamic>? toolArgs;
    int tokenCount = 0;
    final startTime = DateTime.now();
    bool streamStarted = false;

    // Loop-breaker for small models. Gemma 3 1B can latch onto a single
    // high-probability token (often "\n") and emit it for the rest of the
    // budget. We watch a sliding window of the most recent tokens and bail
    // out the moment the same one dominates it.
    //
    // Tuned to avoid false positives on normal short replies: only fires
    // after a warm-up, and only on substantive (non-whitespace) tokens —
    // a comma or a space repeating is not a loop.
    const int loopWarmup = 24;
    const int loopWindow = 20;
    const int loopThreshold = 16;
    final recentTokens = <String>[];
    bool loopAborted = false;

    await for (final response in _chat!.generateChatResponseAsync()) {
      if (response is TextResponse) {
        final token = response.token;
        if (token.isEmpty) continue;
        if (!streamStarted) {
          streamStarted = true;
          _tokenStreamController.add('\x00');
        }
        fullText += token;
        tokenCount++;
        _tokenStreamController.add(token);

        recentTokens.add(token);
        if (recentTokens.length > loopWindow) {
          recentTokens.removeAt(0);
        }
        if (tokenCount >= loopWarmup && recentTokens.length == loopWindow) {
          // Count the most common token in the window. Whitespace and
          // punctuation are excluded — they can legitimately recur.
          final counts = <String, int>{};
          String? topToken;
          int topCount = 0;
          for (final t in recentTokens) {
            final n = (counts[t] ?? 0) + 1;
            counts[t] = n;
            if (n > topCount) {
              topCount = n;
              topToken = t;
            }
          }
          final substantive = topToken != null &&
              (topToken.trim().length > 1 ||
                  topToken == '\n' ||
                  topToken == '\\n');
          if (topCount >= loopThreshold && substantive) {
            loopAborted = true;
            try {
              await _chat!.stopGeneration();
            } catch (_) {}
            if (streamStarted) {
              _tokenStreamController.add('\x02');
              streamStarted = false;
            }
            break;
          }
        }
      } else if (response is FunctionCallResponse) {
        toolName = response.name;
        toolArgs = Map<String, dynamic>.from(response.args);
        // Tool interrupted the stream — \x02 tells the UI to clear the
        // streaming bubble immediately so users don't see flashed JSON-ish
        // fragments. \x01 (used at clean end-of-response) preserves the text
        // so the final ChatMessage can slot in without a one-frame gap.
        if (streamStarted) {
          _tokenStreamController.add('\x02');
          streamStarted = false;
        }
        fullText = '';
        break;
      } else if (response is ParallelFunctionCallResponse) {
        // Only honor the first tool — keeps the agent loop deterministic.
        if (response.calls.isNotEmpty) {
          toolName = response.calls.first.name;
          toolArgs = Map<String, dynamic>.from(response.calls.first.args);
        }
        if (streamStarted) {
          _tokenStreamController.add('\x02');
          streamStarted = false;
        }
        fullText = '';
        break;
      } else if (response is ThinkingResponse) {
        // Surface thinking as a status update but don't store it.
        _statusController.add('Reasoning...');
      }
    }

    final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;
    final double tps = evalTimeMs > 0 && tokenCount > 0
        ? tokenCount / (evalTimeMs / 1000.0)
        : 0;

    if (streamStarted) {
      _tokenStreamController.add('\x01');
      streamStarted = false;
    }

    // User tapped stop — don't fire the captured tool call or fall into the
    // follow-up summary turn. Persist whatever plain text was streamed (may
    // be empty if the stop landed before any text token) and return.
    if (_stopRequested) {
      final partial = fullText.trim();
      final stoppedText = partial.isEmpty ? '[Stopped]' : partial;
      await _dbService.saveMessage('assistant', stoppedText, sessionId);
      return AgentResponse(stoppedText, _modelName, 0,
          tps: tps, evalTime: evalTimeMs / 1000.0);
    }

    if (toolName != null) {
      // After a FunctionCallResponse we exit the stream early. MediaPipe's
      // LlmInferenceSession can still report "Previous invocation still
      // processing" on the next addQuery — force a stop so the engine is in
      // a clean state before we feed the tool response back.
      try {
        await _chat!.stopGeneration();
      } catch (_) {}
      return _handleToolCall(
        sessionId,
        toolName,
        toolArgs ?? {},
        tps,
        evalTimeMs / 1000.0,
      );
    }

    final trimmed = fullText.trim();
    // Treat output that's effectively whitespace, just escape sequences, or
    // single repeating chars as garbage — the 1B model degrades into this
    // state on harder prompts.
    final isGarbage = loopAborted ||
        trimmed.isEmpty ||
        RegExp(r'^[\s\\n]+$').hasMatch(trimmed) ||
        (trimmed.length > 20 && _isSingleCharRepeat(trimmed));

    final String finalText;
    if (isGarbage) {
      finalText = _activeSpec.id == 'gemma3-1b-lite'
          ? "I got stuck on that one. Try rephrasing — or switch to Gemma 4 E2B from the model picker for tougher requests, it handles tools much more reliably."
          : "I got stuck on that. Could you rephrase?";
    } else {
      finalText = trimmed;
    }

    await _dbService.saveMessage('assistant', finalText, sessionId);

    return AgentResponse(finalText, _modelName, 0,
        tps: tps, evalTime: evalTimeMs / 1000.0);
  }

  /// True when [s] is the same character (or escape pair like "\\n") repeated
  /// throughout — a sign the model latched onto one token.
  bool _isSingleCharRepeat(String s) {
    final stripped = s.replaceAll(RegExp(r'\s'), '');
    if (stripped.isEmpty) return true;
    final first = stripped[0];
    for (final c in stripped.split('')) {
      if (c != first) return false;
    }
    return true;
  }

  Future<AgentResponse> _handleToolCall(
    int sessionId,
    String toolName,
    Map<String, dynamic> args,
    double priorTps,
    double priorEvalTime,
  ) async {
    _statusController.add('Running $toolName...');
    final toolResult = await _executeTool(toolName, args);

    // Feed the result back into chat history so the model knows what happened.
    // Use the retrying helper — MediaPipe occasionally reports the session as
    // still-busy right after a function-call response.
    await _addQueryWithRetry(Message.toolResponse(
      toolName: toolName,
      response: toolResult,
    ));

    // For simple actions (flashlight, vibrate, etc.) we have a clean templated
    // reply — return it immediately and skip a second model call. The chat
    // history still has the tool response so future turns stay coherent.
    final direct = _formatToolResult(toolName, args, toolResult);
    if (direct != null) {
      await _dbService.saveMessage('assistant', direct, sessionId);
      return AgentResponse(direct, _modelName, 0,
          tps: priorTps, evalTime: priorEvalTime, toolName: toolName);
    }

    // Complex tool (search, list_apps, device_info, ...) — let the model
    // summarize naturally.
    _statusController.add('Summarizing...');
    final followUp = await _streamResponseAndHandleTools(sessionId);
    return AgentResponse(
      followUp.text,
      _modelName,
      0,
      tps: followUp.tps ?? priorTps,
      evalTime: followUp.evalTime ?? priorEvalTime,
      toolName: toolName,
    );
  }

  /// Direct templated reply for tools where the result is trivially stringifiable.
  /// Returns null for tools where the model should summarize.
  String? _formatToolResult(
      String toolName, Map<String, dynamic> args, Map<String, dynamic> result) {
    if (result.containsKey('error')) return null;

    switch (toolName) {
      case 'toggle_flashlight':
        final on = args['on'] as bool? ?? true;
        return result['success'] == true
            ? 'Flashlight turned ${on ? "on" : "off"}.'
            : 'Could not toggle flashlight. Another app may be using the camera.';

      case 'vibrate':
        final ms = result['duration'] as int? ?? 500;
        final secs = ms / 1000.0;
        final label = secs == secs.truncateToDouble()
            ? '${secs.toInt()} second${secs.toInt() == 1 ? "" : "s"}'
            : '${secs.toStringAsFixed(1)} seconds';
        return 'Phone vibrated for $label.';

      case 'set_volume':
        final pct = ((result['level'] as num?)?.toDouble() ?? 0.5) * 100;
        return 'Volume set to ${pct.toStringAsFixed(0)}%.';

      case 'copy_to_clipboard':
        return 'Copied to clipboard.';

      case 'read_clipboard':
        final text = result['text'] as String? ?? '';
        return text == 'Clipboard is empty'
            ? 'Your clipboard is empty.'
            : 'Clipboard contains: "$text"';

      case 'open_url':
        return result['success'] == true
            ? 'Opening in your browser.'
            : 'Could not open that URL.';

      case 'launch_app':
        return result['success'] == true
            ? 'App launched.'
            : 'Could not launch that app.';

      case 'launch_app_by_name':
        if (result['success'] == true) {
          return '${result['appName'] ?? 'App'} opened.';
        }
        final suggestions = (result['suggestions'] as List?)?.cast<String>() ?? [];
        return suggestions.isNotEmpty
            ? 'App not found. Did you mean: ${suggestions.join(', ')}?'
            : 'App not found on this device.';

      case 'uninstall_app':
        return result['success'] == true
            ? 'Uninstall dialog opened.'
            : 'Could not initiate uninstall.';

      case 'search_play_store':
        return 'Opened Play Store search.';

      case 'open_play_store':
        return result['success'] == true
            ? 'Opened in Play Store.'
            : 'Could not open Play Store.';

      case 'get_public_ip':
        final ip = result['ip'] as String? ?? result['query'] as String? ?? 'unknown';
        return 'Your public IP address is $ip.';

      case 'send_whatsapp':
        return result['success'] == true
            ? 'Opening WhatsApp...'
            : 'Could not open WhatsApp. Make sure it is installed.';

      case 'schedule_event':
        return result['success'] == true
            ? 'Event added to your calendar.'
            : 'Could not create the calendar event.';

      default:
        return null;
    }
  }

  // ─── Tool declarations ───
  // The model sees these as native function declarations via the LiteRT-LM
  // chat template. Keep descriptions concrete and parameters strict.
  static final List<Tool> _tools = const [
    Tool(
      name: 'get_date_time',
      description:
          'Get the current local date, time, day of the week, and timezone.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_device_info',
      description:
          'Get device manufacturer, model, OS version, battery percentage, '
          'free and total storage, and RAM.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'check_connectivity',
      description:
          'Check whether the device is online, the connection type (WiFi or cellular), '
          'WiFi SSID, and local IP address.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_public_ip',
      description: 'Get the public IP address of the device.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_web',
      description:
          'Search the web for facts, news, weather, sports scores, or anything '
          'that needs up-to-date information. Use this whenever the user asks '
          'about real-world current events or topics outside your training.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query in natural language.',
          },
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'open_url',
      description: 'Open a URL in the device default browser.',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The full URL including https://',
          },
        },
        'required': ['url'],
      },
    ),
    Tool(
      name: 'list_files',
      description:
          'List user files on the device. Accepts optional filters: '
          '`extension` (e.g. "pdf", "apk", "jpg") to keep only files of that '
          'type, and `sortBy` ("modified" returns most recently modified first; '
          '"name" sorts alphabetically; "size" returns largest first). Use '
          '`sortBy: "modified"` for "what did I just save/edit" questions, '
          'and `extension` for type-specific questions like "find my PDFs" '
          'or "show me APKs".',
      parameters: {
        'type': 'object',
        'properties': {
          'extension': {
            'type': 'string',
            'description': 'File extension to filter by, without leading dot (e.g. "pdf").',
          },
          'sortBy': {
            'type': 'string',
            'description': 'One of: "modified", "name", "size". Default: "modified".',
          },
        },
      },
    ),
    Tool(
      name: 'list_apps',
      description:
          'List apps installed on the device. Returns each app\'s name, '
          'package name, and approximate disk size in MB (sizeMB). Results are '
          'sorted largest-first, so this is the right tool to use when the '
          'user asks what to uninstall, what is taking up space, or for app '
          'sizes. Always present names and sizes in your reply.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'launch_app_by_name',
      description:
          'Launch an installed app by its display name (e.g. "WhatsApp", "Calculator").',
      parameters: {
        'type': 'object',
        'properties': {
          'appName': {
            'type': 'string',
            'description': 'The display name of the app.',
          },
        },
        'required': ['appName'],
      },
    ),
    Tool(
      name: 'launch_app',
      description: 'Launch an installed app by its Android package name.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {
            'type': 'string',
            'description': 'The Android package name (e.g. com.whatsapp).',
          },
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'uninstall_app',
      description: 'Open the Android uninstall dialog for the given package.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {'type': 'string'},
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'search_play_store',
      description: 'Search the Google Play Store for an app.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'open_play_store',
      description: 'Open a specific app page in the Google Play Store.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {'type': 'string'},
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'toggle_flashlight',
      description: 'Turn the device flashlight on or off.',
      parameters: {
        'type': 'object',
        'properties': {
          'on': {
            'type': 'boolean',
            'description': 'true to turn on, false to turn off.',
          },
        },
        'required': ['on'],
      },
    ),
    Tool(
      name: 'vibrate',
      description: 'Vibrate the device for the given duration in milliseconds.',
      parameters: {
        'type': 'object',
        'properties': {
          'duration': {
            'type': 'integer',
            'description': 'Duration in milliseconds. Default 500.',
          },
        },
      },
    ),
    Tool(
      name: 'set_volume',
      description: 'Set the device media volume.',
      parameters: {
        'type': 'object',
        'properties': {
          'level': {
            'type': 'number',
            'description': 'Volume level between 0.0 and 1.0.',
          },
        },
        'required': ['level'],
      },
    ),
    Tool(
      name: 'copy_to_clipboard',
      description: 'Copy text to the device clipboard.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    ),
    Tool(
      name: 'read_clipboard',
      description:
          'Read whatever text is currently on the device clipboard. Use this '
          'when the user asks about their clipboard or what they just copied.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_recent_screenshots',
      description: 'Get a list of the recent screenshots on the device.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_contacts',
      description:
          'Search the device contacts by name. Returns matching contacts with '
          'their phone numbers and emails. Call this FIRST whenever the user '
          'asks to message, call, or look up someone by name — the result '
          'gives you the phone number to pass to send_whatsapp.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The contact name to search for (partial match OK).',
          },
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'schedule_event',
      description: 'Create a calendar event on the device.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'start': {
            'type': 'string',
            'description': 'ISO-8601 start datetime.',
          },
          'end': {
            'type': 'string',
            'description': 'ISO-8601 end datetime.',
          },
          'description': {'type': 'string'},
        },
        'required': ['title', 'start', 'end'],
      },
    ),
    Tool(
      name: 'send_whatsapp',
      description:
          'Open WhatsApp with a prefilled message for a phone number. '
          'IMPORTANT: only call this when you have a real phone number from '
          'the user or from a previous search_contacts result. NEVER invent '
          'or use placeholder numbers — if you don\'t know the number, call '
          'search_contacts first to look up the contact by name.',
      parameters: {
        'type': 'object',
        'properties': {
          'phone': {
            'type': 'string',
            'description':
                'Phone number in international format (e.g. +14155551234). '
                'Must come from search_contacts or directly from the user.',
          },
          'message': {'type': 'string'},
        },
        'required': ['phone', 'message'],
      },
    ),
  ];

  Future<Map<String, dynamic>> _executeTool(
      String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'get_date_time':
          final now = DateTime.now();
          const days = [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday', 'Sunday'
          ];
          return {
            'date':
                '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
            'time':
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            'dayOfWeek': days[now.weekday - 1],
            'timezone': now.timeZoneName,
          };
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'get_public_ip':
          return await _searchService.getPublicIP();
        case 'list_files':
          {
            final all = await _fileService.indexDocuments();
            final extFilter =
                (args['extension'] as String?)?.trim().toLowerCase();
            var filtered = all;
            if (extFilter != null && extFilter.isNotEmpty) {
              final wanted = extFilter.startsWith('.')
                  ? extFilter.substring(1)
                  : extFilter;
              filtered = all
                  .where((f) => f.type.toLowerCase() == wanted)
                  .toList();
            }
            final sortBy =
                (args['sortBy'] as String?)?.trim().toLowerCase() ?? 'modified';
            switch (sortBy) {
              case 'name':
                filtered.sort((a, b) => a.name.compareTo(b.name));
                break;
              case 'size':
                filtered.sort((a, b) => b.size.compareTo(a.size));
                break;
              case 'modified':
              default:
                filtered.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
            }
            return {
              'files': filtered.take(30).map((f) => {
                    'name': f.name,
                    'path': f.path,
                    'sizeKB': (f.size / 1024).round(),
                    'modified': f.modifiedDate.toIso8601String(),
                  }).toList(),
              'total': filtered.length,
              'filterExtension': extFilter,
              'sortedBy': sortBy,
            };
          }
        case 'toggle_flashlight':
          return {
            'success': await _utilityService
                .toggleFlashlight(args['on'] as bool? ?? true)
          };
        case 'list_apps':
          final apps = await _appService.getInstalledApps();
          // Sort largest-first so "what should I uninstall?" lands the
          // useful entries at the top, then truncate. Apps with unknown
          // size fall to the bottom.
          apps.sort((a, b) =>
              (b['sizeBytes'] as int? ?? 0).compareTo(a['sizeBytes'] as int? ?? 0));
          return {
            'apps': apps.take(60).map((a) {
              final bytes = a['sizeBytes'] as int? ?? 0;
              final mb = bytes > 0 ? (bytes / (1024 * 1024)) : 0;
              return {
                'name': a['name'],
                'pkg': a['packageName'],
                'sizeMB': mb > 0 ? double.parse(mb.toStringAsFixed(1)) : null,
              };
            }).toList(),
            'total': apps.length,
            'sortedBySizeDesc': true,
          };
        case 'launch_app':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.launchApp(pkg)};
        case 'uninstall_app':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.uninstallApp(pkg)};
        case 'search_play_store':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          await _appService.searchPlayStore(query);
          return {'success': true};
        case 'open_play_store':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.openPlayStore(pkg)};
        case 'vibrate':
          final duration = (args['duration'] as num?)?.toInt() ?? 500;
          await _utilityService.vibrate(duration: duration);
          return {'success': true, 'duration': duration};
        case 'set_volume':
          final level = (args['level'] as num?)?.toDouble() ?? 0.5;
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'copy_to_clipboard':
          final text = args['text'] as String? ?? '';
          if (text.isEmpty) return {'error': 'text required'};
          await _utilityService.copyToClipboard(text);
          return {'success': true};
        case 'read_clipboard':
          return {
            'text': await _utilityService.readFromClipboard() ?? 'Clipboard is empty'
          };
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          final raw = await _searchService.searchWeb(query);
          return _truncate(raw, 1500);
        case 'open_url':
          final url = args['url'] as String? ?? '';
          if (url.isEmpty) return {'error': 'url required'};
          return {'success': await _utilityService.openUrl(url)};
        case 'launch_app_by_name':
          final appName = args['appName'] as String? ?? '';
          if (appName.isEmpty) return {'error': 'appName required'};
          return await _appService.launchAppByName(appName);
        case 'get_recent_screenshots':
          return {'screenshots': await _fileService.getRecentScreenshots()};
        case 'search_contacts':
          return {
            'contacts':
                await _personalService.searchContacts(args['query'] as String? ?? '')
          };
        case 'schedule_event':
          final title = args['title'] as String? ?? '';
          final startStr = args['start'] as String? ?? '';
          final endStr = args['end'] as String? ?? '';
          if (title.isEmpty || startStr.isEmpty || endStr.isEmpty) {
            return {'error': 'title, start, and end are required'};
          }
          try {
            return {
              'success': await _personalService.scheduleEvent(
                title: title,
                start: DateTime.parse(startStr),
                end: DateTime.parse(endStr),
                description: args['description'] as String?,
              )
            };
          } catch (e) {
            return {'error': 'Invalid date format: $e'};
          }
        case 'send_whatsapp':
          final phone = args['phone'] as String? ?? '';
          final message = args['message'] as String? ?? '';
          if (phone.isEmpty || message.isEmpty) {
            return {'error': 'phone and message required'};
          }
          return {'success': await _personalService.sendWhatsApp(phone, message)};
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // Retrying addQuery for tool responses. MediaPipe's session sometimes
  // reports "Previous invocation still processing" right after a
  // FunctionCallResponse — we stop the engine and back off, then try again.
  Future<void> _addQueryWithRetry(Message msg) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        await _chat!.addQuery(msg);
        return;
      } catch (e) {
        final isBusy = e.toString().contains('Previous invocation');
        if (!isBusy || attempt == 2) rethrow;
        try {
          await _chat!.stopGeneration();
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 120 * (attempt + 1)));
      }
    }
  }

  // Truncate a JSON-shaped result so a single tool response doesn't blow
  // out the 4K KV window when fed back to the model.
  Map<String, dynamic> _truncate(Map<String, dynamic> result, int maxChars) {
    final encoded = jsonEncode(result);
    if (encoded.length <= maxChars) return result;
    return {
      'summary': encoded.substring(0, maxChars),
      'note': 'Result truncated to fit context window.',
    };
  }
}
