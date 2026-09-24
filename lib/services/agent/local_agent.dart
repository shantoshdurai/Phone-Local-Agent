import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
// flutter_gemma exports its own ModelSpec; we use ours from model_registry.
import 'package:flutter_gemma/flutter_gemma.dart' hide ModelSpec;

import '../model_downloader_service.dart';
import '../model_registry.dart';
import '../tools/tool_catalog.dart';
import '../tools/tool_runtime.dart';
import 'agent_types.dart';
import 'prompts.dart';
import 'text_utils.dart';

/// On-device backend on flutter_gemma (MediaPipe `.task` / LiteRT-LM
/// `.litertlm`).
///
/// Session lifecycle is managed explicitly because the SDK does not:
///  * `createChat` returns the *existing* native session until it is closed,
///    so the old code's warm-up session (no system prompt) silently became
///    every chat's session — the system prompt and tool rules never reached
///    the model, and one conversation leaked into the next.
///  * The SDK only counts response tokens toward the context limit, so the
///    window overflowed long before it recycled. We track the whole session
///    (system prompt, tool catalog, inputs, tool results, outputs) and start
///    a fresh session with a compact transcript before it can overflow.
///  * MediaPipe sessions have no roles for replayed history: every
///    `addQuery` before a generate becomes part of one user turn. History is
///    replayed as a clearly labelled transcript instead of fake turns.
class LocalAgent {
  InferenceModel? _model;
  ModelSpec? _spec;
  bool _usingGpu = false;
  List<ToolSpec> _tools = const [];

  InferenceChat? _chat;
  bool _chatDirty = false;
  int _sessionTokens = 0;
  bool _pendingToolResponse = false;

  /// Recent (user, assistant) exchanges, replayed into a fresh session.
  final List<(String, String)> _transcript = [];

  /// One-off context for the next prompt (e.g. instant commands that ran
  /// without the model).
  final List<String> _notes = [];
  bool _replayPending = false;

  bool _busy = false;
  bool _stopRequested = false;
  StreamSubscription<ModelResponse>? _activeSub;
  Completer<void>? _activeDone;

  static bool _gemmaInitialized = false;
  static const int _maxSteps = 4;

  ModelSpec? get spec => _spec;
  bool get isLoaded => _model != null;
  bool get usingGpu => _usingGpu;
  bool get isBusy => _busy;

  Set<String> get _toolNames => {for (final t in _tools) t.name};

  /// Tokens held back for the model's reply when budgeting a prompt.
  int get _responseReserve => (_spec!.contextTokens * 0.15).round().clamp(200, 600);

  /// Tool results are cut to fit small context windows.
  int get _toolResultChars => _spec!.contextTokens >= 4096 ? 1800 : 600;

  Future<void> load(
    ModelSpec spec, {
    required bool preferGpu,
    void Function(String status)? onStatus,
  }) async {
    final wantGpu = preferGpu && spec.gpuCapable;
    if (_model != null && _spec?.fileName == spec.fileName && _usingGpu == wantGpu) {
      return;
    }
    await unload();

    final path = await ModelDownloaderService().pathFor(spec.fileName);
    if (!await File(path).exists()) {
      throw StateError('${spec.displayName} isn\'t downloaded yet.');
    }
    if (!_gemmaInitialized) {
      await FlutterGemma.initialize();
      _gemmaInitialized = true;
    }
    onStatus?.call('Loading ${spec.displayName}');
    await FlutterGemma.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromFile(path).install();

    _spec = spec;
    _tools = spec.supportsTools ? selectToolsForBudget(spec.toolBudget) : const [];

    if (wantGpu) {
      try {
        await _openModel(spec, PreferredBackend.gpu);
        onStatus?.call('Warming up the GPU');
        if (await _warmup()) {
          _usingGpu = true;
          return;
        }
      } catch (e) {
        debugPrint('[LocalAgent] GPU load failed, falling back to CPU: $e');
      }
      await _closeModel();
      onStatus?.call('GPU unavailable, using CPU');
    }
    await _openModel(spec, PreferredBackend.cpu);
    _usingGpu = false;
    onStatus?.call('Warming up');
    await _warmup();
  }

