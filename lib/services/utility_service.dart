import 'package:flutter/services.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';

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
    // level should be 0.0 to 1.0
    VolumeController().setVolume(level);
  }

  Future<String> getPublicIP() async {
    try {
      final response = await http.get(Uri.parse('https://api.ipify.org?format=json'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['ip'];
      }
    } catch (e) {
    }
    return 'Unknown';
  }

  /// Enhanced connectivity check with technical details
  Future<Map<String, dynamic>> checkConnectivityDetailed() async {
    final result = <String, dynamic>{};

    // Connection type
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      String type = 'Unknown';
      for (var r in connectivityResult) {
        if (r == ConnectivityResult.wifi) {
          type = 'WiFi';
        } else if (r == ConnectivityResult.mobile) {
          type = 'Mobile Data';
        } else if (r == ConnectivityResult.ethernet) {
          type = 'Ethernet';
        } else if (r == ConnectivityResult.none) {
          type = 'No Connection';
        }
      }
      result['connectionType'] = type;
    } catch (e) {
      result['connectionType'] = 'Unknown';
    }

    // Public IP
    try {
      final ipResponse = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 5));
      if (ipResponse.statusCode == 200) {
        result['publicIP'] = jsonDecode(ipResponse.body)['ip'];
      }
    } catch (_) {
      result['publicIP'] = 'Could not fetch';
    }

    // Ping / Latency test (measure HTTP round-trip to a fast endpoint)
    try {
      final stopwatch = Stopwatch()..start();
      await http
          .get(Uri.parse('https://www.google.com/generate_204'))
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();
      result['pingMs'] = stopwatch.elapsedMilliseconds;
      result['latency'] = '${stopwatch.elapsedMilliseconds}ms';
    } catch (_) {
      result['pingMs'] = -1;
      result['latency'] = 'Timeout / Unreachable';
    }

    // DNS resolution test
    try {
      final stopwatch = Stopwatch()..start();
      await http
          .head(Uri.parse('https://dns.google/'))
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();
      result['dnsMs'] = stopwatch.elapsedMilliseconds;
    } catch (_) {
      result['dnsMs'] = -1;
    }

    // Quality assessment
    final ping = result['pingMs'] as int? ?? -1;
    if (ping < 0) {
      result['quality'] = 'No Internet';
    } else if (ping < 100) {
      result['quality'] = 'Excellent';
    } else if (ping < 200) {
      result['quality'] = 'Good';
    } else if (ping < 500) {
      result['quality'] = 'Fair';
    } else {
      result['quality'] = 'Poor';
    }

    return result;
  }

  /// Simple connectivity check (legacy)
  Future<String> checkConnectivity() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.toString();
  }

  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<String?> readFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<bool> openUrl(String url) async {
    final Uri uri = Uri.parse(url);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      return false;
    }
  }
}
