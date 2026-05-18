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

  ModelSpec _activeSpec = ModelRegistry.functionGemma270M;
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
  /// GPU pipeline is hot when the user sends their first real message.
  /// Errors here are swallowed — a failed warm-up shouldn't block the app.
  Future<void> _warmupModel() async {
    if (_model == null) return;
    try {
      final warm = await _model!.createChat(
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
      // Pull at most a handful of tokens — we only care about lighting up
      // the kernels, not the actual text.
      int taken = 0;
      await for (final _ in warm.generateChatResponseAsync()) {
        if (++taken >= 4) break;
      }
      try {
        await warm.stopGeneration();
      } catch (_) {}
    } catch (_) {
      // Cold-start hiccup — the next real send still works.
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
      tokenBuffer: 256,
      supportsFunctionCalls: _activeSpec.supportsTools,
      tools: _activeSpec.supportsTools ? _tools : const [],
      modelType: _activeSpec.modelType,
      // Gemma 4's chat template renders the tool declarations alongside the
      // system message at conversation creation. If we seed the prompt
      // afterwards via addQuery instead, the model never sees its tools and
      // hallucinates function-call syntax as plain text
      // (e.g. `launch_app_by_name(app_name="Flashlight")`). Pass it here.
      systemInstruction: _getSystemPrompt(),
      // Gemma 4 emits `<|channel>thought\n…<channel|>` reasoning tokens; the
      // filter routes them to ThinkingResponse events.
      isThinking: _activeSpec.isThinking,
    );

    for (final m in replay) {
      await _chat!.addQuery(m);
    }
  }

  String _getSystemPrompt() {
    return '''You are an on-device AI agent running on the user's Android phone. You are agentic: you chain tools to actually accomplish what the user asks, and you don't stop at half a step.

RESPOND DIRECTLY. For greetings, names, chit-chat, basic questions, and anything you already know — answer in one or two short sentences immediately. Do NOT use internal reasoning blocks for these. Reply with one line of plain text and stop.

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
    if (_cloudActive) {
      // GeminiService manages its own controllers, but we forwarded those into
      // ours in [_wireGeminiStreams] so ChatScreen still sees the same stream.
      return _gemini.sendMessage(text, sessionId, imagePath: imagePath);
    }

    if (_chat == null) throw Exception('Model not initialized');

    // First real user query consumes the pre-built pristine session.
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