  Future<void> _openModel(ModelSpec spec, PreferredBackend backend) async {
    _model = await FlutterGemma.getActiveModel(
      maxTokens: spec.contextTokens,
      preferredBackend: backend,
      supportImage: spec.supportsVision,
      maxNumImages: spec.supportsVision ? 1 : null,
    );
  }

  Future<void> _closeModel() async {
    await _closeChat();
    try {
      await _model?.close();
    } catch (_) {}
    _model = null;
  }

  Future<void> unload() async {
    await _closeModel();
    _spec = null;
    _tools = const [];
  }

  /// Runs one tiny generation so the first real message doesn't pay for
  /// weight paging / shader compilation. Its session is closed afterwards —
  /// leaving it open is what hijacked every later chat.
  Future<bool> _warmup() async {
    final spec = _spec!;
    InferenceChat? chat;
    try {
      chat = await _model!.createChat(
        temperature: spec.temperature,
        topK: spec.topK,
        topP: spec.topP,
        tokenBuffer: 64,
        modelType: spec.modelType,
        isThinking: false,
        supportsFunctionCalls: false,
      );
      await chat.addQuery(Message.text(text: 'Hi', isUser: true));
      final warm = chat;
      var tokens = 0;
      final done = Completer<void>();
      final sub = warm.generateChatResponseAsync().listen(
        (r) {
          if (r is TextResponse && ++tokens == 4) unawaited(_safeStop(warm));
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        cancelOnError: true,
      );
      try {
        await done.future.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        await _safeStop(warm);
        await sub.cancel();
      }
      return tokens > 0;
    } catch (e) {
      debugPrint('[LocalAgent] warm-up failed: $e');
      return false;
    } finally {
      try {
        await chat?.close();
      } catch (_) {}
    }
  }

  /// Starts a new conversation seeded with prior [history]; the native
  /// session is created lazily on the next message.
  Future<void> resetConversation(List<(String, String)> history) async {
    await _closeChat();
    _transcript
      ..clear()
      ..addAll(history.length > 6 ? history.sublist(history.length - 6) : history);
    _notes.clear();
    _replayPending = _transcript.isNotEmpty;
  }

  /// Adds context the model didn't see (an instant command's outcome).
  void addNote(String userText, String outcome) {
    _notes.add('Earlier the user said "${clip(userText, 80)}" and it was handled: ${clip(outcome, 160)}');
    if (_notes.length > 3) _notes.removeAt(0);
    _remember(userText, outcome);
  }

  Future<void> _closeChat() async {
    final chat = _chat;
    _chat = null;
    _pendingToolResponse = false;
    if (chat == null) return;
    try {
      await chat.close();
    } catch (e) {
      debugPrint('[LocalAgent] closing chat failed: $e');
    }
  }

  Future<void> _ensureChat() async {
    if (_chat != null && !_chatDirty) return;
    await _closeChat();
    final spec = _spec!;
    final hasTools = _tools.isNotEmpty;
    final system = localSystemPrompt(DateTime.now(), hasTools: hasTools);
    _chat = await _model!.createChat(
      temperature: spec.temperature,
      randomSeed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      topK: spec.topK,
      topP: spec.topP,
      tokenBuffer: 256,
      supportImage: spec.supportsVision,
      tools: [
        for (final t in _tools)
          Tool(name: t.name, description: t.localDescription, parameters: t.parameters),
      ],
      supportsFunctionCalls: hasTools,
      modelType: spec.modelType,
      isThinking: false,
      systemInstruction: system,
      maxFunctionBufferLength: 2048,
    );
    _chatDirty = false;
    _pendingToolResponse = false;
    _sessionTokens = estimateTokens(system) + (hasTools ? _toolCatalogTokens() : 0);
    _replayPending = _transcript.isNotEmpty;
  }

  int _toolCatalogTokens() {
    final b = StringBuffer('x' * 480); // SDK tool-use instructions
    for (final t in _tools) {
      b.write('${t.name}: ${t.localDescription} Parameters: ${jsonEncode(t.parameters)}\n');
    }
    return estimateTokens(b.toString());
  }

  String _composePrompt(String userText) {
    final b = StringBuffer();
    if (_replayPending && _transcript.isNotEmpty) {
      final budgetChars = (_spec!.contextTokens * 0.25 * 3.2).round();
      final picked = <(String, String)>[];
      var used = 0;
      for (final turn in _transcript.reversed) {
        final size = turn.$1.length.clamp(0, 240) + turn.$2.length.clamp(0, 360) + 24;
        if (used + size > budgetChars) break;
        picked.insert(0, turn);
        used += size;
      }
      if (picked.isNotEmpty) {
        b.writeln('Earlier in this conversation:');
        for (final (user, assistant) in picked) {
          b.writeln('User: ${clip(user, 240)}');
          b.writeln('Assistant: ${clip(assistant, 360)}');
        }
        b.writeln();
        b.writeln('New message:');
      }
    }
    for (final note in _notes) {
      b.writeln('($note)');
    }
    b.write(userText);
    return b.toString();
  }

  void _remember(String user, String assistant) {
    _transcript.add((user, assistant));
    if (_transcript.length > 6) _transcript.removeAt(0);
  }

  Future<AgentReply> run(
    String userText, {
    String? imagePath,
    required AgentEventSink sink,
    required ToolContext toolContext,
  }) async {
    final spec = _spec;
    if (_model == null || spec == null) {
      throw StateError('The on-device model isn\'t loaded.');
    }
    _busy = true;
    _stopRequested = false;
    final toolsUsed = <String>[];
    String? replyImage;
    var tokens = 0;
    var genSeconds = 0.0;

    AgentReply reply(String text, {bool stopped = false, bool isError = false}) =>
        AgentReply(
          text: text,
          modelLabel: spec.displayName,
          toolsUsed: toolsUsed,
          seconds: genSeconds,
          tokensPerSecond: genSeconds > 0 && tokens > 0 ? tokens / genSeconds : null,
          imagePath: replyImage,
          stopped: stopped,
          isError: isError,
        );

    try {
      sink.status('Thinking…');
      Uint8List? imageBytes;
      if (imagePath != null && spec.supportsVision) {
        imageBytes = await File(imagePath).readAsBytes();
      }

      await _ensureChat();
      var prompt = _composePrompt(userText);
      final imageTokens = imageBytes == null ? 0 : 300;
      if (_sessionTokens + estimateTokens(prompt) + imageTokens + _responseReserve >
          spec.contextTokens) {
        // Out of room: fresh session with a compact transcript.
        _chatDirty = true;
        await _ensureChat();
        prompt = _composePrompt(userText);
      }
      _replayPending = false;
      _notes.clear();
      if (_pendingToolResponse) {
        // A tool result from the previous turn is still queued; keep the new
        // message on its own line.
        prompt = '\n$prompt';
        _pendingToolResponse = false;
      }
      await _chat!.addQuery(imageBytes == null
          ? Message.text(text: prompt, isUser: true)
          : Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true));
      _sessionTokens += estimateTokens(prompt) + imageTokens;

      for (var step = 0; step < _maxSteps; step++) {
        final gen = await _generate(sink);
        tokens += gen.tokens;
        genSeconds += gen.seconds;
        _sessionTokens += estimateTokens(gen.text);

        if (_stopRequested) {
          final partial = cleanModelText(visiblePrefix(gen.text));
          final text = partial.isEmpty ? 'Stopped.' : partial;
          _remember(userText, text);
          return reply(text, stopped: true);
        }

        var calls = gen.calls;
        if (calls.isEmpty && _tools.isNotEmpty) {
          final recovered = extractToolCallFromText(gen.text, _toolNames);
          if (recovered != null) calls = [(recovered.name, recovered.args)];
        }

        if (calls.isEmpty) {
          final text = cleanModelText(gen.text);
          if (gen.looped || isDegenerateOutput(text)) {
            _chatDirty = true; // a looping session tends to keep looping
            sink.clear();
            return reply(
              'Sorry, I lost my train of thought. Please try again — a shorter '
              'question helps on-device models.',
              isError: true,
            );
          }
          _remember(userText, text);
          return reply(text);
        }

        sink.clear();
        final direct = <String>[];
        var allDirect = true;
        for (final (name, args) in calls.take(3)) {
          sink.status(toolStatusLabel(name));
          final result = await ToolRuntime.instance.execute(name, args, context: toolContext);
          toolsUsed.add(name);
          if (name == 'get_recent_screenshots') {
            final shots = result['screenshots'];
            if (shots is List && shots.isNotEmpty) {
              replyImage ??= (shots.first as Map)['path'] as String?;
            }
          }
          final fitted = ToolRuntime.fitToBudget(result, _toolResultChars);
          await _chat!.addQuery(Message.toolResponse(toolName: name, response: fitted));
          _sessionTokens += estimateTokens(jsonEncode(fitted)) + 16;
          final text = ToolRuntime.formatDirect(name, args, result);
          if (text == null) {
            allDirect = false;
          } else {
            direct.add(text);
          }
          if (_stopRequested) break;
        }

        if (_stopRequested) {
          _pendingToolResponse = true;
          final text = direct.isEmpty ? 'Stopped.' : direct.join('\n');
          _remember(userText, text);
          return reply(text, stopped: true);
        }

        if (allDirect) {
          // Every result has a plain-language template: reply now instead of
          // paying for another (slow, error-prone) on-device generation. The
          // tool result stays queued so the model sees it next turn.
          _pendingToolResponse = true;
          final text = direct.join('\n');
          _remember(userText, text);
          return reply(text);
        }
        sink.status('Thinking…');
      }

      return reply(
        'I couldn\'t finish that on-device. Try a simpler request, or switch to '
        'a cloud model in Settings for multi-step tasks.',
        isError: true,
      );
    } finally {
      _busy = false;
    }
  }

