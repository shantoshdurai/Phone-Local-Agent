import 'package:flutter_gemma/flutter_gemma.dart';

/// Static description of a downloadable on-device model.
///
/// One entry per `ModelSpec` lives in [ModelRegistry.all]. The rest of the app
/// — downloader, AgentService, ChatScreen picker, HomeScreen cards — reads
/// everything off the spec so swapping models is a data change, not a
/// scattered code change.
class ModelSpec {
  final String id;
  final String displayName;
  final String fileName;
  final String url;
  final int sizeMB;
  final String tagline;

  final ModelType modelType;
  final ModelFileType fileType;
  final PreferredBackend preferredBackend;

  final bool supportsVision;
  final bool supportsTools;
  final bool isThinking;

  final int maxTokens;
  final double temperature;
  final int topK;
  final double topP;

  /// Lowest device RAM (GB) at which this model is comfortable. The home
  /// screen picks the heaviest spec the device clears as the default.
  final int minRamGB;

  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.url,
    required this.sizeMB,
    required this.tagline,
    required this.modelType,
    required this.fileType,
    required this.preferredBackend,
    required this.supportsVision,
    required this.supportsTools,
    required this.isThinking,
    required this.maxTokens,
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.minRamGB,
  });

  String get sizeLabel {
    if (sizeMB >= 1024) {
      return '~${(sizeMB / 1024).toStringAsFixed(2)} GB';
    }
    return '~$sizeMB MB';
  }
}

class ModelRegistry {
  ModelRegistry._();

  /// Qwen 2.5 1.5B-Instruct, q8 quant with a 1280-token KV window.
  ///
  /// Config matches Google's official AI Edge Gallery model_allowlist.json
  /// entry for this exact .task file:
  ///   accelerators: "cpu", temperature 1.0, topK 40, topP 0.95, maxTokens 1024
  /// (https://github.com/google-ai-edge/gallery, model_allowlist.json).
  ///
  /// Why CPU and not GPU: on Qwen 2.5 1.5B q8 the Adreno/Mali GPU spends
  /// 60–120 s JIT-compiling compute shaders on first chat creation. CPU on
  /// any 8 Gen-1 / Tensor / Dimensity 7000+ class chip beats that wall-clock
  /// because there's no JIT cliff — first token streams within a second or
  /// two. Google's gallery defaults to CPU for the same reason.
  ///
  /// Why maxTokens 1024 not 1280: the .task file is built with `ekv1280`
  /// — 1280 is the hard KV-cache cap. Leaving a 256-token headroom matches
  /// Google's allowlist and keeps the system prompt + tool template +
  /// growing chat history from ever colliding with the cache ceiling
  /// (which is what produced the empty-reply + IllegalStateException
  /// cascade in earlier revisions).
  static const ModelSpec qwen2_5_1_5b = ModelSpec(
    id: 'qwen2.5-1.5b',
    displayName: 'Qwen 2.5 1.5B',
    fileName: 'qwen2.5-1.5b-instruct-q8.task',
    url:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    sizeMB: 1730,
    tagline: 'Chat + tool calls. Solid all-rounder, ~1.7 GB.',
    modelType: ModelType.qwen,
    fileType: ModelFileType.task,
    preferredBackend: PreferredBackend.cpu,
    supportsVision: false,
    supportsTools: true,
    isThinking: false,
    maxTokens: 1280,
    temperature: 1.0,
    topK: 40,
    topP: 0.95,
    minRamGB: 4,
  );

  // Phi-4 mini.
  //
  // Backend = GPU, not CPU. On MediaPipe's CPU/XNNPACK path the Phi
  // architecture's int8 kernels are buggy and the model emits repetition-
  // loop gibberish regardless of sampling (cf. mediapipe#5480 for Phi-2,
  // ollama#9423 for Phi-4-mini, and the Phi-4 multimodal HF discussion).
  // Symptoms we hit on x86_64 Waydroid before flipping the backend:
  //   - "编编编 / 度度度 / 名名名" CJK repetition under greedy sampling
  //   - "190 190 190" / "COMERIDERCOMERER…" subword loops under sane sampling
  // GPU first-run cost is the usual 10–20 s Adreno/Mali shader JIT; the
  // splash-screen warmup amortises that. Qwen stays on CPU because its
  // kernels work there and CPU avoids the shader cliff on most phones.
  //
  // Tools fit only if Phi's chat template + the system instruction +
  // flutter_gemma's hidden tool catalogue injection (~780 Phi tokens of
  // JSON for 22 tools) all live inside the .task file's ekv1280 KV
  // ceiling. With maxTokens raised to 1280 (the hard cap), short user
  // turns clear it; if a longer system prompt or extra tools are added
  // and OUT_OF_RANGE returns (current_step(935) + input_size(783) >
  // maxTokens(1024) on first turn was the original failure), trim tools
  // here or move to a larger-ekv variant.
  //
  // Sampling: litert-community / AI Edge Gallery defaults (temp 0.6,
  // topK 40, topP 0.95). Going near-greedy (the previous topK:1 / topP:0.1)
  // makes Phi-4 q8 degenerate — short prompts emit EOS instantly and longer
  // ones latch onto a single CJK-region token and repeat it for the rest of
  // the budget ("编编编 / 度度度 / 名名名").
  static const ModelSpec phi4_mini = ModelSpec(
    id: 'phi-4-mini-instruct',
    displayName: 'Phi-4 mini Instruct',
    fileName: 'Phi-4-mini-instruct_q8.task',
    url:
        'https://huggingface.co/litert-community/Phi-4-mini-instruct/resolve/main/Phi-4-mini-instruct_multi-prefill-seq_q8_ekv1280.task',
    sizeMB: 3800,
    tagline: 'Chat-focused. Strong general reasoning (~3.8 GB).',
    modelType: ModelType.phi,
    fileType: ModelFileType.task,
    preferredBackend: PreferredBackend.cpu,
    supportsVision: false,
    supportsTools: false,
    isThinking: false,
    maxTokens: 1280,
    temperature: 0.6,
    topK: 40,
    topP: 0.95,
    minRamGB: 6,
  );

  static const List<ModelSpec> all = [phi4_mini, qwen2_5_1_5b];

  static ModelSpec byFileName(String fileName) {
    return all.firstWhere(
      (m) => m.fileName == fileName,
      orElse: () => phi4_mini,
    );
  }

  static ModelSpec defaultForDevice(int? ramGB) {
    return qwen2_5_1_5b;
  }
}
