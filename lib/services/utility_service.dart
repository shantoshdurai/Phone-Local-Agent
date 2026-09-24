import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:torch_light/torch_light.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:volume_controller/volume_controller.dart';

class UtilityService {
  Future<bool> toggleFlashlight(bool on) async {
    try {
      if (on) {
        await TorchLight.enableTorch();
      } else {
        await TorchLight.disableTorch();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> vibrate({int duration = 500}) async {
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(duration: duration);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// [level] is a 0–1 fraction.
  Future<bool> setVolume(double level) async {
    try {
      VolumeController().setVolume(level.clamp(0.0, 1.0), showSystemUI: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> checkConnectivity() async {
    final result = <String, dynamic>{};
    try {
      final types = await Connectivity().checkConnectivity();
      final names = <String>[
        if (types.contains(ConnectivityResult.wifi)) 'Wi-Fi',
        if (types.contains(ConnectivityResult.mobile)) 'mobile data',
        if (types.contains(ConnectivityResult.ethernet)) 'ethernet',
        if (types.contains(ConnectivityResult.vpn)) 'VPN',
      ];
      result['connection'] = names.isEmpty ? 'none' : names.join(' + ');
    } catch (_) {
      result['connection'] = 'unknown';
    }

    final localIp = await _localIp();
    if (localIp != null) result['localIp'] = localIp;

    // One real round-trip decides "online": a network interface being up
    // doesn't mean the internet is reachable (captive portals, no data).
    try {
      final sw = Stopwatch()..start();
      final res = await http
          .get(Uri.parse('https://www.google.com/generate_204'))
          .timeout(const Duration(seconds: 5));
      sw.stop();
      result['online'] = res.statusCode == 204 || res.statusCode == 200;
      result['latencyMs'] = sw.elapsedMilliseconds;
    } catch (_) {
      result['online'] = false;
    }
    return result;
  }

  Future<String?> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> copyToClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  Future<String?> readFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  /// Accepts full URLs or bare domains ("github.com"), which models and
  /// users both produce.
  static Uri? normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s.contains(' ')) return null;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) {
      s = 'https://$s';
    }
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) {
      return null;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  Future<bool> openUrl(String url) async {
    final uri = normalizeUrl(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Opens the dialer pre-filled; the user still presses call.
  Future<bool> makePhoneCall(String phoneNumber) async {
    final cleaned = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.replaceAll('+', '').length < 3) return false;
    try {
      return await launchUrl(Uri(scheme: 'tel', path: cleaned));
    } catch (_) {
      return false;
    }
  }

  Future<bool> setAlarm(int hour, int minute, String message) async {
    try {
      await AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': hour,
          'android.intent.extra.alarm.MINUTES': minute,
          'android.intent.extra.alarm.MESSAGE': message,
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setTimer(int seconds, String message) async {
    try {
      await AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.LENGTH': seconds,
          'android.intent.extra.alarm.MESSAGE': message,
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasNotificationAccess() async {
    try {
      return await NotificationListenerService.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "Notification access" screen.
  Future<void> requestNotificationAccess() async {
    try {
      await NotificationListenerService.requestPermission();
    } catch (_) {}
  }

  /// Notifications currently in the status bar. [appLabel] maps a package
  /// name to its display name.
  Future<Map<String, dynamic>> readNotifications(
      Future<String?> Function(String package) appLabel) async {
    if (!await hasNotificationAccess()) {
      return {
        'error':
            'Notification access is off. Turn it on in Settings → Notification access → Local Agent, then ask again.',
        'needsPermission': true,
      };
    }
    try {
      final all = await NotificationListenerService.getActiveNotifications();
      final items = <Map<String, dynamic>>[];
      for (final n in all.reversed) {
        final title = n.title?.trim() ?? '';
        final text = n.content?.trim() ?? '';
        if (n.onGoing == true) continue; // music players, downloads, us
        if (title.isEmpty && text.isEmpty) continue;
        final pkg = n.packageName ?? '';
        items.add({
          'app': (pkg.isEmpty ? null : await appLabel(pkg)) ?? pkg,
          'title': title,
          'text': text.length > 160 ? '${text.substring(0, 160)}…' : text,
        });
        if (items.length >= 15) break;
      }
      return {'count': items.length, 'notifications': items};
    } catch (e) {
      return {'error': 'Could not read notifications: $e'};
    }
  }
}
