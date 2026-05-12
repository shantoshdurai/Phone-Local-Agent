import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:system_info_plus/system_info_plus.dart';

class DeviceService {
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  final Battery _battery = Battery();

  /// Quick stats for the welcome/settings UI cards.
  Future<Map<String, dynamic>> getQuickStats() async {
    final stats = <String, dynamic>{};

    // RAM (MB → GB for display)
    try {
      final ramMB = await SystemInfoPlus.physicalMemory;
      if (ramMB != null) {
        stats['ramGB'] = (ramMB / 1024).ceil(); // e.g. 8
        stats['ramMB'] = ramMB;
      }
    } catch (_) {}

    // CPU cores
    stats['cpuCores'] = Platform.numberOfProcessors;

    // Battery
    try {
      stats['battery'] = await _battery.batteryLevel;
    } catch (_) {}

    // Storage
    try {
      final totalMB = await DiskSpace.getTotalDiskSpace;
      final freeMB = await DiskSpace.getFreeDiskSpace;
      if (totalMB != null) stats['storageTotal'] = totalMB;
      if (freeMB != null) stats['storageFree'] = freeMB;
    } catch (_) {}

    // Device brand/model
    try {
      if (Platform.isAndroid) {
        final ai = await _deviceInfo.androidInfo;
        stats['brand'] = ai.brand;
        stats['model'] = ai.model;
        stats['os'] = 'Android ${ai.version.release}';
        stats['sdkInt'] = ai.version.sdkInt;
      } else if (Platform.isIOS) {
        final ii = await _deviceInfo.iosInfo;
        stats['brand'] = 'Apple';
        stats['model'] = ii.model;
        stats['os'] = 'iOS ${ii.systemVersion}';
      }
    } catch (_) {}

    return stats;
  }

  Future<Map<String, dynamic>> getDeviceInfo() async {
    Map<String, dynamic> info = {};

    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        info['os'] = 'Android';
        info['version'] = androidInfo.version.release;
        info['sdkInt'] = androidInfo.version.sdkInt;
        info['manufacturer'] = androidInfo.manufacturer;
        info['model'] = androidInfo.model;
        info['device'] = androidInfo.device;
        info['hardware'] = androidInfo.hardware;
        info['board'] = androidInfo.board;
        info['display'] = androidInfo.display;
        info['product'] = androidInfo.product;
        info['brand'] = androidInfo.brand;
        info['supportedAbis'] = androidInfo.supportedAbis;
        
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        info['os'] = 'iOS';
        info['version'] = iosInfo.systemVersion;
        info['model'] = iosInfo.model;
        info['name'] = iosInfo.name;
      } else if (Platform.isLinux) {
        final linuxInfo = await _deviceInfo.linuxInfo;
        info['os'] = 'Linux';
        info['version'] = linuxInfo.version;
        info['id'] = linuxInfo.id;
      }

      final batteryLevel = await _battery.batteryLevel;
      info['batteryLevel'] = batteryLevel;
      
      try {
        info['totalDiskSpaceMB'] = await DiskSpace.getTotalDiskSpace;
        info['freeDiskSpaceMB'] = await DiskSpace.getFreeDiskSpace;
      } catch (e) {
        info['diskSpaceError'] = e.toString();
      }
      
    } catch (e) {
      info['error'] = 'Could not retrieve some device info: $e';
    }

    return info;
  }
}
