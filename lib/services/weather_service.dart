import 'dart:convert';

import 'package:http/http.dart' as http;

/// Keyless weather for the `get_weather` tool.
///
/// wttr.in resolves city names and, with no location, the caller's
/// approximate location from its IP — so no location permission is needed.
/// Open-Meteo is the fallback when a city is given.
class WeatherService {
  static const _timeout = Duration(seconds: 8);
  final http.Client Function() _clientFactory;

  WeatherService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  Future<Map<String, dynamic>> getWeather(String? location) async {
    final place = location?.trim() ?? '';
    try {
      final path = place.isEmpty ? '/' : '/${Uri.encodeComponent(place)}';
      final json = await _getJson(Uri.https('wttr.in', path, {'format': 'j1'}));
      final parsed = parseWttr(json);
      if (parsed != null) return parsed;
    } catch (_) {}
    if (place.isNotEmpty) {
      try {
        final parsed = await _openMeteo(place);
        if (parsed != null) return parsed;
      } catch (_) {}
    }
    return {
      'error': place.isEmpty
          ? 'Weather is unavailable right now. Try again, or name a city.'
          : 'Couldn\'t get weather for "$place". Check the spelling or try a nearby city.',
    };
  }

  Future<dynamic> _getJson(Uri uri) async {
    final client = _clientFactory();
    try {
      final res = await client
          .get(uri, headers: {'user-agent': 'curl/8 LocalAgent'}).timeout(_timeout);
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      return jsonDecode(utf8.decode(res.bodyBytes));
    } finally {
      client.close();
    }
  }

  /// Converts wttr.in `format=j1` JSON into the tool result. Visible for
  /// testing.
  static Map<String, dynamic>? parseWttr(dynamic json) {
    if (json is! Map) return null;
    final current = (json['current_condition'] as List?)?.firstOrNull;
    if (current is! Map) return null;
    String? first(dynamic list) {
      final item = (list as List?)?.firstOrNull;
      return item is Map ? item['value'] as String? : null;
    }

    final area = (json['nearest_area'] as List?)?.firstOrNull;
    final place = area is Map
        ? [first(area['areaName']), first(area['region']), first(area['country'])]
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet()
            .join(', ')
        : null;

    final days = <Map<String, dynamic>>[];
    for (final d in (json['weather'] as List? ?? const []).take(3)) {
      if (d is! Map) continue;
      final hourly = (d['hourly'] as List? ?? const [])
          .whereType<Map>()
          .map((h) => int.tryParse('${h['chanceofrain']}') ?? 0);
      days.add({
        'date': d['date'],
        'minC': _num(d['mintempC']),
        'maxC': _num(d['maxtempC']),
        if (hourly.isNotEmpty)
          'rainChancePercent': hourly.reduce((a, b) => a > b ? a : b),
      });
    }

    return {
      if (place != null && place.isNotEmpty) 'location': place,
      'temperatureC': _num(current['temp_C']),
      'feelsLikeC': _num(current['FeelsLikeC']),
      'condition': first(current['weatherDesc']) ?? 'unknown',
      'humidityPercent': _num(current['humidity']),
      'windKph': _num(current['windspeedKmph']),
      'forecast': days,
    };
  }

  Future<Map<String, dynamic>?> _openMeteo(String place) async {
    final geo = await _getJson(Uri.https('geocoding-api.open-meteo.com',
        '/v1/search', {'name': place, 'count': '1'}));
    final hit = (geo['results'] as List?)?.firstOrNull;
    if (hit is! Map) return null;
    final wx = await _getJson(Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '${hit['latitude']}',
      'longitude': '${hit['longitude']}',
      'current': 'temperature_2m,apparent_temperature,relative_humidity_2m,'
          'weather_code,wind_speed_10m',
      'daily': 'temperature_2m_max,temperature_2m_min,'
          'precipitation_probability_max',
      'forecast_days': '3',
      'timezone': 'auto',
    }));
    final cur = wx['current'];
    if (cur is! Map) return null;
    final daily = wx['daily'] as Map? ?? const {};
    final dates = (daily['time'] as List?) ?? const [];
    return {
      'location': [hit['name'], hit['admin1'], hit['country']]
          .whereType<String>()
          .join(', '),
      'temperatureC': cur['temperature_2m'],
      'feelsLikeC': cur['apparent_temperature'],
      'condition': _wmoDescription((cur['weather_code'] as num?)?.toInt()),
      'humidityPercent': cur['relative_humidity_2m'],
      'windKph': cur['wind_speed_10m'],
      'forecast': [
        for (var i = 0; i < dates.length; i++)
          {
            'date': dates[i],
            'minC': (daily['temperature_2m_min'] as List?)?[i],
            'maxC': (daily['temperature_2m_max'] as List?)?[i],
            'rainChancePercent':
                (daily['precipitation_probability_max'] as List?)?[i],
          }
      ],
    };
  }

  static num? _num(dynamic v) => v is num ? v : num.tryParse('$v');

  static String _wmoDescription(int? code) {
    if (code == null) return 'unknown';
    if (code == 0) return 'Clear sky';
    if (code <= 3) return 'Partly cloudy';
    if (code <= 48) return 'Fog';
    if (code <= 57) return 'Drizzle';
    if (code <= 67) return 'Rain';
    if (code <= 77) return 'Snow';
    if (code <= 82) return 'Rain showers';
    if (code <= 86) return 'Snow showers';
    return 'Thunderstorm';
  }
}
