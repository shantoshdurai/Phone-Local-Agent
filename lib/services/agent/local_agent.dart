import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import '../local/device_profile.dart';
import '../local/inference_settings.dart';
import '../local/local_engine.dart';
import '../local/local_model.dart';
import '../memory_service.dart';
import '../tools/tool_catalog.dart';
import '../tools/tool_runtime.dart';
import 'agent_types.dart';
import 'prompts.dart';
import 'text_utils.dart';

/// On-device agent on llama.cpp.
///
/// The conversation is kept as real chat messages (user, assistant, tool
/// calls, tool results) and rendered with the model's own chat template on
/// every step. llama.cpp keeps the previous prompt in its KV cache and only
/// processes what changed, so a long system prompt with tool declarations
/// is paid for once per chat, not per message.
class LocalAgent {
  LocalAgent({ToolExecutor? executeTool}) : _executeTool = executeTool ?? runTool;

  final LocalEngine _engine = LocalEngine.instance;
  final ToolExecutor _executeTool;

  LocalModel? _model;
  InferenceSettings? _settings;
  List<ToolSpec> _tools = const [];
  List<ToolDefinition> _defs = const [];
  final List<LlamaChatMessage> _history = [];
  String? _memoryBlock;

  bool _busy = false;
  bool _stopRequested = false;
  Future<void>? _warmup;

  static const int _maxSteps = 4;

  /// Receives raw model output and tool results; set by tests to diagnose
  /// prompts.
  static void Function(String message)? debugLog;
  static const int _maxHistoryMessages = 30;

  LocalModel? get model => _model;
  bool get isLoaded => _engine.isLoaded && _model != null;
  bool get usingGpu => _engine.usingGpu;
  bool get isBusy => _busy;
  InferenceSettings? get settings => _settings;
  bool get supportsVision => _model?.supportsVision ?? false;

  Set<String> get _toolNames => {for (final t in _tools) t.name};

  bool get _thinking => (_settings?.thinking ?? false) && (_model?.supportsThinking ?? false);

  /// Tool results are cut to fit the context window.
  int get _toolResultChars => (_settings?.contextSize ?? 4096) >= 8192
      ? 4000
      : ((_settings?.contextSize ?? 4096) >= 4096 ? 2000 : 800);

  Future<void> load(LocalModel model, {void Function(String status)? onStatus}) async {
    await _awaitWarmup(cancel: true);
    final device = await DeviceProfile.load();
    final settings = await InferenceSettingsStore.load(model, device);
    await _engine.load(model, settings, onStatus: onStatus);
    _model = model;
    _settings = settings;
    _configureTools();
    _memoryBlock = await MemoryService.instance.promptBlock();
    _scheduleWarmup();
  }

  /// Applies new settings; reloads the model only if context size, threads
  /// or GPU changed.
  Future<void> applySettings(InferenceSettings settings, {void Function(String status)? onStatus}) async {
    final model = _model;
    if (model == null) return;
    await InferenceSettingsStore.save(model, settings);
    final reload = _settings == null || settings.needsReloadComparedTo(_settings!);
    _settings = settings;
    if (reload) {
      await _awaitWarmup(cancel: true);
      await _engine.load(model, settings, onStatus: onStatus);
      _scheduleWarmup();
    }
  }

  Future<void> unload() async {
    await _awaitWarmup(cancel: true);
    await _engine.unload();
    _model = null;
    _settings = null;
    _tools = const [];
    _defs = const [];
  }

  void _configureTools() {
    final model = _model!;
    var use = model.toolUse;
    // Hub models whose chat template has no tool support get plain chat.
    if (!model.curated && !_engine.templateSupportsTools) use = ToolUse.none;
    _tools = switch (use) {
      ToolUse.none => const <ToolSpec>[],
      ToolUse.lookups => lookupTools(),
      ToolUse.full => selectToolsForBudget(14),
    };
    _defs = [for (final t in _tools) toToolDefinition(t)];
  }

