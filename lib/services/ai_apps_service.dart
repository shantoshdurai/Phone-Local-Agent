import 'package:installed_apps/installed_apps.dart';
import 'package:url_launcher/url_launcher.dart';

/// One external AI app the assistant can hand off to.
class AiApp {
  final String id;
  final String name;
  final String packageName;
  final String developer;
  final String description;
  final List<String> keywords;

  const AiApp({
    required this.id,
    required this.name,
    required this.packageName,
    required this.developer,
    required this.description,
    required this.keywords,
  });

  String get playStoreUrl =>
      'https://play.google.com/store/apps/details?id=$packageName';
}

class DiscoveredAiApp {
  final AiApp app;
  final bool installed;
  const DiscoveredAiApp({required this.app, required this.installed});
}

/// "AI apps" hub: other assistants installed on the phone.
///
/// This is the piece from the `experimental-ai-assistant` branch worth keeping —
/// a catalogue of the assistants people already use, with one-tap launch, so
/// Agent can hand off a request instead of pretending it is the only app.
class AiAppsService {
  AiAppsService._();
  static final AiAppsService instance = AiAppsService._();

  static const List<AiApp> catalog = [
    AiApp(
      id: 'chatgpt',
      name: 'ChatGPT',
      packageName: 'com.openai.chatgpt',
      developer: 'OpenAI',
      description: 'Chat, voice mode and image generation.',
      keywords: ['chatgpt', 'chat gpt', 'openai', 'gpt'],
    ),
    AiApp(
      id: 'claude',
      name: 'Claude',
      packageName: 'com.anthropic.claude',
      developer: 'Anthropic',
      description: 'Long-document reasoning and writing.',
      keywords: ['claude', 'anthropic'],
    ),
    AiApp(
      id: 'gemini',
      name: 'Google Gemini',
      packageName: 'com.google.android.apps.bard',
      developer: 'Google',
      description: 'Google\'s assistant, integrated with Android.',
      keywords: ['gemini', 'bard'],
    ),
    AiApp(
      id: 'copilot',
      name: 'Microsoft Copilot',
      packageName: 'com.microsoft.copilot',
      developer: 'Microsoft',
      description: 'GPT-4 class chat with image generation.',
      keywords: ['copilot', 'microsoft'],
    ),
    AiApp(
      id: 'perplexity',
      name: 'Perplexity',
      packageName: 'ai.perplexity.app',
      developer: 'Perplexity AI',
      description: 'Answer engine with cited sources.',
      keywords: ['perplexity'],
    ),
    AiApp(
      id: 'deepseek',
      name: 'DeepSeek',
      packageName: 'com.deepseek.chat',
      developer: 'DeepSeek',
      description: 'Reasoning-focused chat assistant.',
      keywords: ['deepseek', 'deep seek'],
    ),
    AiApp(
      id: 'poe',
      name: 'Poe',
      packageName: 'com.poe.android',
      developer: 'Quora',
      description: 'Multi-model hub: Claude, GPT, Llama.',
      keywords: ['poe'],
    ),
  ];

  /// Which catalogue apps are installed.
  Future<List<DiscoveredAiApp>> discover() async {
    final installed = <String>{};
    try {
      final apps = await InstalledApps.getInstalledApps();
      for (final app in apps) {
        installed.add(app.packageName);
      }
    } catch (_) {
      // Package visibility or plugin failure — everything shows as "Get".
    }
    return catalog
        .map((a) => DiscoveredAiApp(
              app: a,
              installed: installed.contains(a.packageName),
            ))
        .toList();
  }

  Future<bool> launch(AiApp app) async {
    try {
      await InstalledApps.startApp(app.packageName);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openStore(AiApp app) async {
    try {
      if (await canLaunchUrl(Uri.parse('market://details?id=${app.packageName}'))) {
        return launchUrl(
          Uri.parse('market://details?id=${app.packageName}'),
          mode: LaunchMode.externalApplication,
        );
      }
      return launchUrl(
        Uri.parse(app.playStoreUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// Find an app mentioned by name in a request ("open Claude").
  AiApp? match(String text) {
    final lower = text.toLowerCase();
    for (final app in catalog) {
      for (final keyword in app.keywords) {
        if (lower.contains(keyword)) return app;
      }
    }
    return null;
  }
}
