/// Lenient readers for model-produced tool arguments.
///
/// Models — small on-device ones especially — send `"true"` for booleans,
/// `"7"` or `7.0` for integers and `50` when a 0–1 fraction was asked for.
/// Strict `as int` casts turned all of those into crashes; these helpers
/// accept every reasonable encoding and return null for garbage.
library;

String? argString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  if (v is num || v is bool) return '$v';
  return null;
}

int? argInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) {
    final t = v.trim();
    return int.tryParse(t) ?? double.tryParse(t)?.round();
  }
  return null;
}

double? argDouble(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is num) return v.toDouble();
  if (v is String) {
    return double.tryParse(v.trim().replaceAll('%', ''));
  }
  return null;
}

bool? argBool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true':
      case 'on':
      case 'yes':
      case '1':
      case 'enable':
      case 'enabled':
        return true;
      case 'false':
      case 'off':
      case 'no':
      case '0':
      case 'disable':
      case 'disabled':
        return false;
    }
  }
  return null;
}

/// Volume-style level: accepts a 0–1 fraction or a 0–100 percentage.
double? argFraction(Map<String, dynamic> args, String key) {
  final raw = args[key];
  final isPercentString = raw is String && raw.contains('%');
  final v = argDouble(args, key);
  if (v == null) return null;
  final fraction = (isPercentString || v > 1) ? v / 100 : v;
  return fraction.clamp(0.0, 1.0).toDouble();
}
