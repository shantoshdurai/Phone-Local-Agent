import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;

class SearchService {
  /// Performs a web search using multiple strategies.
  Future<Map<String, dynamic>> searchWeb(String query) async {
    // Strategy 1: DuckDuckGo Instant Answer
    try {
      final ddgResult = await _searchDuckDuckGo(query);
      if (ddgResult != null && ddgResult.isNotEmpty) {
        return {
          'success': true,
          'answer': ddgResult,
          'source': 'DuckDuckGo',
        };
      }
    } catch (_) {}

    // Strategy 2: Google Search Scraper
    try {
      final googleResult = await _searchGoogle(query);
      if (googleResult != null && googleResult.isNotEmpty) {
        return {
          'success': true,
          'answer': googleResult,
          'source': 'Google',
        };
      }
    } catch (_) {}

    // Strategy 3: Wikipedia API (for factual queries)
    try {
      final wikiResult = await _searchWikipedia(query);
      if (wikiResult != null && wikiResult.isNotEmpty) {
        return {
          'success': true,
          'answer': wikiResult,
          'source': 'Wikipedia',
        };
      }
    } catch (_) {}

    // Strategy 4: No result found
    return {
      'success': false,
      'answer': 'Could not find a direct answer.',
      'googleUrl': 'https://www.google.com/search?q=${Uri.encodeComponent(query)}',
    };
  }

  Future<String?> _searchDuckDuckGo(String query) async {
    final url = Uri.parse(
        'https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1');
    final response = await http.get(url).timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final abstract = data['AbstractText'] as String? ?? '';
      if (abstract.isNotEmpty) return abstract;
    }
    return null;
  }

  Future<String?> _searchGoogle(String query) async {
    final url = Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(query)}&hl=en');
    final response = await http.get(url, headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) {
      final document = parse(response.body);
      
      // Try to find the featured snippet box (knowledge panel, direct answer)
      final featuredSnippet = document.querySelector('.BNeawe.iBp4i.AP7Wnd');
      if (featuredSnippet != null && featuredSnippet.text.isNotEmpty) {
         return featuredSnippet.text;
      }
      
      final featuredSnippet2 = document.querySelector('.Z0LcW');
      if (featuredSnippet2 != null && featuredSnippet2.text.isNotEmpty) {
         return featuredSnippet2.text;
      }

      // Extract text from search result descriptions
      final snippets = document.querySelectorAll('.VwiC3b');
      if (snippets.isNotEmpty) {
        return snippets.first.text;
      }
      
      // Generic snippet fallback
      final genericSnippets = document.querySelectorAll('.BNeawe.s3v9rd.AP7Wnd');
      for (var element in genericSnippets) {
         if (element.text.isNotEmpty && !element.text.contains('...') && element.text.length > 20) {
             return element.text;
         }
      }
    }
    return null;
  }

  Future<String?> _searchWikipedia(String query) async {
    final searchUrl = Uri.parse(
        'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=${Uri.encodeComponent(query)}&format=json&srlimit=1');
    final searchResp = await http.get(searchUrl).timeout(const Duration(seconds: 5));

    if (searchResp.statusCode == 200) {
      final searchData = jsonDecode(searchResp.body);
      final results = searchData['query']?['search'] as List?;
      if (results != null && results.isNotEmpty) {
        final title = results[0]['title'] as String;

        final summaryUrl = Uri.parse(
            'https://en.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title)}');
        final summaryResp = await http.get(summaryUrl, headers: {
          'User-Agent': 'LocalAgent/1.0',
        }).timeout(const Duration(seconds: 5));

        if (summaryResp.statusCode == 200) {
          final summaryData = jsonDecode(summaryResp.body);
          final extract = summaryData['extract'] as String? ?? '';
          if (extract.isNotEmpty) {
            return extract.length > 500 ? '${extract.substring(0, 500)}...' : extract;
          }
        }
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> getPublicIP() async {
    try {
      final response = await http.get(Uri.parse('https://api.ipify.org?format=json'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return {'error': 'Failed to fetch IP'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
