/// On-device models: a GGUF file (plus an optional vision projector) that
/// llama.cpp runs through llamadart. Curated models and models picked from
/// the Hugging Face hub share this type, so everything downstream (download,
/// load, settings, speed estimates) treats them the same way.
library;

/// Sampling defaults from the model card. Users can override them per model
/// in Settings → Model settings.
class SamplingDefaults {
  final double temperature;
  final int topK;
  final double topP;
  final double minP;
  final double repeatPenalty;

  /// Flat penalty on tokens already used (Qwen3.5 recommends 1.5 to stop
  /// small models repeating themselves).
  final double presencePenalty;

  const SamplingDefaults({
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.05,
    this.repeatPenalty = 1.0,
    this.presencePenalty = 0.0,
  });

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'minP': minP,
        'repeatPenalty': repeatPenalty,
        'presencePenalty': presencePenalty,
      };

  static SamplingDefaults fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SamplingDefaults();
    double d(String k, double fallback) => (json[k] as num?)?.toDouble() ?? fallback;
    return SamplingDefaults(
      temperature: d('temperature', 0.7),
      topK: (json['topK'] as num?)?.toInt() ?? 40,
      topP: d('topP', 0.9),
      minP: d('minP', 0.05),
      repeatPenalty: d('repeatPenalty', 1.0),
      presencePenalty: d('presencePenalty', 0.0),
    );
  }
}

/// How much of the tool catalog a model gets. Small models pick the wrong
/// tool when they see many (a 0.8B model opened YouTube when asked for the
/// flashlight), and phone actions are handled by the instant command router
/// anyway, so they only get the tools a router can't cover.
enum ToolUse {
  /// No tools: plain chat. Instant commands still work.
  none,

  /// Lookups only (web search, weather, date, device info).
  lookups,

  /// The full catalog.
  full,
}

class LocalModel {
  /// Stable identifier, also the key for per-model settings.
  final String id;
  final String name;

  /// Hugging Face repository, e.g. `unsloth/Qwen3.5-0.8B-GGUF`.
  final String repo;

  /// Commit the files are pinned to, so a resumed download never mixes bytes
  /// from two uploads.
  final String revision;
  final String file;
  final int sizeBytes;

  /// Vision projector (mmproj). Loaded only when an image is sent, so text
  /// chats don't pay its RAM.
  final String? mmprojFile;
  final int? mmprojSizeBytes;

  /// Short label on curated cards ("FASTEST").
  final String? tier;
  final String? tagline;
  final String? license;

  final ToolUse toolUse;
  final bool supportsThinking;
  final int defaultContext;
  final SamplingDefaults sampling;

  /// Rough ratio of weights read per generated token to file size. Gemma 4's
  /// per-layer embeddings are looked up, not multiplied, so it generates
  /// faster than its file size suggests.
  final double activeWeightFraction;

  /// Part of the curated catalog (tested with the app's prompts and tools).
  final bool curated;

  const LocalModel({
    required this.id,
    required this.name,
    required this.repo,
    required this.revision,
    required this.file,
    required this.sizeBytes,
    this.mmprojFile,
    this.mmprojSizeBytes,
    this.tier,
    this.tagline,
    this.license,
    this.toolUse = ToolUse.lookups,
    this.supportsThinking = false,
    this.defaultContext = 4096,
    this.sampling = const SamplingDefaults(),
    this.activeWeightFraction = 1.0,
    this.curated = false,
  });

  bool get supportsVision => mmprojFile != null;

  String get author => repo.split('/').first;

  /// Quantisation parsed from the file name ("Q4_K_M", "IQ4_XS", "BF16").
  String get quant => quantFromFileName(file) ?? 'GGUF';

  /// On-disk name. Hub files get the repo prefixed, since many repos ship a
  /// file called e.g. `model-Q4_K_M.gguf`.
  String get localFileName => curated ? file : '${_slug(repo)}__$file';
  String? get localMmprojName =>
      mmprojFile == null ? null : '${_slug(repo)}__${mmprojFile!}';

  String get downloadUrl => hfResolveUrl(repo, revision, file);
  String? get mmprojUrl =>
      mmprojFile == null ? null : hfResolveUrl(repo, revision, mmprojFile!);

  int get downloadBytes => sizeBytes + (mmprojSizeBytes ?? 0);

