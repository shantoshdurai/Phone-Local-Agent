import 'package:flutter/services.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppService {
  static const _platform = MethodChannel('com.localagent/apps');

  List<AppInfo>? _cachedApps;

  /// Returns installed apps with code size (in bytes) attached when available.
  /// Size comes from the native PackageManager method channel — `installed_apps`
  /// alone doesn't expose it. Apps for which size lookup failed get `sizeBytes: 0`.
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    try {
      final apps = await InstalledApps.getInstalledApps(
        excludeSystemApps: false,
        withIcon: false,
      );
      _cachedApps = apps;
      final sizes = await _getAppSizes();

      return apps.map((app) {
        final bytes = sizes[app.packageName] ?? 0;
        return {
          'name': app.name,
          'packageName': app.packageName,
          'versionName': app.versionName,
          'versionCode': app.versionCode,
          'sizeBytes': bytes,
        };
      }).toList();
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, int>> _getAppSizes() async {
    try {
      final raw = await _platform.invokeMethod<Map<dynamic, dynamic>>('getAppSizes');
      if (raw == null) return {};
      return raw.map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// Smart app launcher: finds the app by name (fuzzy match) and launches it.
  /// Returns a result map with success status and details.
  Future<Map<String, dynamic>> launchAppByName(String appName) async {
    try {
      // Ensure we have the app list
      if (_cachedApps == null) {
        await getInstalledApps();
      }
      final apps = _cachedApps ?? [];

      final query = appName.toLowerCase().trim();

      // Try exact name match first
      AppInfo? match;
      for (var app in apps) {
        if (app.name.toLowerCase() == query) {
          match = app;
          break;
        }
      }

      // Fuzzy: name contains query
      if (match == null) {
        for (var app in apps) {
          if (app.name.toLowerCase().contains(query)) {
            match = app;
            break;
          }
        }
      }

      // Fuzzy: query contains app name
      if (match == null) {
        for (var app in apps) {
          if (query.contains(app.name.toLowerCase())) {
            match = app;
            break;
          }
        }
      }

      // Fuzzy: package name contains query
      if (match == null) {
        for (var app in apps) {
          if (app.packageName.toLowerCase().contains(query)) {
            match = app;
            break;
          }
        }
      }

      if (match != null) {
        final success = await InstalledApps.startApp(match.packageName) ?? false;
        return {
          'success': success,
          'appName': match.name,
          'packageName': match.packageName,
          'message': success
              ? '${match.name} has been launched.'
              : 'Failed to launch ${match.name}.',
        };
      } else {
        // Find closest matches for suggestion
        final suggestions = apps
            .where((a) =>
                a.name.toLowerCase().contains(query.substring(0, (query.length * 0.5).ceil().clamp(1, query.length))) ||
                query.contains(a.name.toLowerCase().substring(0, (a.name.length * 0.5).ceil().clamp(1, a.name.length))))
            .take(3)
            .map((a) => a.name)
            .toList();

        return {
          'success': false,
          'message': 'App "$appName" not found on this device.',
          'suggestions': suggestions,
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Error: $e'};
    }
  }

  Future<bool> uninstallApp(String packageName) async {
    try {
      return await InstalledApps.uninstallApp(packageName) ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> launchApp(String packageName) async {
    try {
      return await InstalledApps.startApp(packageName) ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> openPlayStore(String packageName) async {
    final Uri url = Uri.parse('market://details?id=$packageName');
    final Uri webUrl = Uri.parse('https://play.google.com/store/apps/details?id=$packageName');
    
    try {
      if (await canLaunchUrl(url)) {
        return await launchUrl(url);
      } else {
        return await launchUrl(webUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      return false;
    }
  }

  Future<bool> openPlayStoreUpdates() async {
    final Uri updatesUrl = Uri.parse('https://play.google.com/store/apps/details?id=com.android.vending');
    
    try {
      final Uri intentUrl = Uri.parse('market://my_apps');
      if (await canLaunchUrl(intentUrl)) {
        return await launchUrl(intentUrl);
      }
      return await launchUrl(updatesUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      return false;
    }
  }

  Future<bool> searchPlayStore(String query) async {
    final Uri url = Uri.parse('market://search?q=${Uri.encodeComponent(query)}&c=apps');
    final Uri webUrl = Uri.parse('https://play.google.com/store/search?q=${Uri.encodeComponent(query)}&c=apps');
    
    try {
      if (await canLaunchUrl(url)) {
        return await launchUrl(url);
      } else {
        return await launchUrl(webUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      return false;
    }
  }
}
