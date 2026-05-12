import 'dart:convert';
import 'package:http/http.dart' as http;

class SearchService {
  /// Performs a web search using multiple strategies.
  /// Tries DuckDuckGo first, falls back to scraping Google search snippets.
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

    // Strategy 2: Wikipedia API (for factual queries)
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

    // Strategy 3: No result found — provide Google search link
    return {
      'success': false,
      'answer': 'Could not find a direct answer. The user should search Google.',
      'googleUrl': 'https://www.google.com/search?q=${Uri.encodeComponent(query)}',
    };
  }

  Future<String?> _searchDuckDuckGo(String query) async {
    final url = Uri.parse(
        'https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1');
    final response = await http.get(url).timeout(const Duration(seconds: 8));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final abstract = data['AbstractText'] as String? ?? '';
      if (abstract.isNotEmpty) return abstract;

      // Try related topics
      final relatedTopics = data['RelatedTopics'] as List? ?? [];
      List<String> snippets = [];
      for (var topic in relatedTopics) {
        if (topic is Map && topic.containsKey('Text')) {
          snippets.add(topic['Text'] as String);
        }
      }
      if (snippets.isNotEmpty) return snippets.take(3).join('\n');
    }
    return null;
  }

  Future<String?> _searchWikipedia(String query) async {
    // Wikipedia API search → get summary of the top result
    final searchUrl = Uri.parse(
        'https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=${Uri.encodeComponent(query)}&format=json&srlimit=1');
    final searchResp = await http.get(searchUrl).timeout(const Duration(seconds: 8));

    if (searchResp.statusCode == 200) {
      final searchData = jsonDecode(searchResp.body);
      final results = searchData['query']?['search'] as List?;
      if (results != null && results.isNotEmpty) {
        final title = results[0]['title'] as String;

        // Get the summary extract
        final summaryUrl = Uri.parse(
            'https://en.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title)}');
        final summaryResp = await http.get(summaryUrl, headers: {
          'User-Agent': 'LocalAgent/1.0',
        }).timeout(const Duration(seconds: 8));

        if (summaryResp.statusCode == 200) {
          final summaryData = jsonDecode(summaryResp.body);
          final extract = summaryData['extract'] as String? ?? '';
          if (extract.isNotEmpty) {
            // Truncate to keep context small for 1.5B model
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