  /// Converts a catalog entry to llamadart's typed declaration.
  static ToolDefinition toToolDefinition(ToolSpec spec) {
    final props = (spec.parameters['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    final required = spec.requiredParams.toSet();
    return ToolDefinition(
      name: spec.name,
      description: spec.localDescription,
      parameters: [
        for (final e in props.entries) _param(e.key, e.value as Map, required.contains(e.key)),
      ],
      // Tools are executed by ToolRuntime (with confirmations), not here.
      handler: (_) async => null,
    );
  }

  static ToolParam _param(String name, Map schema, bool required) {
    final description = schema['description'] as String?;
    final values = (schema['enum'] as List?)?.cast<String>();
    if (values != null) {
      return ToolParam.enumType(name, values: values, description: description, required: required);
    }
    return switch (schema['type']) {
      'integer' => ToolParam.integer(name, description: description, required: required),
      'number' => ToolParam.number(name, description: description, required: required),
      'boolean' => ToolParam.boolean(name, description: description, required: required),
      _ => ToolParam.string(name, description: description, required: required),
    };
  }

  String _systemPrompt() =>
      localSystemPrompt(DateTime.now(), tools: _toolNames, memory: _memoryBlock);

  // ---------------------------------------------------------------------
  // Warm-up: process the system prompt and tool declarations right after
  // loading, while the user is still typing, so the first reply starts fast.
  // Skipped for models that can't reuse a cached prompt.
  // ---------------------------------------------------------------------

  void _scheduleWarmup() {
    if (!_engine.cachesPrompt || _settings == null) return;
    _warmup = _runWarmup();
  }

  Future<void> _runWarmup() async {
    try {
      final messages = [
        LlamaChatMessage.fromText(role: LlamaChatRole.system, text: _systemPrompt()),
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hi'),
      ];
      final template = await _engine.render(messages, tools: _defs, thinking: _thinking);
      await for (final _ in _engine.generateRaw(template, messages, _settings!, maxTokens: 1)) {}
    } catch (_) {
      // Warm-up is best effort.
    }
  }

  Future<void> _awaitWarmup({bool cancel = false}) async {
    final w = _warmup;
    if (w == null) return;
    if (cancel) _engine.cancel();
    try {
      await w;
    } catch (_) {}
    _warmup = null;
  }

  // ---------------------------------------------------------------------
  // Conversation
  // ---------------------------------------------------------------------

  /// Starts a new conversation seeded with prior text exchanges.
  Future<void> resetConversation(List<(String, String)> exchanges) async {
    _history.clear();
    final recent = exchanges.length > 6 ? exchanges.sublist(exchanges.length - 6) : exchanges;
    for (final (user, assistant) in recent) {
      _history
        ..add(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: user))
        ..add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: assistant));
    }
    _memoryBlock = await MemoryService.instance.promptBlock();
  }

  /// Records an exchange the model didn't handle (an instant command).
  void addNote(String userText, String outcome) {
    _history
      ..add(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: userText))
      ..add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: outcome));
    _trimHistory();
  }

  Future<AgentReply> run(
    String userText, {
    String? imagePath,
    required AgentEventSink sink,
    required ToolContext toolContext,
  }) async {
    final model = _model;
    final settings = _settings;
    if (model == null || settings == null || !_engine.isLoaded) {
      throw StateError('The on-device model isn\'t loaded.');
    }
    _busy = true;
    _stopRequested = false;
    final toolsUsed = <String>[];
    String? replyImage;
    var stats = const GenerationStats();
    final sw = Stopwatch()..start();
    final turnStart = _history.length;

    AgentReply reply(String text, {bool stopped = false, bool isError = false}) => AgentReply(
          text: text,
          modelLabel: model.name,
          toolsUsed: toolsUsed,
          seconds: sw.elapsedMilliseconds / 1000,
          tokensPerSecond: stats.tokensPerSecond,
          imagePath: replyImage,
          stopped: stopped,
          isError: isError,
        );

    try {
      if (_warmup != null) {
        sink.status('Getting ready…');
        await _awaitWarmup();
      }

      if (imagePath != null) {
        if (!model.supportsVision) {
          return reply(
            '${model.name} can\'t look at images. Pick a model with the photo badge in '
            'Models, or switch to a cloud model.',
            isError: true,
          );
        }
        await _engine.ensureVision(onStatus: sink.status);
        final bytes = await File(imagePath).readAsBytes();
        _history.add(LlamaChatMessage.withContent(role: LlamaChatRole.user, content: [
          LlamaImageContent(bytes: bytes),
          LlamaTextContent(userText),
        ]));
        sink.status('Looking at the photo… this can take a while on a phone');
      } else {
        _history.add(LlamaChatMessage.fromText(role: LlamaChatRole.user, text: userText));
        sink.status('Thinking…');
      }

      var nudged = false;
      for (var step = 0; step < _maxSteps; step++) {
        final gen = await _generate(sink, settings, turnStart);
        stats = stats + gen.stats;

        if (_stopRequested) {
          final text = gen.visible.isEmpty ? 'Stopped.' : gen.visible;
          _history.add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: text));
          return reply(text, stopped: true);
        }

        var calls = gen.calls;
        if (calls.isEmpty && _tools.isNotEmpty) {
          final recovered = extractToolCallFromText(gen.raw, _toolNames);
          if (recovered != null) {
            calls = [_Call('local-${DateTime.now().microsecondsSinceEpoch}', recovered.name, recovered.args, null)];
          }
        }

        if (calls.isEmpty) {
          final text = gen.content;
          if (gen.looped || isDegenerateOutput(text)) {
            sink.clear();
            _history.removeRange(turnStart, _history.length);
            return reply(
              'Sorry, I lost my train of thought. Please try again. Shorter questions '
              'work best with on-device models.',
              isError: true,
            );
          }
          if (!nudged && _tools.isNotEmpty && step < _maxSteps - 1 && promisesAction(text)) {
            // It said what it would do but didn't call the tool: ask once.
            nudged = true;
            sink.clear();
            _history
              ..add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: text))
              ..add(const _NudgeTurn());
            continue;
          }
          _history.add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: text));
          return reply(text);
        }

        // A preamble ("Sure, let me check") is replaced by the result.
        sink.clear();
        _history.add(ToolCallTurn([
          if (gen.content.isNotEmpty) LlamaTextContent(gen.content),
          for (final c in calls)
            LlamaToolCallContent(
              id: c.id,
              name: c.name,
              arguments: c.args,
              rawJson: c.invalidJson ?? jsonEncode(c.args),
            ),
        ]));

        final direct = <String>[];
        var allDirect = true;
        for (final call in calls.take(3)) {
          sink.status(toolStatusLabel(call.name));
          final Map<String, dynamic> result;
          if (call.invalidJson != null) {
            result = {'error': 'INVALID_JSON: the arguments were not valid JSON. Call the tool again with valid JSON.'};
          } else if (!_toolNames.contains(call.name)) {
            result = {'error': 'Unknown tool "${call.name}". Use only the listed tools.'};
          } else {
            result = await _executeTool(call.name, call.args, toolContext);
          }
          toolsUsed.add(call.name);
          debugLog?.call('TOOL ${call.name} → ${jsonEncode(result).length > 600 ? '${jsonEncode(result).substring(0, 600)}…' : jsonEncode(result)}');
          if (call.name == 'get_recent_screenshots') {
            final shots = result['screenshots'];
            if (shots is List && shots.isNotEmpty) {
              replyImage ??= (shots.first as Map)['path'] as String?;
            }
          }
          _history.add(ToolResultTurn(
            call.id,
            call.name,
            jsonEncode(ToolRuntime.fitToBudget(result, _toolResultChars)),
          ));
          final text = call.invalidJson == null ? ToolRuntime.formatDirect(call.name, call.args, result) : null;
          if (text == null) {
            allDirect = false;
          } else {
            direct.add(text);
          }
          if (_stopRequested) break;
        }

        if (_stopRequested || allDirect) {
          // Every result has a plain-language sentence: answer now instead of
          // paying for another (slow on a phone) generation.
          final text = direct.isEmpty ? 'Stopped.' : direct.join('\n');
          _history.add(LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: text));
          return reply(text, stopped: _stopRequested);
        }
        sink.status('Reading the results…');
      }

      return reply(
        'I couldn\'t finish that on-device. Try a simpler request, or switch to a cloud '
        'model for multi-step tasks.',
        isError: true,
      );
    } catch (e) {
      // Leave no half-finished turn behind.
      if (_history.length > turnStart) _history.removeRange(turnStart, _history.length);
      rethrow;
    } finally {
      _busy = false;
      _dropNudges();
      _dropImagesFromHistory();
      _trimHistory();
      if (stats.generatedTokens >= 16) unawaited(_engine.recordSpeed(stats));
    }
  }

  Future<_Generation> _generate(AgentEventSink sink, InferenceSettings settings, int turnStart) async {
    final system = LlamaChatMessage.fromText(role: LlamaChatRole.system, text: _systemPrompt());
    final reserve = math.min(settings.maxTokens, math.max(256, settings.contextSize ~/ 4));

    // Fit the context window by dropping the oldest turns (never the current
    // one).
    late List<LlamaChatMessage> messages;
    late LlamaChatTemplateResult template;
    late int promptTokens;
    var start = turnStart;
    while (true) {
      messages = [system, ..._history];
      template = await _engine.render(messages, tools: _defs, thinking: _thinking);
      promptTokens = template.tokenCount ?? estimateTokens(template.prompt);
      if (promptTokens + reserve <= settings.contextSize) break;
      final cut = _oldestTurnEnd();
      if (cut == null || cut > start) {
        throw StateError(
          'That\'s too long for ${_model!.name}\'s ${settings.contextSize}-token memory. '
          'Start a new chat, or raise the context size in Model settings.',
        );
      }
      _history.removeRange(0, cut);
      start -= cut;
    }

    final maxTokens = math.max(64, math.min(settings.maxTokens, settings.contextSize - promptTokens));
    final raw = StringBuffer();
    var shown = '';
    var looped = false;
    var lastParse = DateTime.fromMillisecondsSinceEpoch(0);

    await for (final piece in _engine.generateRaw(template, messages, settings, maxTokens: maxTokens)) {
      raw.write(piece);
      final now = DateTime.now();
      if (now.difference(lastParse).inMilliseconds >= 120) {
        lastParse = now;
        final text = raw.toString();
        final partial = LocalEngine.parse(template, text, tools: _defs, partial: true);
        final visible = cleanModelText(visiblePrefix(partial.content));
        if (visible.isEmpty && (partial.reasoningContent?.isNotEmpty ?? false)) {
          sink.status('Thinking it through…');
        }
        if (visible != shown && visible.isNotEmpty) {
          shown = visible;
          sink.partial(visible);
        }
        if (!looped && text.length > 200 && isStuckInLoop(text)) {
          looped = true;
          _engine.cancel();
        }
      }
    }

    final text = raw.toString();
    debugLog?.call('PROMPT TOKENS $promptTokens\nRAW OUTPUT: $text');
    final parsed = LocalEngine.parse(template, text, tools: _defs);
    final calls = <_Call>[];
    var index = 0;
    for (final tc in parsed.toolCalls) {
      final name = tc.function?.name;
      if (name == null || name.isEmpty) continue;
      final argsRaw = tc.function?.arguments ?? '{}';
      Map<String, dynamic>? args;
      try {
        final decoded = argsRaw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(argsRaw);
        if (decoded is Map) args = Map<String, dynamic>.from(decoded);
      } catch (_) {}
      calls.add(_Call(
        tc.id ?? 'local-${DateTime.now().microsecondsSinceEpoch}-${index++}',
        name,
        args ?? const {},
        args == null ? argsRaw : null,
      ));
    }
    final content = cleanModelText(parsed.content);
    return _Generation(
      raw: text,
      content: content,
      visible: cleanModelText(visiblePrefix(content)),
      calls: calls,
      stats: await _engine.lastStats(),
      looped: looped,
    );
  }

  /// Index just past the oldest complete turn (user message plus everything
  /// up to the next user message), or null if there's only one turn.
  int? _oldestTurnEnd() {
    for (var i = 1; i < _history.length; i++) {
      if (_history[i].role == LlamaChatRole.user) return i;
    }
    return null;
  }

  void _trimHistory() {
    while (_history.length > _maxHistoryMessages) {
      final cut = _oldestTurnEnd();
      if (cut == null) break;
      _history.removeRange(0, cut);
    }
  }

  /// Removes nudges and the announcements that prompted them, so they don't
  /// linger in later turns.
  void _dropNudges() {
    for (var i = _history.length - 1; i >= 0; i--) {
      if (_history[i] is _NudgeTurn) {
        _history.removeAt(i);
        if (i > 0 && _history[i - 1].role == LlamaChatRole.assistant) _history.removeAt(i - 1);
      }
    }
  }

  /// Images are re-encoded every time they are in the prompt (slow on a
  /// phone), so after their turn they become a text note.
  void _dropImagesFromHistory() {
    for (var i = 0; i < _history.length; i++) {
      final m = _history[i];
      if (!m.parts.any((p) => p is LlamaImageContent)) continue;
      final text = m.parts.whereType<LlamaTextContent>().map((p) => p.text).join(' ').trim();
      _history[i] = LlamaChatMessage.fromText(
        role: m.role,
        text: '(The user shared a photo.) $text'.trim(),
      );
    }
  }

  /// Stops the current reply; the stream ends at the next token.
  Future<void> stop() async {
    if (!_busy) return;
    _stopRequested = true;
    _engine.cancel();
  }

  /// Measures tokens per second with the loaded model.
  Future<GenerationStats> benchmark() async {
    await _awaitWarmup();
    return _engine.benchmark();
  }
}

