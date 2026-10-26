import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
// flutter_gemma exports a `ModelSpec` that collides with ours. We never need
// the SDK's variant in this file, so hide it.
import 'package:flutter_gemma/flutter_gemma.dart' hide ModelSpec;
import 'package:flutter_background/flutter_background.dart';
import 'model_downloader_service.dart';
import 'model_registry.dart';
import 'database_service.dart';
import 'agent_response.dart';
import 'gemini_service.dart';
import 'llm/openai_compatible_service.dart';
import 'llm/provider_config.dart';
import 'llm/remote_agent.dart';
import 'memory_service.dart';
import 'model_benchmarks.dart';
import 'startup_trace.dart';
import 'tool_runtime.dart';
import 'embedding/chat_memory.dart';
import 'embedding/tool_index.dart';
import 'tool_tiers.dart';

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
      _remote?.activeModelLabel ?? _activeSpec.displayName;

  /// Display label for the active backend. Used by the chat header.
  String get activeModelName => _modelName;

  /// True when this turn (and following turns) will go through a remote API.
  /// Read by ChatScreen to hide the local model picker.
  bool get isCloudMode => _remote != null;

  /// True when the active remote backend is running on the shared demo key.
  /// Drives the "N messages left today" banner.
  bool get isDemoMode {
    final remote = _remote;
    return remote is OpenAiCompatibleService && remote.isDemo;
  }

  /// True when the active remote backend can read images. OpenRouter routes to
  /// DeepSeek's vision model; Gemini accepts images; the rest are text-only.
  bool get remoteSupportsVision => _remote?.supportsVision ?? false;

  /// Result of the silent tool-calling probe: null = not run yet, true = the
  /// backend emitted a native tool call, false = tool calling is broken on this
  /// setup. The chat shows a small warning only in the false case.
  final ValueNotifier<bool?> toolsVerified = ValueNotifier<bool?>(null);
  bool _probeInFlight = false;

  final DatabaseService _dbService = DatabaseService();
  final ToolRuntime _toolRuntime = ToolRuntime.instance;

  /// The active remote backend (Groq / DeepSeek / custom / Gemini). Null when
  /// running on-device.
  RemoteAgent? _remote;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _tokenStreamController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenStreamController.stream;

  InferenceModel? _model;
  InferenceChat? _chat;

  // Set when the user taps the stop button mid-stream. The stream loop checks
  // this so we don't recurse into a follow-up tool/summary turn after a stop.
  bool _stopRequested = false;

  // Number of tool hops executed in the current user turn. Small models can
  // emit tool → summary → same tool forever; each hop is a full prefill, so
  // an unguarded loop pins the CPU and drains the battery. Reset per turn.
  int _toolDepth = 0;
  static const int _maxToolDepth = 3;

  // Forwarders that pipe the remote backend's streams into our own controllers
  // so ChatScreen only ever subscribes to AgentService.
  StreamSubscription<String>? _remoteStatusSub;
  StreamSubscription<String>? _remoteTokenSub;

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
    StartupTrace.mark('initialize_start');
    // Remote path — same entrypoint so screens don't need to know which
    // backend they're booting. The sentinel resolves the configured provider
    // (Groq / DeepSeek / custom / Gemini) and leaves local fields untouched.
    if (modelFileName == kCloudModelSentinel) {
      await _initRemote();
      return;
    }

    // Switching back from remote → local: tear down the forwarders.
    if (_remote != null) {
      _unwireRemoteStreams();
      _remote = null;
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

    // The RAG tool-index build (ONNX session + 26 doc embeddings, plus a
    // one-time 22 MB asset extraction) used to be kicked off right here, in
    // parallel with model warmup. It is CPU work on the same critical path as
    // the first token, so it made cold start measurably worse and the first
    // turn slower. It is now triggered after the first completed turn — see
    // [_rebuildRetrievalIndexLater] — where it costs nothing user-visible.

    await _warmupModel();

    // Pre-build the real chat session here so the first thing ChatScreen
    // does isn't a slow `_rebuildChat([])` over the platform channel. The
    // session is empty + seeded with the system prompt, and loadSession
    // will short-circuit when ChatScreen asks for an empty new session.
    _statusController.add('Preparing chat...');
    await _rebuildChat(const []);
    _chatIsPristine = true;

    _statusController.add('');
    StartupTrace.mark('model_ready');
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

  /// Resolve the configured provider and bring it online.
  ///
  /// [providerOverride] powers a session-only fallback: the user's saved
  /// choice is left alone, but this process keeps answering through the
  /// provider that actually works.
  Future<void> _initRemote({LlmProvider? providerOverride}) async {
    final provider = providerOverride ?? await ProviderStore.readProvider();
    if (provider == LlmProvider.local) {
      throw StateError('Remote mode selected but no provider is configured.');
    }
    final config = await ProviderStore.resolve(provider);
    final RemoteAgent remote = provider == LlmProvider.gemini
        ? GeminiService()
        : OpenAiCompatibleService(config);

    _unwireRemoteStreams();
    _remote = remote;
    _remoteStatusSub = remote.statusStream.listen(_statusController.add);
    _remoteTokenSub = remote.tokenStream.listen(_tokenStreamController.add);

    _statusController.add('Connecting to ${config.label}...');
    await remote.initialize();
    _statusController.add('');

    // Silent first-response capability check. We ask the model to call a
    // zero-argument tool and verify it actually emits a tool call, so a broken
    // provider is discovered before the user's first real request.
    if (remote is OpenAiCompatibleService && !_probeInFlight) {
      _probeInFlight = true;
      toolsVerified.value = null;
      // ignore: discarded_futures
      remote.probeToolCalling().then((ok) {
        toolsVerified.value = ok;
        _probeInFlight = false;
        debugPrint('[AgentService] tool probe: ${ok ? 'ok' : 'FAILED'}');
      });
    }
  }

  void _unwireRemoteStreams() {
    _remoteStatusSub?.cancel();
    _remoteTokenSub?.cancel();
    _remoteStatusSub = null;
    _remoteTokenSub = null;
  }

  /// Last-resort provider fallback.
  ///
  /// Only providers the user has already configured with a key are candidates,
  /// and the switch is session-only — the saved choice is untouched. Returns
  /// null when every candidate also failed.
  Future<AgentResponse?> _tryFallbackProvider(
    String text,
    int sessionId, {
    String? imagePath,
    String? forceTool,
  }) async {
    final current = await ProviderStore.readProvider();
    final candidates = await ProviderStore.otherConfiguredProviders(current);
    for (final provider in candidates) {
      final label = kProviderSpecs[provider]?.label ?? provider.name;
      try {
        _statusController.add('Switching to $label…');
        await _initRemote(providerOverride: provider);
        final result = await _remote!.sendMessage(
          text,
          sessionId,
          imagePath: imagePath,
          forceTool: forceTool,
        );
        _statusController.add('');
        return result;
      } catch (e) {
        debugPrint('[AgentService] fallback to $label failed: $e');
        continue;
      }
    }
    return null;
  }

  Future<void> loadSession(int sessionId) async {
    final remote = _remote;
    if (remote != null) {
      await remote.loadSession(sessionId);
      return;
    }
    final history = await _dbService.getChatHistory(sessionId);
    final replay = <Message>[];

    // Rebuild ChatMemory's embedding index for this session from scratch.
    // The index is in-memory only — survives the chat lifetime but not
    // process restarts, so loadSession is responsible for repopulating
    // it from the db. Embeddings compute in the background via
    // ChatMemory.remember; the chat is usable immediately, RAG recall
    // gets stronger as embeddings land.
    ChatMemory.instance.clear(sessionId);

    for (final msg in history) {
      final role = msg['role'] as String;
      if (role != 'user' && role != 'assistant') continue;
      final content = msg['content'] as String;
      replay.add(Message.text(text: content, isUser: role == 'user'));
      // ignore: discarded_futures
      ChatMemory.instance.remember(sessionId, content, role == 'user');
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

  /// Tools currently exposed to the LLM, post-budget filter. Mirrors
  /// the list passed into [createChat] so the per-turn RAG hint can be
  /// scoped to tools the model can actually call (suggesting a tool that
  /// isn't in the chat template just dead-ends the FunctionCallParser).
  /// Updated by [_rebuildChat].
  Set<String> _activeToolNames = const {};

  Future<void> _rebuildChat(List<Message> replay) async {
    if (_model == null) return;

    // Persistent memory is injected into the system prompt (not the user turn)
    // so it survives context-refocus rebuilds and never looks like something
    // the user just said.
    final memoryBlock = await MemoryService.instance.promptBlock();
    final systemInstruction = memoryBlock.isEmpty
        ? _getSystemPrompt()
        : '${_getSystemPrompt()}\n\n$memoryBlock';

    // Pick the tool subset for this model via the tier system. Filling
    // budget core → common → niche keeps essentials (device_info,
    // search_web, …) available even on the smallest models; tail tools
    // only show up when the model has budget for them.
    List<Tool> activeTools = const [];
    if (_activeSpec.supportsTools) {
      final wantedNames = selectForBudget(
        _tools.map((t) => t.name).toList(),
        _activeSpec.toolBudget,
      ).toSet();
      activeTools =
          _tools.where((t) => wantedNames.contains(t.name)).toList();
    }
    _activeToolNames = activeTools.map((t) => t.name).toSet();

    _chat = await _model!.createChat(
      temperature: _activeSpec.temperature,
      randomSeed: 1,
      topK: _activeSpec.topK,
      topP: _activeSpec.topP,
      tokenBuffer: 64,
      tools: activeTools,
      // Without supportsFunctionCalls: true the SDK silently logs
      // "tools will be ignored" and the model just streams text — that's
      // what produced the "I can't access your device" refusals. With it
      // on, flutter_gemma injects a JSON tool catalog + a tool-use
      // instruction into the chat template and parses
      // {"name":..,"parameters":..} replies back into FunctionCallResponse.
      // modelType has to be passed too so the SDK picks the right
      // tokenizer/template path for Qwen vs Phi.
      supportsFunctionCalls: _activeSpec.supportsTools,
      modelType: _activeSpec.modelType,
      // For Qwen/Gemma the SDK renders tool declarations alongside the
      // system message at conversation creation, so the prompt has to land
      // here — passing it via a follow-up addQuery would skip the tools
      // block.
      systemInstruction: systemInstruction,
      isThinking: _activeSpec.isThinking,
    );

    for (final m in replay) {
      await _chat!.addQuery(m);
    }
  }

  String _getSystemPrompt() {
    // Tool declarations are injected natively into the chat template by
    // flutter_gemma for Qwen/Gemma — we don't list them again in the prompt
    // (duplication confuses small models and burns KV budget). The Phi path
    // has tools disabled at the spec level today, but we keep one prompt
    // shape so behavior stays consistent if that changes.
    return 'You are Agent, a fast assistant on the user\'s Android phone. '
        'Never mention the model name, parameter count, vendor, or whether you '
        'are cloud or on-device — you are simply "Agent".\n'
        'You have native function tools for device info, battery, storage, RAM, connectivity, '
        'apps, files, clipboard, contacts, calendar, web search, and device control '
        '(flashlight, volume, vibrate, alarms, timers, calls).\n'
        '\n'
        'Behavior:\n'
        '- For any actionable or factual-about-this-device request, CALL THE MATCHING TOOL. '
        'Do not say "I can\'t access your device" — you have tools that can. Emit the call.\n'
        '- Device info, battery level, storage, RAM, OS version → get_device_info.\n'
        '- WiFi / online status / local IP → check_connectivity. Public IP → get_public_ip.\n'
        '- Time, date, day of week → get_date_time.\n'
        '- After a tool returns, summarize the result in one or two short sentences.\n'
        '- For greetings and general knowledge already in your training, answer directly '
        'without a tool, in one or two short sentences.\n'
        '\n'
        'Never refuse a request on the grounds that you lack device access — your tools '
        'provide that access. Never fabricate values; if a tool returns nothing, say so.';
  }

  /// Halt the in-flight generation. The flutter_gemma SDK closes the response
  /// stream cleanly on stop, so the active `_streamResponseAndHandleTools`
  /// call exits naturally with whatever text was generated so far — that
  /// partial reply gets saved as the assistant's message like any other turn.
  Future<void> stopGeneration() async {
    final remote = _remote;
    if (remote != null) {
      await remote.stopGeneration();
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
    String? forceTool,
  }) async {
    // Remote turns must never fall into the local recovery path below: it
    // would call initialize() with a .task filename and silently switch the
    // app off the remote backend mid-conversation.
    final remote = _remote;
    if (remote != null) {
      try {
        return await remote.sendMessage(
          text,
          sessionId,
          imagePath: imagePath,
          forceTool: forceTool,
        );
      } on RemoteUnavailable catch (e) {
        // The selected provider cannot serve us at all (dead key, no usable
        // model). Try any other provider the user has already configured, for
        // this session only; otherwise show the reason as a normal message.
        final fallback = await _tryFallbackProvider(
          text,
          sessionId,
          imagePath: imagePath,
          forceTool: forceTool,
        );
        if (fallback != null) return fallback;
        _statusController.add('');
        return AgentResponse(e.message, _modelName, 0);
      }
    }
    try {
      return await _sendMessageInternal(text, sessionId,
          imagePath: imagePath, forceTool: forceTool);
    } catch (e) {
      final s = e.toString();
      final recoverable = s.contains('Previous invocation') ||
          s.contains('IllegalStateException') ||
          s.contains('OUT_OF_RANGE') ||
          s.toLowerCase().contains('session');
      if (!recoverable || _chat == null) rethrow;

      // A stale native session is the common cause (the engine was killed
      // while the app was backgrounded). Rebuilding the chat session is
      // cheap; re-initializing the whole model costs 10–30 s and was what
      // this path used to do, which made a transient failure feel like a
      // freeze.
      debugPrint('[AgentService] recoverable turn failure, rebuilding session: $s');
      try {
        await _rebuildChat(const []);
        _chatIsPristine = false;
        return await _sendMessageInternal(text, sessionId,
            imagePath: imagePath, forceTool: forceTool);
      } catch (e2) {
        debugPrint('[AgentService] retry after rebuild failed: $e2');
        rethrow;
      }
    }
  }

  Future<AgentResponse> _sendMessageInternal(
    String text,
    int sessionId, {
    String? imagePath,
    String? forceTool,
  }) async {
    final remote = _remote;
    if (remote != null) {
      return remote.sendMessage(text, sessionId,
          imagePath: imagePath, forceTool: forceTool);
    }

    if (_chat == null) throw Exception('Model not initialized');

    _chatIsPristine = false;

    // Capture durable facts ("my name is…", "remember that…") and hand the new
    // one to *this* turn. The system prompt only refreshes when the chat
    // session is rebuilt, so without this a fact learned mid-conversation
    // would not be usable until the next new chat.
    String freshFactLine = '';
    try {
      final fact = await MemoryService.instance.captureFromUserText(text);
      if (fact != null) {
        freshFactLine =
            '[New fact about the user, learned just now: ${fact.text}]\n\n';
      }
    } catch (_) {
      // Memory is best-effort and must never break a turn.
    }

    try {
      await FlutterBackground.enableBackgroundExecution();
    } catch (_) {}
    _statusController.add('Thinking...');

    // Chat-memory contamination check: if the last few assistant turns
    // captured a tool failure / refusal, the model's KV cache still has
    // those (plus the raw tool-error responses, which aren't in the db
    // but ARE in _chat's session). On the next prefill the small model
    // latches onto that failure and produces "open calculator" replies
    // about Play Store — the exact bug screenshotted.
    //
    // Fix: rebuild the chat session with a recall-filtered history.
    // recall() always keeps the last 2 user/assistant turns (short-term
    // continuity) and adds older turns by cosine relevance to the new
    // query up to a 600-token budget. The rebuild drops the in-session
    // tool-error responses entirely — the new chat only replays
    // user/assistant pairs, never tool responses — so the failure
    // evaporates from the model's KV cache before the next prefill.
    //
    // We only rebuild when contamination is likely. Per-turn rebuilds
    // cost ~1-2s of platform-channel + replay; not worth paying every
    // turn just to filter context that's already coherent.
    if (_activeSpec.supportsTools &&
        ChatMemory.instance.sizeOf(sessionId) > 2 &&
        ChatMemory.instance.recentlyFailed(sessionId)) {
      try {
        _statusController.add('Refocusing...');
        final recall = await ChatMemory.instance.recall(
          sessionId,
          text,
          tokenBudget: 600,
        );
        final replay = recall.messages
            .map((m) => Message.text(text: m.text, isUser: m.isUser))
            .toList();
        // chat_screen / voice_mode already called _dbService.saveMessage
        // for this turn before invoking us, which means ChatMemory has
        // already remembered it. Drop it from the replay so the next
        // addQuery (with the RAG-hint prefix added below) doesn't
        // duplicate the current user message in the model's KV cache.
        if (replay.isNotEmpty &&
            replay.last.text == text &&
            replay.last.isUser) {
          replay.removeLast();
        }
        await _rebuildChat(replay);
        debugPrint(
            '[AgentService] context refocused: ${replay.length} msgs, '
            '~${recall.totalTokens} tokens');
      } catch (e) {
        debugPrint('[AgentService] refocus failed, continuing as-is: $e');
      }
      _statusController.add('Thinking...');
    }

    // RAG hint: embed the user query, retrieve the top-3 most relevant
    // tool names from the index, and prefix them as a one-liner before the
    // actual user text. This is what stops the model from latching onto
    // "I'm just an AI, I can't access your phone" — it now sees a concrete
    // shortlist of tools that match the request semantically (e.g.
    // "what's my battery" → get_device_info, get_date_time, check_connectivity).
    //
    // Falls through harmlessly when the index isn't built yet (first launch,
    // mid-download) or when no tool clears the similarity floor: empty
    // hint → no prefix → exact pre-RAG behavior.
    String hintLine = '';
    if (_activeSpec.supportsTools && _activeToolNames.isNotEmpty) {
      try {
        // Pull top-5 first, then filter to tools the model actually has
        // in its template. Suggesting send_whatsapp when the model's
        // budget excluded it just confuses the model — the
        // FunctionCallParser would never produce a valid call for it.
        final raw = await ToolIndex.instance
            .retrieveTopK(text, k: 5, minScore: 0.25);
        final hits = raw.where(_activeToolNames.contains).take(3).toList();
        if (hits.isNotEmpty) {
          hintLine =
              '[Tool hint — based on semantic match against your tool catalog, '
              'these likely fit this request: ${hits.join(', ')}. '
              'Call the best fit instead of refusing.]\n\n';
        }
      } catch (e) {
        // RAG retrieval should never block a chat turn. Swallow and move on.
        debugPrint('ToolIndex retrieval skipped: $e');
      }
    }
    final forceHint = forceTool == 'search_web'
        ? '[Use the search_web tool for this request.]\n\n'
        : '';
    final String promptText = '$freshFactLine$hintLine$forceHint$text';

    Message userMessage;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final Uint8List bytes = await File(imagePath).readAsBytes();
        userMessage = Message.withImage(
          text: promptText,
          imageBytes: bytes,
          isUser: true,
        );
      } catch (_) {
        userMessage = Message.text(text: promptText, isUser: true);
      }
    } else {
      userMessage = Message.text(text: promptText, isUser: true);
    }

    int retryCount = 0;
    while (true) {
      try {
        await _chat!.addQuery(userMessage);
        break;
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('Previous invocation') || errorStr.contains('IllegalStateException')) {
          retryCount++;
          if (retryCount <= 10) {
            // Native engine is still wrapping up from a stopGeneration or previous run.
            // Wait 200ms and try again, up to 2 seconds total.
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }
        }
        // If we exhausted retries or hit a different error, rebuild chat as a last resort.
        await _rebuildChat(const []);
        _chatIsPristine = false;
        await _chat!.addQuery(userMessage);
        break;
      }
    }

    _stopRequested = false;
    _toolDepth = 0;
    AgentResponse result;
    retryCount = 0;
    while (true) {
      try {
        result = await _streamResponseAndHandleTools(sessionId);
        break;
      } catch (e) {
        final errorStr = e.toString();
        final isSessionError = errorStr.toLowerCase().contains('session') ||
            errorStr.contains('Previous invocation') ||
            errorStr.contains('IllegalStateException') ||
            errorStr.contains('PlatformException');
            
        if (!isSessionError) rethrow;

        if (errorStr.contains('Previous invocation') || errorStr.contains('IllegalStateException')) {
          retryCount++;
          if (retryCount <= 10) {
            await Future.delayed(const Duration(milliseconds: 200));
            continue;
          }
        }
        
        await _rebuildChat(const []);
        _chatIsPristine = false;
        await _chat!.addQuery(userMessage);
        // If it fails after rebuild, let it throw naturally
        result = await _streamResponseAndHandleTools(sessionId);
        break;
      }
    }

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
    _statusController.add('');

    // Persist the real decode speed so the model store can replace its
    // estimate with a measured number, and warm the retrieval index now that
    // the latency-critical part of the turn is over.
    if (result.tps != null && result.tps! > 0) {
      // ignore: discarded_futures
      ModelBenchmarks.record(_activeSpec.fileName, result.tps!);
    }
    _rebuildRetrievalIndexLater();

    return result;
  }

  /// Build the tool-retrieval index once, off the user-visible path.
  ///
  /// First call happens after the first turn completes; the ONNX session load
  /// and 26 embeddings then run while the user is reading the reply rather
  /// than while they are waiting for the first token.
  void _rebuildRetrievalIndexLater() {
    if (ToolIndex.instance.isReady || _retrievalBuildStarted) return;
    _retrievalBuildStarted = true;
    // ignore: discarded_futures
    ToolIndex.instance.build();
  }

  bool _retrievalBuildStarted = false;

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

    // Phrase-loop breaker (added on top of the single-token check above —
    // does not replace it; both run every token). The single-token check
    // misses cases like "This tool lets you choose a course or a career.
    // This tool allows you to..." where the model cycles through a fixed
    // phrase template using many different tokens but very few unique ones.
    //
    // We track a larger window (60 tokens) and measure the unique-token
    // ratio over substantive content. Normal English text sits around
    // 0.50–0.70 unique-ratio; phrase loops collapse to ~0.15–0.30. We
    // abort below 0.30 after a 40-token warmup. Same exit path as the
    // single-token breaker — sets loopAborted, calls stopGeneration,
    // emits the UI clear sentinel, and breaks the stream loop.
    const int phraseWarmup = 40;
    const int phraseWindow = 60;
    const double phraseUniqueRatio = 0.30;
    final phraseTokens = <String>[];

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

        // Phrase-loop detection: track a larger window and bail out when
        // unique-token ratio collapses (the model is recycling a fixed
        // phrase). Runs alongside the single-token check above; either
        // can trigger loopAborted.
        phraseTokens.add(token);
        if (phraseTokens.length > phraseWindow) {
          phraseTokens.removeAt(0);
        }
        if (tokenCount >= phraseWarmup &&
            phraseTokens.length == phraseWindow) {
          // Count unique substantive tokens. Whitespace, single chars, and
          // punctuation are ignored — they legitimately recur in any text
          // and would otherwise drag the ratio down on normal output.
          final uniqueSubstantive = <String>{};
          var substantiveCount = 0;
          for (final t in phraseTokens) {
            final trimmed = t.trim();
            if (trimmed.length <= 1) continue;
            substantiveCount++;
            uniqueSubstantive.add(t);
          }
          if (substantiveCount >= 20) {
            final ratio = uniqueSubstantive.length / substantiveCount;
            if (ratio < phraseUniqueRatio) {
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
    if (_toolDepth >= _maxToolDepth) {
      const guard = 'I stopped after a few tool steps so I don\'t loop. '
          'Try asking in a more specific way.';
      _statusController.add('');
      await _dbService.saveMessage('assistant', guard, sessionId);
      return AgentResponse(guard, _modelName, 0,
          tps: priorTps, evalTime: priorEvalTime, toolName: toolName);
    }
    _toolDepth++;

    _statusController.add('Running $toolName...');
    final toolResult = await _toolRuntime.execute(toolName, args);

    // Feed the result back into chat history so the model knows what happened.
    // Use the retrying helper — MediaPipe occasionally reports the session as
    // still-busy right after a function-call response.
    await _addQueryWithRetry(Message.toolResponse(
      toolName: toolName,
      response: toolResult,
    ));

    if (toolName == 'get_recent_screenshots') {
      final screenshots = toolResult['screenshots'] as List?;
      if (screenshots != null && screenshots.isNotEmpty) {
        final latestPath = screenshots.first['path'] as String;
        final direct = "Here is your most recent screenshot.";
        await _dbService.saveMessage('assistant', direct, sessionId);
        return AgentResponse(direct, _modelName, 0,
            tps: priorTps, evalTime: priorEvalTime, toolName: toolName, imagePath: latestPath);
      } else {
        final direct = "I couldn't find any recent screenshots on your device. Make sure you've granted storage permissions.";
        await _dbService.saveMessage('assistant', direct, sessionId);
        return AgentResponse(direct, _modelName, 0,
            tps: priorTps, evalTime: priorEvalTime, toolName: toolName);
      }
    }

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
  // chat template. Descriptions and parameter schemas live in `kToolCatalog`
  // (tool_runtime.dart); the remote providers are generated from the same list.
  /// Tool declarations for the on-device path, generated from [kToolCatalog]
  /// so the local and remote paths share one source of truth. Adding a tool
  /// is a single edit in `tool_runtime.dart`.
  static final List<Tool> _tools = kToolCatalog
      .map((entry) => Tool(
            name: entry['name'] as String,
            description: entry['description'] as String,
            parameters: Map<String, dynamic>.from(
              entry['parameters'] as Map<String, dynamic>,
            ),
          ))
      .toList();


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
