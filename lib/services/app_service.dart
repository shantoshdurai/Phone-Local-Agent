import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppService {
  List<AppInfo>? _cachedApps;

  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    try {
      List<AppInfo> apps = await InstalledApps.getInstalledApps(
        excludeSystemApps: false,
        withIcon: false,
      );
      _cachedApps = apps;
      
      return apps.map((app) => {
        'name': app.name,
        'packageName': app.packageName,
        'versionName': app.versionName,
        'versionCode': app.versionCode,
      }).toList();
    } catch (e) {
      print('Error getting installed apps: $e');
      return [];
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
      print('Error triggering uninstall for $packageName: $e');
      return false;
    }
  }

  Future<bool> launchApp(String packageName) async {
    try {
      return await InstalledApps.startApp(packageName) ?? false;
    } catch (e) {
      print('Error launching $packageName: $e');
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
      print('Error opening play store for $packageName: $e');
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
      print('Error opening play store updates: $e');
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
      print('Error searching play store for $query: $e');
      return false;
    }
  }
}