/// An assistant turn that called tools. llamadart hands tool-call arguments
/// to chat templates as a JSON string, but Hugging Face templates take an
/// object (Gemma 4's raises an error on a string), so they're decoded here.
class ToolCallTurn extends LlamaChatMessage {
  const ToolCallTurn(List<LlamaContentPart> content)
      : super.withContent(role: LlamaChatRole.assistant, content: content);

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    final calls = json['tool_calls'];
    if (calls is List) {
      // Rebuilt rather than mutated: llamadart's maps are Map<String, String>.
      json['tool_calls'] = [
        for (final c in calls)
          if (c is Map && c['function'] is Map)
            {
              ...c,
              'function': {
                ...(c['function'] as Map),
                'arguments': _decodeArguments((c['function'] as Map)['arguments']),
              },
            }
          else
            c,
      ];
    }
    return json;
  }

  static Object? _decodeArguments(Object? raw) {
    if (raw is! String) return raw;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded : raw;
    } catch (_) {
      return raw;
    }
  }
}

/// A tool result in the OpenAI shape (`role: tool`, `tool_call_id`, `name`,
/// `content`) that chat templates read. llamadart's Gemma 4 path otherwise
/// emits a shape the template drops, so the model never saw the result.
class ToolResultTurn extends LlamaChatMessage {
  final String callId;
  final String toolName;
  final String body;

  ToolResultTurn(this.callId, this.toolName, this.body)
      : super.fromText(role: LlamaChatRole.tool, text: body);

  @override
  List<LlamaContentPart> get parts => [LlamaTextContent(body)];

  @override
  Map<String, dynamic> toJson() =>
      {'role': 'tool', 'tool_call_id': callId, 'name': toolName, 'content': body};
}

/// Follow-up sent when the model announced an action without taking it.
class _NudgeTurn extends LlamaChatMessage {
  const _NudgeTurn()
      : super.fromText(
          role: LlamaChatRole.user,
          text: 'Go ahead and do it now: call the tool, or answer from the results you already have.',
        );
}

class _Call {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  /// Raw arguments when they weren't valid JSON.
  final String? invalidJson;

  const _Call(this.id, this.name, this.args, this.invalidJson);
}

class _Generation {
  final String raw;
  final String content;
  final String visible;
  final List<_Call> calls;
  final GenerationStats stats;
  final bool looped;

  const _Generation({
    required this.raw,
    required this.content,
    required this.visible,
    required this.calls,
    required this.stats,
    required this.looped,
  });
}
