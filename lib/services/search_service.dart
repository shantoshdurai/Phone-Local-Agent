import 'dart:convert';
import 'package:http/http.dart' as http;

class SearchService {
  /// Performs a simple web search using DuckDuckGo's API.
  /// This doesn't require an API key and is good for general knowledge.
  Future<Map<String, dynamic>> searchWeb(String query) async {
    try {
      final url = Uri.parse('https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final abstract = data['AbstractText'] as String? ?? '';
        final relatedTopics = data['RelatedTopics'] as List? ?? [];
        final results = data['Results'] as List? ?? [];
        
        List<String> snippets = [];
        if (abstract.isNotEmpty) snippets.add(abstract);
        
        for (var topic in relatedTopics) {
          if (topic is Map && topic.containsKey('Text')) {
            snippets.add(topic['Text'] as String);
          }
        }

        List<Map<String, String>> links = [];
        for (var res in results) {
          if (res is Map && res.containsKey('FirstURL')) {
            links.add({
              'title': res['Text'] as String? ?? 'Link',
              'url': res['FirstURL'] as String
            });
          }
        }
        
        if (snippets.isEmpty && links.isEmpty) {
          return {
            'success': true,
            'result': 'No direct answer found, but you can try searching on Google.',
            'searchUrl': 'https://www.google.com/search?q=${Uri.encodeComponent(query)}'
          };
        }

        return {
          'success': true,
          'result': snippets.join('\n\n'),
          'links': links,
          'source': data['AbstractSource'] ?? 'DuckDuckGo',
          'url': data['AbstractURL'] ?? ''
        };
      } else {
        return {'success': false, 'error': 'Search service returned status ${response.statusCode}'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
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
