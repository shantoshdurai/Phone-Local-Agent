import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_agent/services/search_service.dart';
import 'package:local_agent/services/tools/tool_runtime.dart';
import 'package:local_agent/services/weather_service.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Routes requests by host; unknown hosts fail like a blocked network.
http.Client Function() fakeNetwork(Map<String, http.Response Function(Uri)> hosts, List<Uri> seen) =>
    () => MockClient((request) async {
          seen.add(request.url);
          final handler = hosts[request.url.host];
          if (handler == null) throw const SocketException('blocked');
          return handler(request.url);
        });

http.Response utf8Response(String body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(body), status, headers: {'content-type': 'text/html; charset=utf-8'});

void main() {
  group('Bing', () {
    test('parses a real results page', () {
      final results = SearchService.parseBing(fixture('bing_results.html'));
      expect(results.map((r) => r.title), [
        'iPhone - Apple',
        'Buy iPhone - Apple',
        'Which iPhone Should You Buy (or Avoid) Right Now?',
      ]);
      expect(results.first.url, 'https://www.apple.com/iphone/');
      expect(results.first.snippet, startsWith('Regular iOS updates keep your iPhone'));
      expect(results.last.url, 'https://www.wired.com/gallery/iphone-buying-guide/');
    });

    test('unwraps /ck/ redirect links', () {
      final target = base64Url.encode(utf8.encode('https://example.com/a?b=1')).replaceAll('=', '');
      final html = '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&&p=abc&u=a1$target&ntb=1">'
          'Example</a></h2><div class="b_caption"><p>Snippet</p></div></li>';
      final results = SearchService.parseBing(html);
      expect(results.single.url, 'https://example.com/a?b=1');
      expect(results.single.snippet, 'Snippet');
    });

    test('an empty or blocked page gives no results', () {
      expect(SearchService.parseBing('<html><body>Please verify you are a human</body></html>'), isEmpty);
    });
  });

  test('DuckDuckGo skips ads and decodes wrapped links', () {
    const html = '''
<div class="result result--ad"><a class="result__a" href="https://ads.example/x">Ad</a></div>
<div class="result results_links web-result">
  <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fflutter.dev%2Fdocs&amp;rut=abc">Flutter  docs</a>
  <a class="result__snippet">Build apps for   any screen.</a>
</div>
<div class="result"><a class="result__a" href="https://dart.dev/">Dart</a></div>
<div class="result"><a class="result__a" href="/local/path">Broken</a></div>
''';
    final results = SearchService.parseDuckDuckGo(html);
    expect(results.map((r) => r.url), ['https://flutter.dev/docs', 'https://dart.dev/']);
    expect(results.first.title, 'Flutter docs');
    expect(results.first.snippet, 'Build apps for any screen.');
  });

  group('search chain', () {
    test('uses Bing when DuckDuckGo is blocked', () async {
      final seen = <Uri>[];
      final service = SearchService(
        clientFactory: fakeNetwork({
          'html.duckduckgo.com': (_) => utf8Response('anomaly', 202),
          'www.bing.com': (_) => utf8Response(fixture('bing_results.html')),
        }, seen),
      );
      final result = await service.searchWeb('iphone');
      expect(result['sources'], ['Bing']);
      expect((result['results'] as List).length, 3);
      // Both engines and Google News are asked at once.
      expect(seen.map((u) => u.host).toSet(), {'html.duckduckgo.com', 'www.bing.com', 'news.google.com'});
      expect(seen.firstWhere((u) => u.host == 'www.bing.com').queryParameters['q'], 'iphone');
    });

    test('says so honestly when every source fails', () async {
      final service = SearchService(clientFactory: fakeNetwork({}, []));
      final result = await service.searchWeb('anything');
      expect(result['results'], isEmpty);
      expect(result['error'], contains('Do not guess'));
    });
  });

  group('weather', () {
    test('parses wttr.in JSON', () {
      final w = WeatherService.parseWttr(jsonDecode(fixture('wttr_chennai.json')))!;
      expect(w['location'], 'Chennai, Tamil Nadu, India');
      expect(w['temperatureC'], 26);
      expect(w['feelsLikeC'], 27);
      expect(w['condition'], 'Light rain shower');
      expect(w['humidityPercent'], 70);
      expect(w['windKph'], 23);
      final forecast = w['forecast'] as List;
      expect(forecast.first, {'date': '2026-09-24', 'minC': 26, 'maxC': 34, 'rainChancePercent': 50});
      expect(forecast.length, 2);
      expect(
        ToolRuntime.formatDirect('get_weather', {}, w),
        "It's 26°C and light rain shower in Chennai, Tamil Nadu, India (feels like 27°C). "
        'Today: 26–34°C, 50% chance of rain.',
      );
    });

    test('rejects malformed JSON', () {
      expect(WeatherService.parseWttr('nope'), isNull);
      expect(WeatherService.parseWttr({'current_condition': []}), isNull);
    });

    test('falls back to Open-Meteo when wttr.in is down', () async {
      final seen = <Uri>[];
      final service = WeatherService(
        clientFactory: fakeNetwork({
          'wttr.in': (_) => http.Response('Unknown location', 500),
          'geocoding-api.open-meteo.com': (_) => http.Response(
              jsonEncode({
                'results': [
                  {'name': 'Pune', 'admin1': 'Maharashtra', 'country': 'India', 'latitude': 18.5, 'longitude': 73.9}
                ]
              }),
              200),
          'api.open-meteo.com': (_) => http.Response(
              jsonEncode({
                'current': {
                  'temperature_2m': 29.4,
                  'apparent_temperature': 31.0,
                  'relative_humidity_2m': 60,
                  'weather_code': 2,
                  'wind_speed_10m': 12.0,
                },
                'daily': {
                  'time': ['2026-09-24', '2026-09-25'],
                  'temperature_2m_max': [31.0, 30.0],
                  'temperature_2m_min': [22.0, 21.5],
                  'precipitation_probability_max': [40, 10],
                },
              }),
              200),
        }, seen),
      );
      final w = await service.getWeather('Pune');
      expect(w['location'], 'Pune, Maharashtra, India');
      expect(w['condition'], 'Partly cloudy');
      expect((w['forecast'] as List).first['rainChancePercent'], 40);
      expect(seen.first.path, '/Pune');
      expect(seen[2].queryParameters['latitude'], '18.5');
    });

    test('explains failure instead of inventing weather', () async {
      final service = WeatherService(clientFactory: fakeNetwork({}, []));
      expect((await service.getWeather('Atlantis'))['error'], contains('Atlantis'));
      expect((await service.getWeather(null))['error'], contains('name a city'));
    });
  });
}
