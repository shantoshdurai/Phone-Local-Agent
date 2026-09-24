import 'package:flutter/services.dart';

/// Keeps the screen on while long work runs (a download, a slow on-device
/// reply). Reference-counted, so overlapping users don't switch it off early.
class ScreenAwake {
  ScreenAwake._();

  static const _channel = MethodChannel('com.localagent/screen');
  static int _holders = 0;

  static Future<void> acquire() async {
    if (_holders++ == 0) await _set(true);
  }

  static Future<void> release() async {
    if (_holders == 0) return;
    if (--_holders == 0) await _set(false);
  }

  static Future<void> _set(bool on) async {
    try {
      await _channel.invokeMethod('keepOn', on);
    } catch (_) {
      // Not on Android (tests, desktop).
    }
  }
}
