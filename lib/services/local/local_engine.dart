import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../model_downloader_service.dart';
import 'device_profile.dart';
import 'inference_settings.dart';
import 'local_model.dart';

/// Timings for one generation, from llama.cpp's own counters.
class GenerationStats {
  final int promptTokens;
  final double promptSeconds;
  final int generatedTokens;
  final double generateSeconds;

  const GenerationStats({
    this.promptTokens = 0,
    this.promptSeconds = 0,
    this.generatedTokens = 0,
    this.generateSeconds = 0,
  });

  double? get tokensPerSecond =>
      generateSeconds > 0 && generatedTokens > 0 ? generatedTokens / generateSeconds : null;

  double? get promptTokensPerSecond =>
      promptSeconds > 0 && promptTokens > 0 ? promptTokens / promptSeconds : null;

  GenerationStats operator +(GenerationStats o) => GenerationStats(
        promptTokens: promptTokens + o.promptTokens,
        promptSeconds: promptSeconds + o.promptSeconds,
        generatedTokens: generatedTokens + o.generatedTokens,
        generateSeconds: generateSeconds + o.generateSeconds,
      );
}

/// Owns the llama.cpp engine: one model at a time, loaded with the user's
/// settings, with the vision projector attached only when an image is sent.
class LocalEngine {
  LocalEngine._();
  static final LocalEngine instance = LocalEngine._();

  LlamaEngine? _engine;
  LocalModel? _model;
  InferenceSettings? _loadedWith;
  bool _visionLoaded = false;
  bool _usingGpu = false;
  bool? _templateHasTools;
  String? _architecture;

  LocalModel? get model => _model;
  bool get isLoaded => _engine != null && _model != null;
  bool get usingGpu => _usingGpu;
  bool get visionLoaded => _visionLoaded;
  InferenceSettings? get loadedSettings => _loadedWith;

  /// Whether the model's chat template knows about tools. Hub models without
  /// one get plain chat (tool JSON pasted into a template that ignores it
  /// just confuses them).
  bool get templateSupportsTools => _templateHasTools ?? false;

  /// llama.cpp architecture name from the GGUF metadata ("gemma4", "qwen35").
  String? get architecture => _architecture;

  /// Whether llama.cpp can reuse the cached prompt prefix between messages.
  /// Recurrent and hybrid models (Qwen3.5, LFM2, Mamba, RWKV...) keep state
  /// that can't be rolled back to a prefix, so they re-read the whole prompt
  /// every time; warming them up is wasted work.
  bool get cachesPrompt => !isRecurrentArchitecture(_architecture);

  static bool isRecurrentArchitecture(String? arch) {
    if (arch == null) return false;
    const markers = [
      'mamba', 'rwkv', 'lfm2', 'hybrid', 'jamba', 'qwen35', 'qwen3next',
      'falcon-h1', 'falcon_h1', 'nemotron_h', 'plamo2', 'kimi_linear', 'granitemoehybrid',
    ];
    final a = arch.toLowerCase();
    return markers.any(a.contains);
  }

  LlamaEngine get _ready {
    final e = _engine;
    if (e == null) throw StateError('No on-device model is loaded.');
    return e;
  }

