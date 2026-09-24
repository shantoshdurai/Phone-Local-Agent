import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

class SearchResult {
  final String title;
  final String snippet;
  final String url;
  const SearchResult(this.title, this.snippet, this.url);

  Map<String, dynamic> toJson() =>
      {'title': title, 'snippet': snippet, 'url': url};
}

/// Keyless web search for the `search_web` tool.
///
/// Tries several free sources in order and returns real result snippets, or
/// an honest failure. The old implementation returned "Could not find a
/// direct answer" for most queries (DuckDuckGo's instant-answer API is empty
/// for anything that isn't an encyclopedia topic), which pushed the model
/// into making answers up.
class SearchService {
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0 Mobile Safari/537.36';
  static const _timeout = Duration(seconds: 8);
  static const _maxResults = 5;

  final http.Client Function() _clientFactory;

  SearchService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  Future<Map<String, dynamic>> searchWeb(String query) async {
    final sources = <(String, Future<List<SearchResult>> Function(String))>[
      ('DuckDuckGo', _duckDuckGo),
      ('Bing', _bing),
      ('Wikipedia', _wikipedia),
    ];
    for (final (name, search) in sources) {
      try {
        final results = await search(query);
        if (results.isNotEmpty) {
          return {
            'query': query,
            'source': name,
            'results': results.take(_maxResults).map((r) => r.toJson()).toList(),
          };
        }
      } catch (_) {
        // Try the next source.
      }
    }
    return {
      'query': query,
      'results': const [],
      'error':
          'Web search is unavailable right now (no internet, or the search '
          'services refused the request). Do not guess an answer.',
    };
  }

  Future<String> _get(Uri uri) async {
    final client = _clientFactory();
    try {
      final res = await client.get(uri, headers: {
        'user-agent': _userAgent,
        'accept-language': 'en-US,en;q=0.8',
      }).timeout(_timeout);
      if (res.statusCode != 200) {
        throw StateError('HTTP ${res.statusCode}');
      }
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  Future<List<SearchResult>> _duckDuckGo(String query) async {
    final body = await _get(Uri.https('html.duckduckgo.com', '/html/', {'q': query}));
    return parseDuckDuckGo(body);
  }

  Future<List<SearchResult>> _bing(String query) async {
    final body = await _get(
        Uri.https('www.bing.com', '/search', {'q': query, 'setlang': 'en'}));
    return parseBing(body);
  }

  Future<List<SearchResult>> _wikipedia(String query) async {
    final search = jsonDecode(await _get(Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': query,
      'format': 'json',
      'srlimit': '3',
      'utf8': '1',
    })));
    final hits = (search['query']?['search'] as List?) ?? const [];
    final out = <SearchResult>[];
    for (final hit in hits.take(2)) {
      final title = '${hit['title']}';
      try {
        final summary = jsonDecode(await _get(Uri.https('en.wikipedia.org',
            '/api/rest_v1/page/summary/${Uri.encodeComponent(title)}')));
        final extract = '${summary['extract'] ?? ''}'.trim();
        if (extract.isEmpty) continue;
        out.add(SearchResult(
          title,
          _clip(extract, 500),
          'https://en.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Parses html.duckduckgo.com results, skipping ads. Visible for testing.
  static List<SearchResult> parseDuckDuckGo(String body) {
    final doc = parse(body);
    final out = <SearchResult>[];
    for (final result in doc.querySelectorAll('.result')) {
      if (result.classes.contains('result--ad')) continue;
      final link = result.querySelector('a.result__a');
      if (link == null) continue;
      final url = _ddgTarget(link.attributes['href'] ?? '');
      final title = _text(link);
      final snippet = _text(result.querySelector('.result__snippet'));
      if (url == null || title.isEmpty) continue;
      out.add(SearchResult(title, _clip(snippet, 300), url));
    }
    return out;
  }

  /// DDG wraps result links as `//duckduckgo.com/l/?uddg=<encoded target>`.
  static String? _ddgTarget(String href) {
    if (href.startsWith('//')) href = 'https:$href';
    final uri = Uri.tryParse(href);
    if (uri == null) return null;
    final target = uri.queryParameters['uddg'];
    if (target != null && target.isNotEmpty) return target;
    if (uri.hasScheme && uri.host.isNotEmpty && !uri.host.contains('duckduckgo.com')) {
      return href;
    }
    return null;
  }

  /// Parses Bing results. Visible for testing.
  static List<SearchResult> parseBing(String body) {
    final doc = parse(body);
    final out = <SearchResult>[];
    for (final result in doc.querySelectorAll('li.b_algo')) {
      final heading = result.querySelector('h2');
      final link = result.querySelector('.b_algoheader a[href]') ??
          result.querySelector('h2 a[href]');
      final url = _bingTarget(link?.attributes['href'] ?? '');
      final title = _text(heading);
      final snippet = _text(result.querySelector('.b_caption p'));
      if (url == null || title.isEmpty) continue;
      out.add(SearchResult(title, _clip(snippet, 300), url));
    }
    return out;
  }

  /// Bing sometimes routes links through `/ck/a?...&u=a1<base64url(target)>`.
  static String? _bingTarget(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null || !uri.hasScheme) return null;
    if (uri.host.endsWith('bing.com') && uri.path.startsWith('/ck/')) {
      final u = uri.queryParameters['u'];
      if (u != null && u.startsWith('a1')) {
        try {
          var b64 = u.substring(2);
          b64 += '=' * ((4 - b64.length % 4) % 4);
          return utf8.decode(base64Url.decode(b64));
        } catch (_) {
          return null;
        }
      }
      return null;
    }
    return href;
  }

  static String _text(Element? e) =>
      (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max).trimRight()}…';

  Future<Map<String, dynamic>> getPublicIP() async {
    try {
      final body = await _get(Uri.https('api.ipify.org', '/', {'format': 'json'}));
      final ip = jsonDecode(body)['ip'];
      if (ip is String && ip.isNotEmpty) return {'ip': ip};
    } catch (_) {}
    return {'error': 'Could not look up the public IP (no internet?).'};
  }
}