  /// RAM needed while chatting with [contextTokens] of context: weights
  /// (memory-mapped, but they are all touched), KV cache and compute
  /// buffers. Vision adds the projector.
  double ramNeededGB({int? contextTokens, bool withVision = false}) {
    final ctx = contextTokens ?? defaultContext;
    final weights = sizeBytes / _gb;
    final kvPer1k = weights < 1.5 ? 0.03 : 0.06;
    final vision = withVision && mmprojSizeBytes != null ? mmprojSizeBytes! / _gb : 0.0;
    return weights * 1.05 + ctx / 1024 * kvPer1k + 0.35 + vision;
  }

  String get sizeLabel => formatBytes(sizeBytes);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'repo': repo,
        'revision': revision,
        'file': file,
        'size': sizeBytes,
        if (mmprojFile != null) 'mmproj': mmprojFile,
        if (mmprojSizeBytes != null) 'mmprojSize': mmprojSizeBytes,
        if (license != null) 'license': license,
        'toolUse': toolUse.name,
        'thinking': supportsThinking,
        'ctx': defaultContext,
        'sampling': sampling.toJson(),
      };

  /// Hub models the user downloaded. Returns null for malformed entries.
  static LocalModel? fromJson(Map<String, dynamic> json) {
    final id = json['id'], repo = json['repo'], file = json['file'], size = json['size'];
    if (id is! String || repo is! String || file is! String || size is! num) return null;
    return LocalModel(
      id: id,
      name: (json['name'] as String?) ?? file,
      repo: repo,
      revision: (json['revision'] as String?) ?? 'main',
      file: file,
      sizeBytes: size.toInt(),
      mmprojFile: json['mmproj'] as String?,
      mmprojSizeBytes: (json['mmprojSize'] as num?)?.toInt(),
      license: json['license'] as String?,
      toolUse: ToolUse.values.firstWhere(
        (t) => t.name == json['toolUse'],
        orElse: () => ToolUse.lookups,
      ),
      supportsThinking: json['thinking'] == true,
      defaultContext: (json['ctx'] as num?)?.toInt() ?? 4096,
      sampling: SamplingDefaults.fromJson(json['sampling'] as Map<String, dynamic>?),
    );
  }

  LocalModel copyWith({String? mmprojFile, int? mmprojSizeBytes, bool clearMmproj = false}) =>
      LocalModel(
        id: id,
        name: name,
        repo: repo,
        revision: revision,
        file: file,
        sizeBytes: sizeBytes,
        mmprojFile: clearMmproj ? null : (mmprojFile ?? this.mmprojFile),
        mmprojSizeBytes: clearMmproj ? null : (mmprojSizeBytes ?? this.mmprojSizeBytes),
        tier: tier,
        tagline: tagline,
        license: license,
        toolUse: toolUse,
        supportsThinking: supportsThinking,
        defaultContext: defaultContext,
        sampling: sampling,
        activeWeightFraction: activeWeightFraction,
        curated: curated,
      );

  static const double _gb = 1024 * 1024 * 1024;
  static String _slug(String repo) => repo.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

String hfResolveUrl(String repo, String revision, String path) =>
    'https://huggingface.co/$repo/resolve/$revision/${path.split('/').map(Uri.encodeComponent).join('/')}';

final _quantPattern = RegExp(
  r'(?:^|[-_.])((?:UD-)?(?:I?Q\d(?:_[0-9A-Z]+)*|BF16|F16|F32|TQ\d_\d|MXFP4))(?=[-_.]|$)',
  caseSensitive: false,
);

/// "Qwen3.5-0.8B-UD-Q4_K_XL.gguf" → "UD-Q4_K_XL"; "model.q4_0.gguf" → "Q4_0".
String? quantFromFileName(String fileName) {
  final base = fileName.split('/').last.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '');
  final matches = _quantPattern.allMatches(base).toList();
  if (matches.isEmpty) return null;
  return matches.last.group(1)!.toUpperCase();
}

/// "Qwen3.5-0.8B-GGUF" → 0.8; "gemma-4-E2B-it" → 2; "LFM2.5-8B-A1B" → 8.
double? paramsFromName(String name) {
  final m = RegExp(r'(?:^|[-_/ .])E?(\d+(?:\.\d+)?)[Bb](?:[-_/ .]|$)').firstMatch(name);
  if (m == null) {
    final millions = RegExp(r'(?:^|[-_/ .])(\d{2,4})[Mm](?:[-_/ .]|$)').firstMatch(name);
    return millions == null ? null : double.parse(millions.group(1)!) / 1000;
  }
  return double.tryParse(m.group(1)!);
}

String formatBytes(num bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(mb >= 10240 ? 0 : 1)} GB';
  return '${mb.round()} MB';
}
