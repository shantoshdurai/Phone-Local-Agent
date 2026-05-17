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

  // Public HF mirror under the user's account. The original
  // `litert-community/Gemma3-1B-IT` is gated; this re-host removes the gate so
  // first-launch download is one tap. The .task is the multi-prefill q4 build
  // with a 2048-token ekv window — match maxTokens to that ceiling so the
  // system prompt + 20+ tool declarations (~1400 tokens) fit on first turn.
  static const String _gemma3_1bUrl =
      'https://huggingface.co/Santoshp123/Local-Agent/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task';

  static const ModelSpec gemma3_1bLite = ModelSpec(
    id: 'gemma3-1b-lite',
    displayName: 'Gemma 3 1B Lite',
    fileName: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task',
    url: _gemma3_1bUrl,
    sizeMB: 555,
    tagline: 'Fast on-device chat + native tool calls. Text only.',
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
    preferredBackend: PreferredBackend.gpu,
    supportsVision: false,
    supportsTools: true,
    isThinking: false,
    maxTokens: 2048,
    // Small models drift. Tighter sampling cuts the repetition loops the user
    // hit on Qwen3 0.6B and keeps Gemma 3 1B factual on tool-call args.
    temperature: 0.55,
    topK: 40,
    topP: 0.92,
    minRamGB: 3,
  );

  static const ModelSpec gemma4E2bVision = ModelSpec(
    id: 'gemma4-e2b',
    displayName: 'Gemma 4 E2B',
    fileName: 'gemma-4-E2B-it.litertlm',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    sizeMB: 2590,
    tagline: 'Multimodal — vision + reasoning + native tools.',
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    preferredBackend: PreferredBackend.gpu,
    supportsVision: true,
    supportsTools: true,
    isThinking: true,
    // 2048 is plenty for tool conversations and frees ~1 GB of KV vs the old
    // 4096 ceiling — that was the biggest single lag source on Dimensity-700
    // class devices.
    maxTokens: 2048,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    minRamGB: 6,
  );

  static const List<ModelSpec> all = [gemma3_1bLite, gemma4E2bVision];

  static ModelSpec byFileName(String fileName) {
    return all.firstWhere(
      (m) => m.fileName == fileName,
      orElse: () => gemma3_1bLite,
    );
  }

  /// Heaviest spec the device's RAM clears. Used for the home-screen default
  /// recommendation. Falls back to the lite model when RAM is unknown so
  /// low-end hardware never gets pushed into E2B by accident.
  static ModelSpec defaultForDevice(int? ramGB) {
    if (ramGB == null) return gemma3_1bLite;
    ModelSpec best = gemma3_1bLite;
    for (final spec in all) {
      if (ramGB >= spec.minRamGB && spec.sizeMB > best.sizeMB) {
        best = spec;
      }
    }
    return best;
  }
}
