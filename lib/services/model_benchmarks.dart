import 'package:shared_preferences/shared_preferences.dart';

/// Per-model decode speed actually measured on this device.
///
/// The model store shows a *predicted* tok/s number derived from core count
/// and model size. That is honest but generic. Every completed turn already
/// produces a real measurement (`tokens / evalTime`), so we persist it and
/// prefer it over the prediction. That turns "~12 tok/s (estimated)" into
/// "9.4 tok/s measured on this phone" after one message — and it self-corrects
/// for thermal throttling, background load and OEM CPU governors, none of
/// which a static table can know about.
class ModelBenchmarks {
  ModelBenchmarks._();

  static const String _prefix = 'measured_tps_v1_';

  static Map<String, double>? _cache;

  /// Reads every stored measurement once, then serves from memory.
  static Future<Map<String, double>> load() async {
    if (_cache != null) return _cache!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = <String, double>{};
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final v = prefs.getDouble(key);
        if (v != null && v > 0) {
          out[key.substring(_prefix.length)] = v;
        }
      }
      _cache = out;
      return out;
    } catch (_) {
      _cache = const {};
      return _cache!;
    }
  }

  static double? cached(String fileName) => _cache?[fileName];

  /// Record a measurement. Uses an exponential moving average so one slow turn
  /// (a long tool-free reply on a hot phone) does not overwrite a good number,
  /// and ignores obviously bogus values.
  static Future<void> record(String fileName, double tps) async {
    if (fileName.isEmpty || tps <= 0 || tps > 200) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix$fileName';
      final previous = prefs.getDouble(key);
      final next = previous == null ? tps : (previous * 0.7 + tps * 0.3);
      await prefs.setDouble(key, next);
      _cache = {...?_cache, fileName: next};
    } catch (_) {
      // Benchmarks are a nicety; never let them affect a chat turn.
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_prefix)) await prefs.remove(key);
      }
      _cache = const {};
    } catch (_) {}
  }
}
