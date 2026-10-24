import 'package:flutter/foundation.dart';

/// Lightweight startup timing, so "cold start is faster now" is a measurement
/// instead of a claim.
///
/// Zero dependencies and no platform channels: a Stopwatch plus `debugPrint`,
/// which is stripped-ish in release (it still logs, but the calls are cheap).
/// Run `flutter run --profile` and filter the console for `[startup]` to see
/// where the time actually goes on a real device.
///
/// Example on a mid-range phone:
///   [startup] app_main=0ms
///   [startup] prefs_ready=38ms
///   [startup] first_frame=61ms
///   [startup] model_ready=4210ms
///   [startup] chat_ready=4330ms
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _since = Stopwatch()..start();
  static final Map<String, int> marks = <String, int>{};

  static void mark(String name) {
    final ms = _since.elapsedMilliseconds;
    marks[name] = ms;
    if (kDebugMode || kProfileMode) {
      debugPrint('[startup] $name=${ms}ms');
    }
  }

  /// Milliseconds between two marks, or null when either is missing.
  static int? delta(String from, String to) {
    final a = marks[from];
    final b = marks[to];
    if (a == null || b == null) return null;
    return b - a;
  }
}
