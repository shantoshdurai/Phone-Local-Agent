import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
// flutter_gemma exports a `ModelSpec` that collides with ours. We never need
// the SDK's variant in this file, so hide it.
import 'package:flutter_gemma/flutter_gemma.dart' hide ModelSpec;
import 'package:flutter_background/flutter_background.dart';
import 'model_downloader_service.dart';
import 'model_registry.dart';
import 'database_service.dart';
import 'agent_response.dart';
import 'gemini_service.dart';
import 'tool_runtime.dart';

export 'agent_response.dart';

/// Sentinel passed as `modelFileName` when the app should open the cloud
/// backend instead of a local .task/.litertlm. Local screens (Splash, Chat,
/// Home) check for this before doing model-file work.
const String kCloudModelSentinel = 'gemini-cloud';

class AgentService {
  static final AgentService _instance = AgentService._internal();
  factory AgentService() => _instance;
  AgentService._internal();

  ModelSpec _activeSpec = ModelRegistry.qwen2_5_1_5b;
  ModelSpec get activeSpec => _activeSpec;
  String get _modelName =>
      _cloudActive ? GeminiService.modelName : _activeSpec.displayName;

  /// Display label for the active backend. Used by the chat header.
  String get activeModelName => _modelName;

  /// True when this turn (and following turns) will go through the cloud
  /// Gemini path. Read by ChatScreen to hide the local model picker.
  bool get isCloudMode => _cloudActive;

  final DatabaseService _dbService = DatabaseService();
  final ToolRuntime _toolRuntime = ToolRuntime.instance;
  final GeminiService _gemini = GeminiService();

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _tokenStreamController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenStreamController.stream;

  InferenceModel? _model;
  InferenceChat? _chat;

  // Set when the user taps the stop button mid-stream. The stream loop checks
  // this so we don't recurse into a follow-up tool/summary turn after a stop.
  bool _stopRequested = false;

  // True when the active backend is GeminiService (cloud). Set during
  // [initialize]; consulted by every public entry point so the cloud path
  // is taken regardless of which screen calls us.
  bool _cloudActive = false;

  // Forwarders that pipe GeminiService's streams into our own controllers
  // so ChatScreen only ever subscribes to AgentService.
  StreamSubscription<String>? _geminiStatusSub;
  StreamSubscription<String>? _geminiTokenSub;

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
    // Cloud path — same entrypoint so SplashScreen + ChatScreen don't need
    // to know which backend they're booting. The sentinel routes us to
    // GeminiService and we leave the local model fields untouched.
    if (modelFileName == kCloudModelSentinel) {
      _cloudActive = true;
      _wireGeminiStreams();
      _statusController.add('Connecting to Gemini...');
      await _gemini.initialize();
      _statusController.add('');
      return;
    }

    // Switching back from cloud → local: tear down the forwarders.
    if (_cloudActive) {
      _unwireGeminiStreams();
      _cloudActive = false;
    }

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

    // GPU kernel warm-up. The first generate call after model load takes
    // 10–20 s on Adreno/Mali because the compute shaders are JIT-compiled
    // and the weight tensors are mapped lazily. Doing it here — silently,
    // before the user types — means the user's actual "hi" comes back fast
    // instead of stalling for half a minute on cold start.
    _statusController.add('Warming up...');
    await _warmupModel();

    // Pre-build the real chat session here so the first thing ChatScreen
    // does isn't a slow `_rebuildChat([])` over the platform channel. The
    // session is empty + seeded with the system prompt, and loadSession
    // will short-circuit when ChatScreen asks for an empty new session.
    _statusController.add('Preparing chat...');
    await _rebuildChat(const []);
    _chatIsPristine = true;

