import 'package:flutter_gemma/flutter_gemma.dart';

/// Static description of a downloadable on-device model. Everything that
/// varies per model — download, sampling, context size, tool budget — lives
/// here, so adding a model is a data change. See MODELS.md for the history.
class ModelSpec {
  final String id;
  final String displayName;
  final String fileName;

  /// Pinned to a Hugging Face commit so the bytes never change under us:
  /// flutter_gemma 0.15.x bundles a specific LiteRT-LM runtime and newer
  /// exports of the same file name can require a newer runtime.
  final String url;

  /// Exact size of the file at [url]; a download is only accepted when it
  /// matches, which catches truncated downloads that used to leave a corrupt
  /// model on disk forever.
  final int sizeBytes;
  final String tier;
  final String tagline;

  final ModelType modelType;
  final ModelFileType fileType;

  final bool supportsVision;
  final bool supportsTools;

  /// Context window (input + output tokens) the model file was built for.
  final int contextTokens;
  final double temperature;
  final int topK;
  final double topP;

  /// Comfortable minimum device RAM.
  final int minRamGB;

  /// How many tools the model sees (see selectToolsForBudget). Each
  /// declaration costs context tokens and small models get confused by long
  /// tool lists.
  final int toolBudget;

  /// `.litertlm` models run on the LiteRT-LM runtime, which flutter_gemma
  /// only ships for arm64 Android (not x86_64 emulators/Waydroid).
  bool get arm64Only => fileType == ModelFileType.litertlm;

  final bool gpuCapable;

  /// Kept only so existing downloads keep working; not offered for new
  /// downloads.
  final bool legacy;

  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    required this.tier,
    required this.tagline,
    required this.modelType,
    required this.fileType,
    required this.supportsVision,
    required this.supportsTools,
    required this.contextTokens,
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.minRamGB,
    required this.toolBudget,
    this.gpuCapable = true,
    this.legacy = false,
  });

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.round()} MB';
  }
}

class ModelRegistry {
  ModelRegistry._();

  /// Lite: runs on almost any phone. Qwen3 was trained for tool use, and the
  /// 4096-token window leaves room for tools plus a few turns.
  /// Sampling follows Qwen's recommendation for non-thinking mode.
  static const ModelSpec qwen3Small = ModelSpec(
    id: 'qwen3-0.6b',
    displayName: 'Qwen3 0.6B',
    fileName: 'Qwen3-0.6B.litertlm',
    url: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
        'a3c5d805ae362dff7f580bc25f2dfb9a5a7eaa76/Qwen3-0.6B.litertlm',
    sizeBytes: 614236160,
    tier: 'FASTEST',
    tagline: 'Small and quick. Good for commands and short answers on any phone.',
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    supportsVision: false,
    supportsTools: true,
    contextTokens: 4096,
    temperature: 0.7,
    topK: 20,
    topP: 0.8,
    minRamGB: 3,
    toolBudget: 10,
  );

  /// Balanced: the model this app was tuned on, now in the 4096-token build
  /// (same download size as the 1280-token build the app used before, 3.2×
  /// the context — the old window overflowed after two tool calls).
  static const ModelSpec qwen25 = ModelSpec(
    id: 'qwen2.5-1.5b-4k',
    displayName: 'Qwen 2.5 1.5B',
    fileName: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task',
    url: 'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/'
        '19edb84c69a0212f29a6ef17ba0d6f278b6a1614/'
        'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task',
    sizeBytes: 1598556720,
    tier: 'BALANCED',
    tagline: 'Better answers and tool use. Works on most phones with 6 GB+ RAM.',
    modelType: ModelType.qwen,
    fileType: ModelFileType.task,
    supportsVision: false,
    supportsTools: true,
    contextTokens: 4096,
    temperature: 0.6,
    topK: 40,
    topP: 0.9,
    minRamGB: 4,
    toolBudget: 12,
  );

  /// Best: Gemma 4 has native function-calling tokens (the SDK parses them,
  /// no prompt-engineered JSON) and understands images. Apache-2.0, so the
  /// download isn't gated. Pinned to the revision flutter_gemma 0.15 was
  /// released against.
  static const ModelSpec gemma4E2b = ModelSpec(
    id: 'gemma-4-e2b',
    displayName: 'Gemma 4 E2B',
    fileName: 'gemma-4-E2B-it.litertlm',
    url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/'
        '6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm',
    sizeBytes: 2588147712,
    tier: 'SMARTEST',
    tagline: 'Most capable: reliable tool calls and image understanding. Flagship phones.',
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    supportsVision: true,
    supportsTools: true,
    contextTokens: 4096,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    minRamGB: 8,
    toolBudget: 30,
  );

  /// Legacy 1280-token builds from earlier versions of the app.
  static const ModelSpec qwen25Legacy = ModelSpec(
    id: 'qwen2.5-1.5b',
    displayName: 'Qwen 2.5 1.5B (old)',
    fileName: 'qwen2.5-1.5b-instruct-q8.task',
    url: 'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/'
        '19edb84c69a0212f29a6ef17ba0d6f278b6a1614/'
        'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    sizeBytes: 1597913616,
    tier: 'OLD BUILD',
    tagline: 'Short-context build from an earlier version. Replace with the new one.',
    modelType: ModelType.qwen,
    fileType: ModelFileType.task,
    supportsVision: false,
    supportsTools: true,
    contextTokens: 1280,
    temperature: 0.6,
    topK: 40,
    topP: 0.9,
    minRamGB: 4,
    toolBudget: 7,
    legacy: true,
  );

  static const ModelSpec phi4MiniLegacy = ModelSpec(
    id: 'phi-4-mini-instruct',
    displayName: 'Phi-4 mini (old)',
    fileName: 'Phi-4-mini-instruct_q8.task',
    url: 'https://huggingface.co/litert-community/Phi-4-mini-instruct/resolve/'
        '8cd368be75fdb94d5a6f6f5b40f1ab22a6c2543e/'
        'Phi-4-mini-instruct_multi-prefill-seq_q8_ekv1280.task',
    sizeBytes: 3944275882,
    tier: 'OLD BUILD',
    tagline: 'Large short-context model from an earlier version.',
    modelType: ModelType.phi,
    fileType: ModelFileType.task,
    supportsVision: false,
    supportsTools: true,
    contextTokens: 1280,
    temperature: 0.6,
    topK: 40,
    topP: 0.95,
    minRamGB: 6,
    toolBudget: 7,
    legacy: true,
  );

  /// Offered for download, lightest first.
  static const List<ModelSpec> downloadable = [qwen3Small, qwen25, gemma4E2b];

  static const List<ModelSpec> all = [
    ...downloadable,
    qwen25Legacy,
    phi4MiniLegacy,
  ];

  static ModelSpec? byFileName(String? fileName) {
    for (final m in all) {
      if (m.fileName == fileName) return m;
    }
    return null;
  }

  /// Specs this device can run at all.
  static List<ModelSpec> runnableOn({required bool arm64}) =>
      downloadable.where((m) => arm64 || !m.arm64Only).toList();

  /// Recommendation by RAM. RAM is a rough proxy for the SoC tier: phones
  /// with 12 GB+ are flagships that run Gemma 4 comfortably, mid-range 6–8 GB
  /// phones are happier with the 1.5B model, and anything smaller gets the
  /// 0.6B model.
  static ModelSpec recommendedFor({int? ramGB, required bool arm64}) {
    final ram = ramGB ?? 6;
    if (!arm64) return qwen25;
    if (ram >= 12) return gemma4E2b;
    if (ram >= 7) return qwen25;
    return qwen3Small;
  }
}
