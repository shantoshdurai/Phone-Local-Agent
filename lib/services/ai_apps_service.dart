import 'package:installed_apps/installed_apps.dart';
import 'package:url_launcher/url_launcher.dart';

class DiscoveredAiApp {
  final String id;
  final String name;
  final String packageName;
  final String developer;
  final String description;
  final List<String> triggerKeywords;
  bool isInstalled;
  String? versionName;

  DiscoveredAiApp({
    required this.id,
    required this.name,
    required this.packageName,
    required this.developer,
    required this.description,
    required this.triggerKeywords,
    this.isInstalled = false,
    this.versionName,
  });

  String get playStoreUrl =>
      'https://play.google.com/store/apps/details?id=$packageName';
}

class AiAppsService {
  static final AiAppsService _instance = AiAppsService._internal();
  factory AiAppsService() => _instance;
  AiAppsService._internal();

  // Catalog of prominent Android AI apps
  final List<DiscoveredAiApp> _catalog = [
    DiscoveredAiApp(
      id: 'chatgpt',
      name: 'ChatGPT',
      packageName: 'com.openai.chatgpt',
      developer: 'OpenAI',
      description: 'Official ChatGPT app with Voice Mode and GPT-4o.',
      triggerKeywords: ['chatgpt', 'chat gpt', 'openai', 'gpt'],
    ),
    DiscoveredAiApp(
      id: 'claude',
      name: 'Claude',
      packageName: 'com.anthropic.claude',
      developer: 'Anthropic',
      description: 'Official Claude AI assistant with Claude 3.5 Sonnet.',
      triggerKeywords: ['claude', 'anthropic'],
    ),
    DiscoveredAiApp(
      id: 'gemini',
      name: 'Google Gemini',
      packageName: 'com.google.android.apps.bard',
      developer: 'Google LLC',
      description: 'Google’s AI assistant integrated with Android system.',
      triggerKeywords: ['gemini', 'bard', 'google gemini'],
    ),
    DiscoveredAiApp(
      id: 'copilot',
      name: 'Microsoft Copilot',
      packageName: 'com.microsoft.copilot',
      developer: 'Microsoft Corporation',
      description: 'AI companion with GPT-4, DALL-E 3, and Bing search.',
      triggerKeywords: ['copilot', 'microsoft copilot'],
    ),
    DiscoveredAiApp(
      id: 'perplexity',
      name: 'Perplexity',
      packageName: 'ai.perplexity.app',
      developer: 'Perplexity AI',
      description: 'AI conversational search engine with cited web sources.',
      triggerKeywords: ['perplexity', 'perplexity ai'],
    ),
    DiscoveredAiApp(
      id: 'poe',
      name: 'Poe',
      packageName: 'com.poe.android',
      developer: 'Quora',
      description: 'Multi-AI hub supporting Claude, GPT-4, Llama, and Flux.',
      triggerKeywords: ['poe', 'poe ai'],
    ),
    DiscoveredAiApp(
      id: 'grok',
      name: 'X (Grok)',
      packageName: 'com.twitter.android',
      developer: 'X Corp.',
      description: 'Real-time knowledge and unfiltered intelligence via Grok.',
      triggerKeywords: ['grok', 'twitter', 'x'],
    ),
  ];

  List<DiscoveredAiApp> get catalog => List.unmodifiable(_catalog);

  /// Scans the Android phone for installed AI applications.
  Future<List<DiscoveredAiApp>> scanInstalledAiApps() async {
    try {
      final installed = await InstalledApps.getInstalledApps(
        excludeSystemApps: false,
        withIcon: false,
      );

      final installedMap = <String, String?>{};
      for (final app in installed) {
        installedMap[app.packageName] = app.versionName;
      }

      for (final target in _catalog) {
        if (installedMap.containsKey(target.packageName)) {
          target.isInstalled = true;
          target.versionName = installedMap[target.packageName];
        } else {
          // Double check with direct package inquiry
          final isPresent =
              await InstalledApps.isAppInstalled(target.packageName) ?? false;
          target.isInstalled = isPresent;
        }
      }
    } catch (_) {
      // In tests or environments without Android framework
      for (final target in _catalog) {
        target.isInstalled = false;
      }
    }
    return _catalog;
  }

  /// Launch an installed AI app by package name.
  Future<bool> launchApp(String packageName) async {
    try {
      final ok = await InstalledApps.startApp(packageName);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open Google Play Store for an uninstalled AI app.
  Future<bool> openInPlayStore(String packageName) async {
    final uri =
        Uri.parse('https://play.google.com/store/apps/details?id=$packageName');
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Matches user query like "open claude" or "launch chatgpt" to an installed AI app.
  DiscoveredAiApp? matchLaunchQuery(String query) {
    final lower = query.toLowerCase().trim();
    final isLaunchIntent = lower.startsWith('open ') ||
        lower.startsWith('launch ') ||
        lower.startsWith('start ') ||
        lower.startsWith('switch to ');

    if (!isLaunchIntent) return null;

    final targetName = lower
        .replaceFirst(RegExp(r'^(open|launch|start|switch to)\s+'), '')
        .trim();

    for (final app in _catalog) {
      if (!app.isInstalled) continue;
      for (final keyword in app.triggerKeywords) {
        if (targetName.contains(keyword) || keyword == targetName) {
          return app;
        }
      }
    }
    return null;
  }
}
