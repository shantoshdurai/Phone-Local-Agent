import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:flutter/services.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:notification_listener_service/notification_listener_service.dart';

class UtilityService {
  Future<bool> toggleFlashlight(bool on) async {
    try {
      if (on) {
        await TorchLight.enableTorch();
      } else {
        await TorchLight.disableTorch();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> vibrate({int duration = 500}) async {
    if (await Vibration.hasVibrator()) {
      Vibration.vibrate(duration: duration);
    }
  }

  Future<void> setVolume(double level) async {
    // The model can send 0..100 or 0..1; ToolRuntime normalises to a fraction,
    // but clamp again here so no caller can push an out-of-range value into
    // the platform channel.
    final clamped = level.clamp(0.0, 1.0);
    try {
      // `setVolume` is fire-and-forget in volume_controller 2.x (returns void),
      // so there is no future to await and no failure to observe here.
      VolumeController().setVolume(clamped);
    } catch (_) {
      // Some devices reject volume changes while a call is active.
    }
  }

  Future<String> getPublicIP() async {
    try {
      final response = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final ip = jsonDecode(response.body)['ip'];
        if (ip is String && ip.isNotEmpty) return ip;
      }
    } catch (_) {
      // Offline or blocked — the caller falls back to "unknown".
    }
    return 'Unknown';
  }

  /// Connectivity check that answers the question the user actually asked
  /// ("am I online?") in one round trip instead of three.
  ///
  /// The old version made three sequential HTTP requests with 5 s timeouts
  /// each, so a phone with no signal spent ~15 s inside a tool call. It also
  /// promised SSID/local IP in its description while returning neither, which
  /// made the model invent one.
  Future<Map<String, dynamic>> checkConnectivityDetailed() async {
    final result = <String, dynamic>{};

    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      final types = connectivityResult
          .map((r) => switch (r) {
                ConnectivityResult.wifi => 'WiFi',
                ConnectivityResult.mobile => 'Mobile Data',
                ConnectivityResult.ethernet => 'Ethernet',
                ConnectivityResult.vpn => 'VPN',
                ConnectivityResult.bluetooth => 'Bluetooth',
                ConnectivityResult.other => 'Other',
                ConnectivityResult.none => 'None',
                _ => 'Other',
              })
          .toList();
      result['connectionType'] = types.isEmpty ? 'Unknown' : types.join(', ');
      if (types.isEmpty || types.contains('None')) {
        result['online'] = false;
        result['quality'] = 'No Internet';
        return result;
      }
    } catch (_) {
      result['connectionType'] = 'Unknown';
    }

    // DNS resolution is the cheapest reliable "is there real internet?"
    // probe — no HTTP round trip, no third-party endpoint.
    try {
      final sw = Stopwatch()..start();
      final lookup = await InternetAddress.lookup('one.one.one.one')
          .timeout(const Duration(seconds: 3));
      sw.stop();
      final reachable = lookup.isNotEmpty;
      result['online'] = reachable;
      result['dnsMs'] = sw.elapsedMilliseconds;
      final ms = sw.elapsedMilliseconds;
      result['quality'] = !reachable
          ? 'No Internet'
          : ms < 120
              ? 'Excellent'
              : ms < 300
                  ? 'Good'
                  : 'Slow';
    } catch (_) {
      result['online'] = false;
      result['quality'] = 'No Internet';
      result['note'] = 'DNS lookup failed or timed out.';
    }

    return result;
  }

  /// Simple connectivity check (legacy)
  Future<String> checkConnectivity() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.map((r) => r.name).join(', ');
  }

  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<String?> readFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    return (text == null || text.isEmpty) ? null : text;
  }

  Future<bool> openUrl(String url) async {
    final Uri uri = Uri.parse(url);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      return false;
    }
  }

  Future<bool> makePhoneCall(String phoneNumber) async {
    // Strip all non-digit characters except the leading +
    String cleaned = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    final Uri uri = Uri.parse('tel:$cleaned');
    try {
      return await launchUrl(uri);
    } catch (e) {
      return false;
    }
  }

  Future<bool> setAlarm(int hour, int minute, String message) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': hour,
          'android.intent.extra.alarm.MINUTES': minute,
          'android.intent.extra.alarm.MESSAGE': message,
          // SKIP_UI used to be true, which created alarms silently in the
          // background. Opening the clock app with the value prefilled lets
          // the user confirm — important for a destructive-ish action.
          'android.intent.extra.alarm.SKIP_UI': false,
        },
      );
      await intent.launch();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> setTimer(int seconds, String message) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.LENGTH': seconds,
          'android.intent.extra.alarm.MESSAGE': message,
          'android.intent.extra.alarm.SKIP_UI': false,
        },
      );
      await intent.launch();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>> readNotifications() async {
    try {
      bool status = await NotificationListenerService.isPermissionGranted();
      if (!status) {
        // Will prompt the user to grant permission
        status = await NotificationListenerService.requestPermission();
        if (!status) {
          return {'error': 'Notification access permission denied.'};
        }
      }
      
      return {'success': true, 'message': 'Notification listening setup. (Note: Can only read new incoming notifications after granting permission, reading past notifications is not supported by Android API unless cached)'};
    } catch (e) {
      return {'error': 'Failed to read notifications: $e'};
    }
  }

  // ── Added for the expanded toolset ────────────────────────────────────────

  /// Opens the SMS composer. No SEND_SMS permission is needed because the user
  /// taps send themselves.
  Future<bool> sendSms(String phone, String message) async {
    try {
      final uri = Uri(
        scheme: 'sms',
        path: phone.replaceAll(RegExp(r'[^\d+]'), ''),
        queryParameters: {'body': message},
      );
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  Future<bool> composeEmail({
    required String to,
    String? subject,
    String? body,
  }) async {
    try {
      final uri = Uri(
        scheme: 'mailto',
        path: to,
        queryParameters: {
          if (subject != null && subject.isNotEmpty) 'subject': subject,
          if (body != null && body.isNotEmpty) 'body': body,
        },
      );
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Opens a specific system settings screen. Values come from the model, so
  /// anything unknown falls back to the root settings screen.
  Future<bool> openSettings(String section) async {
    const map = {
      'wifi': 'android.settings.WIFI_SETTINGS',
      'bluetooth': 'android.settings.BLUETOOTH_SETTINGS',
      'display': 'android.settings.DISPLAY_SETTINGS',
      'sound': 'android.settings.SOUND_SETTINGS',
      'battery': 'android.settings.BATTERY_SAVER_SETTINGS',
      'apps': 'android.settings.APPLICATION_SETTINGS',
      'location': 'android.settings.LOCATION_SOURCE_SETTINGS',
      'data': 'android.settings.DATA_ROAMING_SETTINGS',
      'settings': 'android.settings.SETTINGS',
    };
    try {
      await AndroidIntent(
        action: map[section.trim().toLowerCase()] ?? 'android.settings.SETTINGS',
      ).launch();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Current weather via wttr.in (no API key). Empty location = let the
  /// service geolocate by IP.
  Future<Map<String, dynamic>> getWeather(String location) async {
    try {
      final q = location.trim().isEmpty
          ? ''
          : Uri.encodeComponent(location.trim());
      final response = await http
          .get(Uri.parse('https://wttr.in/$q?format=j1'))
          .timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) {
        return {'error': 'Weather service returned ${response.statusCode}.'};
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return {'error': 'Unexpected weather response.'};

      final current = (decoded['current_condition'] as List?)?.isNotEmpty == true
          ? decoded['current_condition'][0] as Map
          : null;
      if (current == null) return {'error': 'No weather data available.'};

      String describe(dynamic desc) {
        if (desc is List && desc.isNotEmpty) {
          final first = desc[0];
          if (first is Map && first['value'] != null) {
            return first['value'].toString();
          }
        }
        return 'Unknown';
      }

      String areaName = '';
      final nearest = decoded['nearest_area'];
      if (nearest is List && nearest.isNotEmpty) {
        final a = nearest[0];
        if (a is Map) {
          final names = a['areaName'];
          if (names is List && names.isNotEmpty) {
            final n = names[0];
            if (n is Map && n['value'] != null) areaName = n['value'].toString();
          }
        }
      }

      return {
        'location': areaName.isEmpty
            ? (location.trim().isEmpty ? 'Your area' : location.trim())
            : areaName,
        'tempC': current['temp_C']?.toString(),
        'feelsLikeC': current['FeelsLikeC']?.toString(),
        'condition': describe(current['weatherDesc']),
        'humidity': current['humidity']?.toString(),
        'windKmph': current['windspeedKmph']?.toString(),
      };
    } catch (e) {
      return {'error': 'Could not fetch weather: $e'};
    }
  }
}