  /// Loads [model]. A no-op if it's already loaded with compatible settings.
  /// GPU loading falls back to the CPU instead of failing.
  Future<void> load(
    LocalModel model,
    InferenceSettings settings, {
    void Function(String status)? onStatus,
  }) async {
    if (isLoaded &&
        _model!.id == model.id &&
        _loadedWith != null &&
        !settings.needsReloadComparedTo(_loadedWith!)) {
      _loadedWith = settings;
      return;
    }
    await unload();

    final downloader = ModelDownloaderService();
    final path = await downloader.pathFor(model.localFileName);
    if (!await File(path).exists()) {
      throw StateError('${model.name} isn\'t downloaded yet.');
    }

    LlamaEngine.configureLogging(level: kDebugMode ? LlamaLogLevel.warn : LlamaLogLevel.none);
    final device = await DeviceProfile.load();
    final threads = settings.threads > 0 ? settings.threads : device.recommendedThreads;

    ModelParams params({required bool gpu}) => ModelParams(
          contextSize: settings.contextSize,
          gpuLayers: gpu ? ModelParams.maxGpuLayers : 0,
          preferredBackend: gpu ? GpuBackend.opencl : GpuBackend.cpu,
          numberOfThreads: threads,
          numberOfThreadsBatch: settings.threads > 0 ? settings.threads : device.recommendedBatchThreads,
          // Prompt chunks: smaller batches keep peak RAM down on phones.
          batchSize: 512,
          microBatchSize: 256,
        );

    onStatus?.call('Loading ${model.name}');
    var engine = LlamaEngine(LlamaBackend());
    var gpu = false;
    try {
      if (settings.useGpu) {
        try {
          await engine.loadModel(path, modelParams: params(gpu: true));
          gpu = true;
        } catch (e) {
          debugPrint('[LocalEngine] GPU load failed, using CPU: $e');
          await _dispose(engine);
          engine = LlamaEngine(LlamaBackend());
          onStatus?.call('GPU unavailable, loading on CPU');
        }
      }
      if (!gpu) await engine.loadModel(path, modelParams: params(gpu: false));
    } catch (e) {
      await _dispose(engine);
      throw StateError(_loadError(model, e));
    }

    _engine = engine;
    _model = model;
    _loadedWith = settings;
    _usingGpu = gpu;
    _visionLoaded = false;
    try {
      final meta = await engine.getMetadata();
      final template = meta['tokenizer.chat_template'] ?? '';
      _templateHasTools = template.contains('tool');
      _architecture = meta['general.architecture'];
    } catch (_) {
      _templateHasTools = null;
      _architecture = null;
    }
  }

  /// Attaches the vision projector (downloaded separately) before the first
  /// image. Throws a user-readable [StateError] if it's missing.
  Future<void> ensureVision({void Function(String status)? onStatus}) async {
    final model = _model;
    final engine = _ready;
    if (_visionLoaded) return;
    final name = model?.localMmprojName;
    if (model == null || name == null) {
      throw StateError('${model?.name ?? 'This model'} can\'t read images. '
          'Pick a model with the vision badge, or use a cloud model.');
    }
    final path = await ModelDownloaderService().pathFor(name);
    if (!await File(path).exists()) {
      throw StateError('The vision add-on for ${model.name} isn\'t downloaded. '
          'Open Models → ${model.name} to get it.');
    }
    onStatus?.call('Loading image support…');
    try {
      await engine.loadMultimodalProjector(path);
      _visionLoaded = true;
    } catch (e) {
      throw StateError('Couldn\'t load image support for ${model.name}: ${_short(e)}');
    }
  }

  /// Renders [messages] (and tool declarations) with the model's chat
  /// template. `tokenCount` is the exact prompt length.
  Future<LlamaChatTemplateResult> render(
    List<LlamaChatMessage> messages, {
    List<ToolDefinition>? tools,
    bool thinking = false,
  }) =>
      _ready.chatTemplate(
        messages,
        tools: (tools == null || tools.isEmpty) ? null : tools,
        enableThinking: thinking,
        includeTokenCount: true,
      );

  /// Generates from a rendered prompt. The whole conversation is rendered
  /// every time; llama.cpp reuses the cached prefix, so on most models only
  /// the new tokens are processed.
  ///
  /// This deliberately skips the tool-call grammar that `LlamaEngine.create`
  /// applies: llama.cpp's grammar sampler throws a C++ exception when a
  /// model keeps writing after a finished call ("Unexpected empty grammar
  /// stack"), which aborts the whole app through FFI. Tool calls are parsed
  /// from the text afterwards with the same format handlers instead.
  Stream<String> generateRaw(
    LlamaChatTemplateResult template,
    List<LlamaChatMessage> messages,
    InferenceSettings settings, {
    int? maxTokens,
    int? seed,
  }) {
    final media = messages
        .expand((m) => m.parts)
        .where((p) => p is LlamaImageContent || p is LlamaAudioContent)
        .toList();
    return _ready.generate(
      template.prompt,
      params: GenerationParams(
        maxTokens: maxTokens ?? settings.maxTokens,
        temp: settings.temperature,
        topK: settings.topK,
        topP: settings.topP,
        minP: settings.minP,
        penalty: settings.repeatPenalty,
        presencePenalty: settings.presencePenalty,
        seed: seed,
        stopSequences: template.stopSequences,
        preservedTokens: template.preservedTokens,
        // Smooth streaming on slow phones: flush every couple of tokens.
        streamBatchTokenThreshold: 2,
        streamBatchByteThreshold: 64,
      ),
      parts: media.isEmpty ? null : media,
    );
  }