  Future<_Generation> _generate(AgentEventSink sink) async {
    final chat = _chat!;
    final text = StringBuffer();
    final calls = <(String, Map<String, dynamic>)>[];
    var tokens = 0;
    var looped = false;
    var shown = '';
    final sw = Stopwatch()..start();
    final done = Completer<void>();
    _activeDone = done;

    _activeSub = chat.generateChatResponseAsync().listen(
      (r) {
        if (r is TextResponse) {
          if (r.token.isEmpty) return;
          text.write(r.token);
          tokens++;
          final current = text.toString();
          final visible = cleanModelText(visiblePrefix(current));
          if (visible != shown) {
            shown = visible;
            if (visible.isNotEmpty) sink.partial(visible);
          }
          if (!looped && tokens > 40 && isStuckInLoop(current)) {
            looped = true;
            unawaited(_safeStop(chat));
          }
        } else if (r is FunctionCallResponse) {
          calls.add((r.name, Map<String, dynamic>.from(r.args)));
        } else if (r is ParallelFunctionCallResponse) {
          for (final c in r.calls) {
            calls.add((c.name, Map<String, dynamic>.from(c.args)));
          }
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      _activeSub = null;
      _activeDone = null;
      sw.stop();
    }
    return _Generation(
      text: text.toString(),
      calls: calls,
      tokens: tokens,
      seconds: sw.elapsedMilliseconds / 1000,
      looped: looped,
    );
  }

  /// Stops the current generation. If the native side doesn't end the
  /// stream promptly, the stream is abandoned and the session rebuilt on the
  /// next message rather than leaving the chat stuck on "Thinking…".
  Future<void> stop() async {
    if (!_busy) return;
    _stopRequested = true;
    final chat = _chat;
    if (chat != null) await _safeStop(chat);
    final done = _activeDone;
    if (done != null) {
      unawaited(Future.delayed(const Duration(seconds: 4), () {
        if (!done.isCompleted) {
          _activeSub?.cancel();
          _chatDirty = true;
          done.complete();
        }
      }));
    }
  }

  static Future<void> _safeStop(InferenceChat chat) async {
    try {
      await chat.stopGeneration();
    } catch (_) {
      // Already stopped / not supported.
    }
  }
}

class _Generation {
  final String text;
  final List<(String, Map<String, dynamic>)> calls;
  final int tokens;
  final double seconds;
  final bool looped;

  const _Generation({
    required this.text,
    required this.calls,
    required this.tokens,
    required this.seconds,
    required this.looped,
  });
}
