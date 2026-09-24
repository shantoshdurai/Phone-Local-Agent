import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../model_downloader_service.dart';
import 'device_profile.dart';
import 'local_model.dart';

/// Curated models, tested with this app's prompts and tools (see MODELS.md
/// for the evaluation), plus whatever the user downloads from the hub.
class ModelCatalog {
  ModelCatalog._();

  /// Tiny and quick; understands images. Too small to pick the right tool
  /// out of many (in testing it opened YouTube when asked for the
  /// flashlight), so it only gets lookups; phone actions go through the
  /// instant command router. Its hybrid architecture can't reuse the cached
  /// prompt, so every reply re-reads the conversation; fine at this size.
  static const qwen35Small = LocalModel(
    id: 'qwen3.5-0.8b',
    name: 'Qwen3.5 0.8B',
    repo: 'unsloth/Qwen3.5-0.8B-GGUF',
    revision: '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0',
    file: 'Qwen3.5-0.8B-Q4_K_M.gguf',
    sizeBytes: 532517120,
    mmprojFile: 'mmproj-F16.gguf',
    mmprojSizeBytes: 204987232,
    tier: 'FASTEST',
    tagline: 'Quick answers on almost any phone. Can look at photos.',
    license: 'Apache 2.0',
    toolUse: ToolUse.lookups,
    supportsThinking: true,
    sampling: SamplingDefaults(
      temperature: 0.7,
      topK: 20,
      topP: 0.8,
      minP: 0,
      presencePenalty: 1.5,
    ),
    curated: true,
  );

  /// Mid-range phones: honest (offers to search instead of inventing
  /// answers) and picked the right tool for timers, alarms, weather, search
  /// and apps in testing. Standard attention, so the system prompt and tools
  /// are cached after the first message and later replies start quickly.
  static const miniCpm = LocalModel(
    id: 'minicpm5-2b',
    name: 'MiniCPM5 2B',
    repo: 'openbmb/MiniCPM5-2B-GGUF',
    revision: '2079a22f3beaa4e306449978533478fe0522f4b3',
    file: 'MiniCPM5-2B-Q4_K_M.gguf',
    sizeBytes: 1561318368,
    tier: 'BALANCED',
    tagline: 'Good answers and reliable phone actions. For phones with 6 GB+ RAM.',
    license: 'Apache 2.0',
    toolUse: ToolUse.full,
    supportsThinking: true,
    // Model card: min_p must be 0 (llama.cpp's 0.05 default causes loops).
    sampling: SamplingDefaults(temperature: 1.0, topK: 0, topP: 0.95, minP: 0, repeatPenalty: 1.05),
    curated: true,
  );

  /// Google's quantisation-aware Q4_0 build: near full-precision quality at
  /// 4 bits. Best tool use of the models we tested. Its per-layer
  /// embeddings are looked up rather than multiplied, so it generates
  /// faster than the 3.3 GB file suggests.
  static const gemma4 = LocalModel(
    id: 'gemma-4-e2b',
    name: 'Gemma 4 E2B',
    repo: 'google/gemma-4-E2B-it-qat-q4_0-gguf',
    revision: '675cff42a74c774d6cb76f76d8eacb49b48c9b93',
    file: 'gemma-4-E2B_q4_0-it.gguf',
    sizeBytes: 3349516256,
    mmprojFile: 'gemma-4-E2B-it-mmproj.gguf',
    mmprojSizeBytes: 986833664,
    tier: 'SMARTEST',
    tagline: 'Most capable: best at using tools, understands photos. Needs 8 GB+ RAM.',
    license: 'Apache 2.0',
    toolUse: ToolUse.full,
    supportsThinking: true,
    sampling: SamplingDefaults(temperature: 1.0, topK: 64, topP: 0.95, minP: 0),
    activeWeightFraction: 0.45,
    curated: true,
  );

