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

  /// Purpose-built for function calling — that's the actual job this app
  /// asks the local model to do most of the time ("turn on flashlight",
  /// "open Instagram", "find my PDFs"). Tradeoff: weak on open-ended chat
  /// because it's only 270M parameters. For anything that isn't an action,
  /// users can flip to cloud mode in Settings.
  ///
  /// Switched here from Gemma 4 E2B because the litertlm bundle of that
  /// model has `supportsFunctionCalls` disabled in the upstream
  /// flutter_gemma example with the comment "causes issues with
  /// multimodal" — native FC isn't reliable on that file regardless of
  /// how we wire the template.
  static const ModelSpec functionGemma270M = ModelSpec(
    id: 'function-gemma-270m',
    displayName: 'FunctionGemma 270M',
    fileName: 'functiongemma-270M-it.task',
    url:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task',
    sizeMB: 284,
    tagline: 'Tiny + tool-calling specialist. Pair with cloud for open chat.',
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.task,
    preferredBackend: PreferredBackend.gpu,
    supportsVision: false,
    supportsTools: true,
    isThinking: false,
    maxTokens: 1024,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    minRamGB: 2,
  );

  static const List<ModelSpec> all = [functionGemma270M];

  static ModelSpec byFileName(String fileName) {
    return all.firstWhere(
      (m) => m.fileName == fileName,
      orElse: () => functionGemma270M,
    );
  }

  static ModelSpec defaultForDevice(int? ramGB) => functionGemma270M;
}
