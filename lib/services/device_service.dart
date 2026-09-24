import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:system_info_plus/system_info_plus.dart';

class DeviceService {
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  final Battery _battery = Battery();

  static int? _cachedRamMB;
  static List<String>? _cachedAbis;

  /// Total physical RAM in MB, cached (it never changes at runtime).
  Future<int?> totalRamMB() async {
    if (_cachedRamMB != null) return _cachedRamMB;
    try {
      _cachedRamMB = await SystemInfoPlus.physicalMemory;
    } catch (_) {}
    return _cachedRamMB;
  }

  /// RAM rounded to the marketing size (a "6 GB" phone reports ~5.6 GB).
  Future<int?> totalRamGB() async {
    final mb = await totalRamMB();
    return mb == null ? null : (mb / 1024).ceil();
  }

  /// CPU ABIs, e.g. [arm64-v8a, armeabi-v7a]. Used to hide `.litertlm`
  /// models, whose runtime only ships for arm64.
  Future<List<String>> supportedAbis() async {
    if (_cachedAbis != null) return _cachedAbis!;
    try {
      if (Platform.isAndroid) {
        _cachedAbis = (await _deviceInfo.androidInfo).supportedAbis;
      }
    } catch (_) {}
    return _cachedAbis ?? const [];
  }

  Future<bool> isArm64() async {
    if (!Platform.isAndroid) return true;
    return (await supportedAbis()).contains('arm64-v8a');
  }

  /// Quick stats for the model picker and settings screens.
  Future<Map<String, dynamic>> getQuickStats() async {
    final stats = <String, dynamic>{};
    final ramMB = await totalRamMB();
    if (ramMB != null) {
      stats['ramGB'] = (ramMB / 1024).ceil();
      stats['ramMB'] = ramMB;
    }
    try {
      final freeMB = await DiskSpace.getFreeDiskSpace;
      if (freeMB != null) stats['storageFreeMB'] = freeMB;
    } catch (_) {}
    stats['arm64'] = await isArm64();
    return stats;
  }

  /// Result of the `get_device_info` tool. Every field named in the tool's
  /// description is populated here, so the model never has to guess.
  Future<Map<String, dynamic>> getDeviceInfo() async {
    final info = <String, dynamic>{};

    try {
      if (Platform.isAndroid) {
        final a = await _deviceInfo.androidInfo;
        info['manufacturer'] = a.manufacturer;
        info['model'] = a.model;
        info['androidVersion'] = a.version.release;
      } else if (Platform.isIOS) {
        final i = await _deviceInfo.iosInfo;
        info['manufacturer'] = 'Apple';
        info['model'] = i.model;
        info['iosVersion'] = i.systemVersion;
      }
    } catch (_) {}

    try {
      info['batteryPercent'] = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      info['charging'] =
          state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      info['batteryPercent'] = 'unavailable';
    }

    try {
      final total = await DiskSpace.getTotalDiskSpace;
      final free = await DiskSpace.getFreeDiskSpace;
      if (total != null) info['storageTotalGB'] = _gb(total);
      if (free != null) info['storageFreeGB'] = _gb(free);
    } catch (_) {}

    final ramMB = await totalRamMB();
    if (ramMB != null) info['ramTotalGB'] = _gb(ramMB.toDouble());

    return info;
  }

  static double _gb(double mb) => double.parse((mb / 1024).toStringAsFixed(1));
}
