import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppService {
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    try {
      List<AppInfo> apps = await InstalledApps.getInstalledApps(
        excludeSystemApps: true,
        withIcon: false,
      );
      
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
}