  /// Flagships (12 GB+): the larger Gemma 4, noticeably better at reasoning
  /// and long answers.
  static const gemma4Large = LocalModel(
    id: 'gemma-4-e4b',
    name: 'Gemma 4 E4B',
    repo: 'google/gemma-4-E4B-it-qat-q4_0-gguf',
    revision: '4b4a2c1d584be7264f87aac328a1bc739ce81b6c',
    file: 'gemma-4-E4B_q4_0-it.gguf',
    sizeBytes: 5154941280,
    mmprojFile: 'gemma-4-E4B-it-mmproj.gguf',
    mmprojSizeBytes: 991552256,
    tier: 'BEST',
    tagline: 'Best quality on-device. For flagships with 12 GB+ RAM.',
    license: 'Apache 2.0',
    toolUse: ToolUse.full,
    supportsThinking: true,
    sampling: SamplingDefaults(temperature: 1.0, topK: 64, topP: 0.95, minP: 0),
    activeWeightFraction: 0.5,
    curated: true,
  );

  /// Lightest first.
  static const List<LocalModel> curated = [qwen35Small, miniCpm, gemma4, gemma4Large];

  static const _kHubModels = 'hub_models_v1';

  /// Hub models the user has added (downloaded or downloading).
  static Future<List<LocalModel>> hubModels() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_kHubModels);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(LocalModel.fromJson)
          .whereType<LocalModel>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addHubModel(LocalModel model) async {
    final list = (await hubModels()).where((m) => m.id != model.id).toList()..add(model);
    await _saveHub(list);
  }

  static Future<void> removeHubModel(String id) async =>
      _saveHub((await hubModels()).where((m) => m.id != id).toList());

  static Future<void> _saveHub(List<LocalModel> list) async =>
      (await SharedPreferences.getInstance())
          .setString(_kHubModels, jsonEncode([for (final m in list) m.toJson()]));

  static Future<List<LocalModel>> all() async => [...curated, ...await hubModels()];

  static Future<LocalModel?> byId(String? id) async {
    if (id == null) return null;
    for (final m in await all()) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Models whose main file is fully downloaded.
  static Future<List<LocalModel>> downloaded() async {
    final downloader = ModelDownloaderService();
    final out = <LocalModel>[];
    for (final m in await all()) {
      if (await downloader.isModelDownloaded(m.localFileName)) out.add(m);
    }
    return out;
  }

  /// The curated model that suits this phone best, or null when even the
  /// smallest won't fit (the app then suggests a cloud model).
  ///
  /// Gemma 4 E2B generates about as fast as a 2B model (its per-layer
  /// embeddings are looked up, not multiplied), so any phone with the RAM
  /// for it gets it; E4B only on flagships where it stays responsive.
  ///
  /// Bigger models are only recommended with room to spare (a tight fit
  /// means Android kills other apps and replies crawl); the smallest one is
  /// the fallback even when it's tight.
  static LocalModel? recommendedFor(DeviceProfile device) {
    bool comfortable(LocalModel m) => device.fitOf(m) == ModelFit.good;
    final perf = device.perfClass;
    if (perf == PerfClass.flagship && comfortable(gemma4Large)) return gemma4Large;
    if (perf != PerfClass.low && comfortable(gemma4)) return gemma4;
    if (comfortable(miniCpm)) return miniCpm;
    if (device.fitOf(qwen35Small) != ModelFit.tooBig) return qwen35Small;
    return null;
  }

  /// Model files from earlier versions of the app (MediaPipe `.task` and
  /// LiteRT-LM `.litertlm`), which this runtime can't load. Offered for
  /// deletion so they don't hold gigabytes of storage.
  static Future<List<File>> legacyFiles() async {
    try {
      final dir = Directory(await ModelDownloaderService().getModelsDirectory());
      return await dir
          .list()
          .where((e) => e is File && RegExp(r'\.(task|litertlm|bin)(\.part)?$').hasMatch(e.path))
          .cast<File>()
          .toList();
    } catch (_) {
      return [];
    }
  }
}
