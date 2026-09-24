import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_settings.dart';
import 'local_model.dart';

enum HubSort {
  popular('downloads', 'Popular'),
  trending('trendingScore', 'Trending'),
  newest('createdAt', 'Newest'),
  liked('likes', 'Most liked');

  final String apiName;
  final String label;
  const HubSort(this.apiName, this.label);
}

/// A search hit on the Hugging Face hub.
class HubModelSummary {
  final String repo;
  final int downloads;
  final int likes;
  final String? pipeline;
  final List<String> tags;
  final DateTime? created;
  final bool gated;

  const HubModelSummary({
    required this.repo,
    this.downloads = 0,
    this.likes = 0,
    this.pipeline,
    this.tags = const [],
    this.created,
    this.gated = false,
  });

  String get author => repo.split('/').first;
  String get name => repo.split('/').last.replaceAll(RegExp(r'[-_]GGUF$', caseSensitive: false), '');

  bool get vision =>
      pipeline == 'image-text-to-text' || pipeline == 'any-to-any' || tags.contains('vision');

  /// Parameter count from the name ("Qwen3.5-2B" → 2.0), if it says.
  double? get paramsB => paramsFromName(repo.split('/').last);

  /// Rough 4-bit download size, for "fits your phone" before the file list
  /// is loaded.
  double? get approxQ4GB => paramsB == null ? null : paramsB! * 0.62 + 0.1;
}

class HubFile {
  final String path;
  final int size;
  const HubFile(this.path, this.size);

  String get quant => quantFromFileName(path) ?? 'GGUF';
  String get fileName => path.split('/').last;
}

class HubRepoDetails {
  final String repo;
  final String revision;
  final bool gated;
  final String? license;
  final String? pipeline;
  final List<HubFile> models;
  final List<HubFile> projectors;

  const HubRepoDetails({
    required this.repo,
    required this.revision,
    this.gated = false,
    this.license,
    this.pipeline,
    this.models = const [],
    this.projectors = const [],
  });
}