    _statusController.add('');
  }

  /// True when `_chat` was just created by `initialize` and hasn't received
  /// a real user query yet. Lets [loadSession] skip the expensive rebuild
  /// when ChatScreen asks for a fresh empty session.
  bool _chatIsPristine = false;

  /// Fire a tiny throwaway generation against a fresh chat session so the
  /// inference engine has touched the model graph once before the user's
  /// real first message lands. With CPU backend (matching Google's AI Edge
  /// Gallery default) there is no big GPU shader JIT to amortise, so this
  /// stays lightweight on purpose — no tools, no system prompt, tiny
  /// tokenBuffer. Splash finishes in seconds, not minutes.
  ///
  /// Errors are logged via debugPrint so a silent warmup failure can still
  /// be diagnosed; we never rethrow because a degraded warmup shouldn't
  /// block the app from booting.
  Future<void> _warmupModel() async {
    if (_model == null) return;
    InferenceChat? warm;
    try {
      warm = await _model!.createChat(
        temperature: _activeSpec.temperature,
        randomSeed: 1,
        topK: _activeSpec.topK,
        topP: _activeSpec.topP,
        tokenBuffer: 8,
        supportsFunctionCalls: false,
        tools: const [],
        modelType: _activeSpec.modelType,
        isThinking: false,
      );
      await warm.addQuery(Message.text(text: 'hi', isUser: true));
      int taken = 0;
      await for (final _ in warm.generateChatResponseAsync()) {
        if (++taken >= 4) break;
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('AgentService warmup failed: $e\n$st');
    } finally {
      if (warm != null) {
        try {
          await warm.stopGeneration();
        } catch (_) {}
      }
    }
  }

  void _wireGeminiStreams() {
    _geminiStatusSub ??= _gemini.statusStream.listen(_statusController.add);
    _geminiTokenSub ??= _gemini.tokenStream.listen(_tokenStreamController.add);
  }

  void _unwireGeminiStreams() {
    _geminiStatusSub?.cancel();
    _geminiTokenSub?.cancel();
    _geminiStatusSub = null;
    _geminiTokenSub = null;
  }

  Future<void> loadSession(int sessionId) async {
    if (_cloudActive) {
      await _gemini.loadSession(sessionId);
      return;
    }
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
    // Truncate history to prevent OUT_OF_RANGE KV cache crashes
    if (replay.length > 6) {
      replay.removeRange(0, replay.length - 6);
    }
    // Short-circuit when initialize() already built an empty chat session
    // for us. Avoids 1–2s of platform-channel round-trips (createChat +
    // two system-prompt addQuery calls) every time the user taps "new chat".
    if (replay.isEmpty && _chatIsPristine && _chat != null) {
      return;
    }
    await _rebuildChat(replay);
    _chatIsPristine = replay.isEmpty;
  }

  Future<void> _rebuildChat(List<Message> replay) async {
    if (_model == null) return;

    _chat = await _model!.createChat(
      temperature: _activeSpec.temperature,
      randomSeed: 1,
      topK: _activeSpec.topK,
      topP: _activeSpec.topP,
      tokenBuffer: 64,
      supportsFunctionCalls: _activeSpec.supportsTools,
      tools: _activeSpec.supportsTools ? _tools : const [],
      modelType: _activeSpec.modelType,
      // For Qwen/Gemma the SDK renders tool declarations alongside the
      // system message at conversation creation, so the prompt has to land
      // here — passing it via a follow-up addQuery would skip the tools
      // block.
      systemInstruction: _getSystemPrompt(),
      isThinking: _activeSpec.isThinking,
    );

    for (final m in replay) {
      await _chat!.addQuery(m);
    }
  }

  String _getSystemPrompt() {
    return 'You are LocalAgent, an independent on-device AI. You are strictly NOT developed by Microsoft or Google. Never identify as Phi.\n'
        'You have native tools to check network connectivity, search the web, manage apps, control hardware, read/write clipboard, read screenshots, search contacts, schedule events, and send WhatsApp.\n'
        'Always prioritize using a tool if it can accomplish the user\'s request.\n'
        'Reply in one or two short sentences.';
  }

  /// Halt the in-flight generation. The flutter_gemma SDK closes the response
  /// stream cleanly on stop, so the active `_streamResponseAndHandleTools`
  /// call exits naturally with whatever text was generated so far — that
  /// partial reply gets saved as the assistant's message like any other turn.
  Future<void> stopGeneration() async {
    if (_cloudActive) {
      await _gemini.stopGeneration();
      _statusController.add('');
      return;
    }
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
    try {
      return await _sendMessageInternal(text, sessionId, imagePath: imagePath);
    } catch (e) {
      print('sendMessage failed natively. Attempting full model re-initialization: $e');
      // Model might have been corrupted by OS backgrounding. Re-initialize from disk!
      if (_activeSpec != null) {
        await initialize(_activeSpec!.fileName);
        await loadSession(sessionId);
        return await _sendMessageInternal(text, sessionId, imagePath: imagePath);
      }
      rethrow;
    }
  }

  Future<AgentResponse> _sendMessageInternal(
    String text,
    int sessionId, {
    String? imagePath,
  }) async {
    if (_cloudActive) {
      return _gemini.sendMessage(text, sessionId, imagePath: imagePath);
    }

    if (_chat == null) throw Exception('Model not initialized');

    _chatIsPristine = false;

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

    try {
      await _chat!.addQuery(userMessage);
    } catch (e) {
      await _rebuildChat(const []);
      _chatIsPristine = false;
      await _chat!.addQuery(userMessage);
    }

    _stopRequested = false;
    AgentResponse result;
    try {
      result = await _streamResponseAndHandleTools(sessionId);
    } catch (e) {
      final isSessionError = e
              .toString()
              .toLowerCase()
              .contains('session') ||
          e.toString().contains('Previous invocation') ||
          e.toString().contains('IllegalStateException') ||
          e.toString().contains('PlatformException');
      if (!isSessionError) rethrow;
      await _rebuildChat(const []);
      _chatIsPristine = false;
      await _chat!.addQuery(userMessage);
      result = await _streamResponseAndHandleTools(sessionId);
    }

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
      finalText =
          "Hmm, that one came back empty. Try again, or switch to Gemini in Settings for harder requests.";
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
    final toolResult = await _toolRuntime.execute(toolName, args);

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
    final direct = _toolRuntime.formatDirect(toolName, args, toolResult);
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

  // ─── Tool declarations ───
  // The model sees these as native function declarations via the LiteRT-LM
  // chat template. Keep descriptions concrete and parameters strict.
  static final List<Tool> _tools = const [
    Tool(
      name: 'get_date_time',
      description: 'Get local date, time, and timezone.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_device_info',
      description: 'Get device manufacturer, OS, battery, storage, and RAM.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'check_connectivity',
      description: 'Check if device is online, WiFi/Cellular, SSID, and IP.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_public_ip',
      description: 'Get public IP address.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_web',
      description: 'Search the web for up-to-date facts and news.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'open_url',
      description: 'Open URL in browser.',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
        'required': ['url'],
      },
    ),
    Tool(
      name: 'list_files',
      description: 'List user files. Filters: extension, sortBy (modified/name/size).',
      parameters: {
        'type': 'object',
        'properties': {
          'extension': {'type': 'string'},
          'sortBy': {'type': 'string'},
        },
      },
    ),
    Tool(
      name: 'list_apps',
      description: 'List installed apps and sizes.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'launch_app_by_name',
      description: 'Launch app by display name.',
      parameters: {
        'type': 'object',
        'properties': {
          'appName': {'type': 'string'},
        },
        'required': ['appName'],
      },
    ),
    Tool(
      name: 'launch_app',
      description: 'Launch app by package name.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {'type': 'string'},
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'uninstall_app',
      description: 'Uninstall app by package name.',
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
      description: 'Search Play Store.',
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
      description: 'Open Play Store page.',
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
      description: 'Turn flashlight on/off.',
      parameters: {
        'type': 'object',
        'properties': {
          'on': {'type': 'boolean'},
        },
        'required': ['on'],
      },
    ),
    Tool(
      name: 'vibrate',
      description: 'Vibrate device.',
      parameters: {
        'type': 'object',
        'properties': {
          'duration': {'type': 'integer'},
        },
      },
    ),
    Tool(
      name: 'set_volume',
      description: 'Set media volume (0.0 to 1.0).',
      parameters: {
        'type': 'object',
        'properties': {
          'level': {'type': 'number'},
        },
        'required': ['level'],
      },
    ),
    Tool(
      name: 'copy_to_clipboard',
      description: 'Copy text to clipboard.',
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
      description: 'Read clipboard text.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_recent_screenshots',
      description: 'Get recent screenshots.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_contacts',
      description: 'Search contacts by name to get phone number.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'schedule_event',
      description: 'Create calendar event.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'start': {'type': 'string'},
          'end': {'type': 'string'},
          'description': {'type': 'string'},
        },
        'required': ['title', 'start', 'end'],
      },
    ),
    Tool(
      name: 'send_whatsapp',
      description: 'Open WhatsApp to send message.',
      parameters: {
        'type': 'object',
        'properties': {
          'phone': {'type': 'string'},
          'message': {'type': 'string'},
        },
        'required': ['phone', 'message'],
      },
    ),
  ];


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
}