  /// Splits raw output into reply text, reasoning and tool calls using the
  /// model family's own format (Hermes JSON, Qwen XML, Gemma 4, LFM2...).
  static ChatParseResult parse(
    LlamaChatTemplateResult template,
    String raw, {
    List<ToolDefinition>? tools,
    bool partial = false,
  }) {
    try {
      return ChatTemplateEngine.parse(
        template.format,
        raw,
        isPartial: partial,
        parseToolCalls: tools != null && tools.isNotEmpty,
        thinkingForcedOpen: template.thinkingForcedOpen,
        parser: template.parser,
        tools: tools,
      );
    } catch (_) {
      return ChatParseResult(content: raw);
    }
  }

  Future<int> countTokens(String text) async {
    try {
      return await _ready.getTokenCount(text);
    } catch (_) {
      return (text.length / 3.5).ceil();
    }
  }

  /// Timings of the most recent generation. llama.cpp's counters are reset
  /// at the start of each generation, so they describe exactly one run.
  Future<GenerationStats> lastStats() async {
    try {
      final p = await _engine?.getPerformanceContext();
      if (p == null) return const GenerationStats();
      return GenerationStats(
        promptTokens: p.promptEvalTokens,
        promptSeconds: p.promptEvalMs / 1000,
        generatedTokens: p.evalTokens,
        generateSeconds: p.evalMs / 1000,
      );
    } catch (_) {
      return const GenerationStats();
    }
  }

  void cancel() {
    try {
      _engine?.cancelGeneration();
    } catch (_) {}
  }

  /// Generates a fixed short reply to measure this phone's speed with the
  /// loaded model, and remembers the result for speed estimates.
  Future<GenerationStats> benchmark() async {
    final settings = _loadedWith;
    if (settings == null) throw StateError('No on-device model is loaded.');
    const messages = [
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Write a short paragraph about the ocean.',
      ),
    ];
    final template = await render(messages);
    final sw = Stopwatch()..start();
    var chars = 0;
    await for (final piece in generateRaw(template, messages, settings, maxTokens: 96, seed: 42)) {
      chars += piece.length;
    }
    sw.stop();
    var stats = await lastStats();
    if (stats.generatedTokens == 0) {
      // Backend without perf counters: estimate from wall time.
      stats = GenerationStats(
        generatedTokens: (chars / 3.8).round(),
        generateSeconds: sw.elapsedMilliseconds / 1000,
      );
    }
    await recordSpeed(stats);
    return stats;
  }

  /// Feeds a real generation into the phone's speed estimate.
  Future<void> recordSpeed(GenerationStats stats) async {
    final tps = stats.tokensPerSecond;
    final model = _model;
    if (tps == null || model == null) return;
    await DeviceProfile.recordSpeed(
      tokensPerSecond: tps,
      activeWeightsGB: model.sizeBytes / (1024 * 1024 * 1024) * model.activeWeightFraction,
      generatedTokens: stats.generatedTokens,
    );
  }

  Future<void> unload() async {
    final engine = _engine;
    _engine = null;
    _model = null;
    _loadedWith = null;
    _visionLoaded = false;
    _usingGpu = false;
    _templateHasTools = null;
    _architecture = null;
    if (engine != null) await _dispose(engine);
  }

  static Future<void> _dispose(LlamaEngine engine) async {
    try {
      await engine.dispose();
    } catch (e) {
      debugPrint('[LocalEngine] dispose failed: $e');
    }
  }

  static String _short(Object e) {
    final s = e is LlamaException ? e.message : e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  static String _loadError(LocalModel model, Object e) {
    final s = _short(e).toLowerCase();
    if (s.contains('memory') || s.contains('alloc')) {
      return 'Not enough free memory to load ${model.name}. Close other apps, lower the '
          'context size in Model settings, or pick a smaller model.';
    }
    if (s.contains('unknown model architecture') || s.contains('unsupported')) {
      return '${model.name} uses an architecture this version of the app can\'t run yet.';
    }
    if (s.contains('invalid') || s.contains('magic') || s.contains('failed to read')) {
      return 'The ${model.name} file looks damaged. Delete it in Models and download it again.';
    }
    return 'Couldn\'t load ${model.name}: ${_short(e)}';
  }
}
