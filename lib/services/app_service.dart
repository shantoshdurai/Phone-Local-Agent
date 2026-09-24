import 'package:flutter/services.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:url_launcher/url_launcher.dart';

class AppService {
  static const _platform = MethodChannel('com.localagent/apps');

  static List<AppInfo>? _cachedApps;
  static DateTime? _cachedAt;

  /// Launchable apps (including system apps like Camera and Settings),
  /// cached for a few minutes so repeated commands stay instant.
  Future<List<AppInfo>> launchableApps({bool refresh = false}) async {
    final fresh = _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 5);
    if (!refresh && fresh && _cachedApps != null) return _cachedApps!;
    try {
      _cachedApps = await InstalledApps.getInstalledApps(
        excludeSystemApps: false,
        excludeNonLaunchableApps: true,
        withIcon: false,
      );
      _cachedAt = DateTime.now();
    } catch (_) {
      _cachedApps ??= const [];
    }
    return _cachedApps!;
  }

  Future<String?> labelFor(String packageName) async {
    for (final app in await launchableApps()) {
      if (app.packageName == packageName) return app.name;
    }
    return null;
  }

  /// Installed apps with approximate install size, largest first.
  Future<List<Map<String, dynamic>>> getInstalledApps() async {
    final apps = await launchableApps();
    final sizes = await _getAppSizes();
    final out = [
      for (final app in apps)
        {
          'name': app.name,
          'package': app.packageName,
          'sizeBytes': sizes[app.packageName] ?? 0,
        }
    ];
    out.sort((a, b) => (b['sizeBytes'] as int).compareTo(a['sizeBytes'] as int));
    return out;
  }

  Future<Map<String, int>> _getAppSizes() async {
    try {
      final raw =
          await _platform.invokeMethod<Map<dynamic, dynamic>>('getAppSizes');
      if (raw == null) return {};
      return raw.map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// Opens the best-matching app for [appName]. Returns `success`, the
  /// matched `appName`, or `suggestions` when nothing matched confidently.
  Future<Map<String, dynamic>> launchAppByName(String appName) async {
    final apps = await launchableApps();
    final match = bestMatch(appName, apps.map((a) => (a.name, a.packageName)));
    if (match == null) {
      final suggestions = suggest(appName, apps.map((a) => a.name));
      return {
        'success': false,
        'error': 'No installed app matches "$appName".',
        if (suggestions.isNotEmpty) 'suggestions': suggestions,
      };
    }
    final (name, package) = match;
    bool ok = false;
    try {
      ok = await InstalledApps.startApp(package) ?? false;
    } catch (_) {}
    return ok
        ? {'success': true, 'appName': name}
        : {'success': false, 'appName': name, 'error': 'Could not open $name.'};
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Scored name matching: exact > prefix > whole-word > substring. Short or
  /// generic queries never match by substring, which is what made the old
  /// matcher open random apps. Visible for testing.
  static (String, String)? bestMatch(
      String query, Iterable<(String, String)> apps) {
    final q = _norm(query.replaceAll(RegExp(r'\bapp\b', caseSensitive: false), ''));
    if (q.isEmpty) return null;
    (String, String)? best;
    var bestScore = 0;
    for (final app in apps) {
      final (name, package) = app;
      final n = _norm(name);
      if (n.isEmpty) continue;
      int score;
      if (n == q) {
        score = 100;
      } else if (n.replaceAll(' ', '') == q.replaceAll(' ', '')) {
        score = 95;
      } else if (n.startsWith('$q ') || (q.length >= 3 && n.startsWith(q))) {
        score = 80;
      } else if (' $n '.contains(' $q ')) {
        score = 70;
      } else if (q.length >= 4 && n.contains(q)) {
        score = 55;
      } else if (q.length >= 4 && package.toLowerCase().contains(q.replaceAll(' ', ''))) {
        score = 50;
      } else {
        continue;
      }
      // Prefer shorter names on ties ("Chrome" over "Chrome Beta").
      if (score > bestScore ||
          (score == bestScore && best != null && name.length < best.$1.length)) {
        best = app;
        bestScore = score;
      }
    }
    return best;
  }

  static List<String> suggest(String query, Iterable<String> names) {
    final q = _norm(query);
    if (q.length < 2) return const [];
    final prefix = q.substring(0, q.length < 3 ? q.length : 3);
    return names
        .where((n) => _norm(n).split(' ').any((w) => w.startsWith(prefix)))
        .take(3)
        .toList();
  }

  Future<bool> uninstallApp(String packageName) async {
    try {
      return await InstalledApps.uninstallApp(packageName) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> searchPlayStore(String query) async {
    final q = Uri.encodeComponent(query);
    try {
      final market = Uri.parse('market://search?q=$q&c=apps');
      if (await canLaunchUrl(market)) return await launchUrl(market);
      return await launchUrl(
        Uri.parse('https://play.google.com/store/search?q=$q&c=apps'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}