/// Browses GGUF models on huggingface.co. Everything llama.cpp runs is
/// there; the filters keep the list to chat models a phone can use.
class HfHubClient {
  HfHubClient({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  Future<dynamic> _getJson(Uri uri) async {
    final client = _clientFactory();
    try {
      final token = await KeyStore.read('huggingface');
      final res = await client.get(uri, headers: {
        if (token != null) 'authorization': 'Bearer $token',
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw 'Hugging Face refused the request. Check your access token in Settings.';
      }
      if (res.statusCode != 200) throw 'Hugging Face returned HTTP ${res.statusCode}.';
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on String {
      rethrow;
    } catch (e) {
      throw 'Couldn\'t reach Hugging Face. Check your connection.';
    } finally {
      client.close();
    }
  }

  Future<List<HubModelSummary>> search({
    String query = '',
    HubSort sort = HubSort.popular,
    int limit = 60,
  }) async {
    final params = <String, dynamic>{
      if (query.trim().isNotEmpty) 'search': query.trim(),
      'filter': 'gguf',
      'sort': sort.apiName,
      'direction': '-1',
      'limit': '$limit',
      'expand[]': ['downloads', 'likes', 'pipeline_tag', 'tags', 'gated', 'createdAt'],
    };
    final json = await _getJson(Uri.https('huggingface.co', '/api/models', params));
    return parseSearch(json);
  }

  Future<HubRepoDetails> details(String repo) async {
    final json = await _getJson(Uri.https('huggingface.co', '/api/models/$repo', {'blobs': 'true'}));
    return parseDetails(json);
  }

  // ---------------------------------------------------------------------
  // Parsing and filtering (pure, unit-tested)
  // ---------------------------------------------------------------------

  /// Tasks a chat app can run. Image generators, speech and embedding
  /// models also ship as GGUF but aren't chat models.
  static const _chatPipelines = {
    null,
    'text-generation',
    'image-text-to-text',
    'any-to-any',
    'conversational',
    'text2text-generation',
  };

  /// Repos marketed as uncensored or NSFW are left out: Play's policy for
  /// AI apps requires preventing generation of restricted content.
  static final _blocked = RegExp(
    r'uncensor|abliterat|nsfw|heretic|lewd|erotic|porn|jailbreak|unfilter|dealign|crack',
    caseSensitive: false,
  );

  static List<HubModelSummary> parseSearch(dynamic json) {
    if (json is! List) return [];
    final out = <HubModelSummary>[];
    for (final m in json) {
      if (m is! Map) continue;
      final repo = (m['id'] ?? m['modelId']) as String?;
      if (repo == null) continue;
      final pipeline = m['pipeline_tag'] as String?;
      if (!_chatPipelines.contains(pipeline)) continue;
      final tags = ((m['tags'] as List?) ?? const []).whereType<String>().toList();
      if (_blocked.hasMatch(repo) || tags.any(_blocked.hasMatch)) continue;
      // Pure image generators sometimes carry no pipeline tag.
      if (tags.any((t) => t == 'text-to-image' || t == 'comfyui' || t == 'diffusers')) continue;
      out.add(HubModelSummary(
        repo: repo,
        downloads: (m['downloads'] as num?)?.toInt() ?? 0,
        likes: (m['likes'] as num?)?.toInt() ?? 0,
        pipeline: pipeline,
        tags: tags,
        created: DateTime.tryParse('${m['createdAt'] ?? ''}'),
        gated: m['gated'] != null && m['gated'] != false,
      ));
    }
    return out;
  }

  static HubRepoDetails parseDetails(dynamic json) {
    final m = json as Map;
    final siblings = ((m['siblings'] as List?) ?? const []).whereType<Map>();
    final models = <HubFile>[];
    final projectors = <HubFile>[];
    for (final s in siblings) {
      final path = s['rfilename'] as String?;
      final size = (s['size'] as num?)?.toInt() ?? (s['lfs'] is Map ? ((s['lfs'] as Map)['size'] as num?)?.toInt() : null);
      if (path == null || size == null || !path.toLowerCase().endsWith('.gguf')) continue;
      final name = path.split('/').last.toLowerCase();
      if (name.contains('mmproj')) {
        projectors.add(HubFile(path, size));
        continue;
      }
      // Split files need every part; imatrix/MTP draft files aren't chat models.
      if (RegExp(r'-\d{5}-of-\d{5}\.gguf$').hasMatch(name)) continue;
      if (name.contains('imatrix') || name.startsWith('mtp-') || name.contains('draft')) continue;
      models.add(HubFile(path, size));
    }
    models.sort((a, b) => a.size.compareTo(b.size));
    final card = m['cardData'];
    return HubRepoDetails(
      repo: (m['id'] ?? m['modelId']) as String,
      revision: (m['sha'] as String?) ?? 'main',
      gated: m['gated'] != null && m['gated'] != false,
      license: card is Map ? card['license'] as String? : null,
      pipeline: m['pipeline_tag'] as String?,
      models: models,
      projectors: projectors,
    );
  }

  /// A sensible default: the best 4-bit quant that fits, else the largest
  /// file that fits, else the smallest.
  static HubFile? pickDefault(List<HubFile> files, {required double usableGB}) {
    if (files.isEmpty) return null;
    const preference = ['Q4_K_M', 'Q4_0', 'UD-Q4_K_XL', 'Q4_K_S', 'IQ4_XS', 'IQ4_NL', 'Q5_K_M', 'Q3_K_M', 'Q6_K', 'Q8_0'];
    bool fits(HubFile f) => f.size / (1024 * 1024 * 1024) * 1.05 + 0.5 <= usableGB;
    for (final q in preference) {
      for (final f in files) {
        if (f.quant == q && fits(f)) return f;
      }
    }
    final fitting = files.where(fits).toList();
    if (fitting.isNotEmpty) return fitting.last;
    return files.first;
  }

  /// F16 projectors are the usual choice; they are small next to the model.
  static HubFile? pickProjector(List<HubFile> files) {
    if (files.isEmpty) return null;
    for (final q in ['F16', 'BF16', 'Q8_0']) {
      for (final f in files) {
        // Exact match: "F16" must not pick "BF16".
        if (quantFromFileName(f.fileName) == q) return f;
      }
    }
    return files.reduce((a, b) => a.size <= b.size ? a : b);
  }

  /// Turns a picked file into a model the app can download and run.
  static LocalModel toLocalModel(HubRepoDetails repo, HubFile file, {HubFile? projector}) {
    final params = paramsFromName(repo.repo.split('/').last) ?? paramsFromName(file.fileName);
    final base = repo.repo.split('/').last.replaceAll(RegExp(r'[-_]GGUF$', caseSensitive: false), '');
    return LocalModel(
      id: '${repo.repo}/${file.path}',
      name: '$base · ${file.quant}',
      repo: repo.repo,
      revision: repo.revision,
      file: file.path,
      sizeBytes: file.size,
      mmprojFile: projector?.path,
      mmprojSizeBytes: projector?.size,
      license: repo.license,
      // Small models pick the wrong tool out of a long list.
      toolUse: (params != null && params < 2) ? ToolUse.lookups : ToolUse.full,
      supportsThinking: true,
      sampling: const SamplingDefaults(temperature: 0.7, topK: 40, topP: 0.9, minP: 0.05),
    );
  }
}
