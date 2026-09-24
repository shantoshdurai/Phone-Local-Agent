import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

class SearchResult {
  final String title;
  final String snippet;
  final String url;

  /// Publication date for news results.
  final DateTime? published;
  final String? source;

  const SearchResult(this.title, this.snippet, this.url, {this.published, this.source});

  /// News links are long Google redirect URLs that cost a phone model
  /// hundreds of tokens and tell it nothing, so news results carry the
  /// publisher and date instead.
  Map<String, dynamic> toJson() => {
        'title': title,
        if (snippet.isNotEmpty) 'snippet': snippet,
        if (published == null) 'url': url.length > 120 ? url.substring(0, 120) : url,
        if (published != null) 'published': published!.toIso8601String().substring(0, 10),
        if (source != null) 'source': source,
      };
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

  /// Web results plus recent news, filtered for relevance.
  ///
  /// Search engines serve degraded pages to clients they suspect are bots
  /// (Bing answered "who won the last F1 race" with dictionary entries for
  /// "won"), so web results must share key words with the question to
  /// count, and Google News is queried alongside for anything current.
  Future<Map<String, dynamic>> searchWeb(String query) async {
    final newsFuture = _googleNews(query).catchError((_) => <SearchResult>[]);

    // Both engines run at once, so one that is blocked or slow doesn't add
    // its timeout to every search; DuckDuckGo wins when both have results.
    Future<List<SearchResult>> safe(Future<List<SearchResult>> Function(String) search) async {
      try {
        return filterRelevant(await search(query), query);
      } catch (_) {
        return const [];
      }
    }

    final engines = await Future.wait([safe(_duckDuckGo), safe(_bing)]);
    var web = <SearchResult>[];
    final sources = <String>[];
    if (engines[0].isNotEmpty) {
      web = engines[0];
      sources.add('DuckDuckGo');
    } else if (engines[1].isNotEmpty) {
      web = engines[1];
      sources.add('Bing');
    }

    final news = (await newsFuture).take(4).toList();
    if (news.isNotEmpty) sources.add('Google News');

    if (web.isEmpty) {
      try {
        final wiki = filterRelevant(await _wikipedia(query), query);
        if (wiki.isNotEmpty) {
          web = wiki;
          sources.add('Wikipedia');
        }
      } catch (_) {}
    }

    final seen = <String>{};
    final results = [
      for (final r in [...news, ...web.take(_maxResults)])
        if (seen.add(r.title.toLowerCase())) r,
    ];
    if (results.isEmpty) {
      return {
        'query': query,
        'results': const [],
        'error':
            'Web search found nothing useful right now (no internet, or the '
            'search services refused the request). Do not guess an answer.',
      };
    }
    return {
      'query': query,
      'sources': sources,
      'results': [for (final r in results) r.toJson()],
    };
  }

  static const _stopWords = {
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'of', 'in', 'on',
    'at', 'to', 'for', 'and', 'or', 'what', 'who', 'whom', 'which', 'when', 'where',
    'why', 'how', 'do', 'does', 'did', 'i', 'me', 'my', 'you', 'your', 'it', 'its',
    'this', 'that', 'these', 'those', 'with', 'about', 'from', 'by', 'as', 'can',
    'tell', 'please', 'there', 'their', 'most', 'recent', 'latest', 'current', 'now',
    'today', 'right',
  };

  static const _irregular = {'won': 'win', 'wins': 'win', 'winning': 'win', 'winner': 'win', 'winners': 'win'};

  /// Key terms of a query or text: lower-cased, stop words removed, light
  /// stemming ("races" → "race", "won" → "win").
  static Set<String> terms(String text) {
    final out = <String>{};
    for (var w in text.toLowerCase().split(RegExp(r"[^a-z0-9]+"))) {
      if (w.length < 2 || _stopWords.contains(w)) continue;
      w = _irregular[w] ?? w;
      if (w.length > 4 && w.endsWith('ing')) w = w.substring(0, w.length - 3);
      if (w.length > 3 && w.endsWith('es')) w = w.substring(0, w.length - 2);
      if (w.length > 3 && w.endsWith('s')) w = w.substring(0, w.length - 1);
      out.add(w);
    }
    return out;
  }

  /// Keeps results that share enough key terms with [query]: all of them for
  /// one- or two-term queries, at least two otherwise. Visible for testing.
  static List<SearchResult> filterRelevant(List<SearchResult> results, String query) {
    final q = terms(query);
    if (q.isEmpty) return results;
    final needed = q.length <= 2 ? q.length : 2;
    return [
      for (final r in results)
        if (terms('${r.title} ${r.snippet} ${Uri.tryParse(r.url)?.host ?? ''}').intersection(q).length >= needed) r,
    ];
  }

  Future<List<SearchResult>> _googleNews(String query) async {
    final body = await _get(Uri.https('news.google.com', '/rss/search', {
      'q': query,
      'hl': 'en-US',
      'gl': 'US',
      'ceid': 'US:en',
    }));
    return parseGoogleNewsRss(body);
  }

  /// Parses a Google News RSS feed. Visible for testing.
  static List<SearchResult> parseGoogleNewsRss(String xml) {
    String? tag(String item, String name) {
      final m = RegExp('<$name[^>]*>([\\s\\S]*?)</$name>').firstMatch(item);
      if (m == null) return null;
      var v = m.group(1)!.trim();
      if (v.startsWith('<![CDATA[')) v = v.substring(9, v.length - 3);
      return _unescape(v).trim();
    }

    final out = <SearchResult>[];
    for (final m in RegExp(r'<item>([\s\S]*?)</item>').allMatches(xml)) {
      final item = m.group(1)!;
      var title = tag(item, 'title');
      final link = tag(item, 'link');
      if (title == null || link == null) continue;
      final source = tag(item, 'source');
      // Titles end with " - Publisher".
      if (source != null && title.endsWith(' - $source')) {
        title = title.substring(0, title.length - source.length - 3);
      }
      DateTime? published;
      final date = tag(item, 'pubDate');
      if (date != null) published = _parseRfc822(date);
      out.add(SearchResult(title, '', link, published: published, source: source));
    }
    return out;
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// "Sun, 23 Aug 2026 07:00:00 GMT" → DateTime (UTC).
  static DateTime? _parseRfc822(String s) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    final month = _months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    return DateTime.utc(int.parse(m.group(3)!), month, int.parse(m.group(1)!),
        int.parse(m.group(4)!), int.parse(m.group(5)!));
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
