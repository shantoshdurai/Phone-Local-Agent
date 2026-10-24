import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_agent/services/assistant_router_service.dart';
import 'package:local_agent/services/ai_apps_service.dart';
import 'package:local_agent/services/wake_word_launcher_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'assistant_custom_wake_word': 'Jarvis',
      'assistant_custom_target': 'claude',
      'assistant_wake_words_enabled': true,
      'assistant_default_provider': 'gemini',
    });
  });

  group('AssistantRouterService Wake Word Detection', () {
    final router = AssistantRouterService();

    test('Detects Hey Jarvis as default wake word', () async {
      final match = await router.parseWakeWord('Hey Jarvis, who won the game?');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.claude));
      expect(match.cleanQuery, equals('who won the game?'));
    });

    test('Detects Jarvis direct wake word', () async {
      final match = await router.parseWakeWord('Jarvis, open my documents');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.claude));
      expect(match.cleanQuery, equals('open my documents'));
    });

    test('Detects Hey Claude wake word and strips prefix', () async {
      final match = await router.parseWakeWord('Hey Claude, what is the weather?');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.claude));
      expect(match.cleanQuery, equals('what is the weather?'));
    });

    test('Detects Grok wake word', () async {
      final match = await router.parseWakeWord('Grok, explain quantum computing');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.grok));
      expect(match.cleanQuery, equals('explain quantum computing'));
    });

    test('Detects Hey ChatGPT wake word', () async {
      final match = await router.parseWakeWord('Hey ChatGPT, write a python script');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.chatgpt));
      expect(match.cleanQuery, equals('write a python script'));
    });

    test('Detects Gemini wake word', () async {
      final match = await router.parseWakeWord('Hey Gemini, what is my battery level?');
      expect(match.matched, isTrue);
      expect(match.provider, equals(AIProvider.gemini));
      expect(match.cleanQuery, equals('what is my battery level?'));
    });

    test('Routes to default provider when no wake word is present', () async {
      final match = await router.parseWakeWord('Turn off the flashlight');
      expect(match.matched, isFalse);
      expect(match.provider, equals(AIProvider.gemini));
      expect(match.cleanQuery, equals('Turn off the flashlight'));
    });
  });

  group('WakeWordLauncherService (Direct App Launching)', () {
    final launcher = WakeWordLauncherService();

    test('Loads default wake word bindings', () async {
      final bindings = await launcher.getBindings();
      expect(bindings.isNotEmpty, isTrue);
      final jarvis = bindings.firstWhere((b) => b.id == 'jarvis');
      expect(jarvis.wakeWord, equals('Hey Jarvis'));
    });

    test('Allows changing Jarvis target app', () async {
      await launcher.setJarvisTargetApp(
        packageName: 'com.anthropic.claude',
        appName: 'Claude',
      );
      final bindings = await launcher.getBindings();
      final jarvis = bindings.firstWhere((b) => b.id == 'jarvis');
      expect(jarvis.packageName, equals('com.anthropic.claude'));
      expect(jarvis.appName, equals('Claude'));
    });

    test('Matches Hey Jarvis wake word to its bound app', () async {
      final match = await launcher.matchWakeWord('Hey Jarvis');
      expect(match, isNotNull);
      expect(match!.binding.id, equals('jarvis'));
      expect(match.binding.appName, equals('Claude'));
    });

    test('Matches Hey ChatGPT wake word', () async {
      final match = await launcher.matchWakeWord('Hey ChatGPT');
      expect(match, isNotNull);
      expect(match!.binding.packageName, equals('com.openai.chatgpt'));
    });

    test('Matches custom wake word binding', () async {
      await launcher.setBinding(WakeWordAppBinding(
        id: 'notes_app',
        wakeWord: 'Hey Notes',
        packageName: 'com.google.android.keep',
        appName: 'Google Keep',
      ));
      final match = await launcher.matchWakeWord('Hey Notes');
      expect(match, isNotNull);
      expect(match!.binding.appName, equals('Google Keep'));
    });
  });

  group('AiAppsService Launch Intent Query Matching', () {
    final aiApps = AiAppsService();

    test('Matches launch query for installed Claude app', () {
      for (final app in aiApps.catalog) {
        if (app.id == 'claude') app.isInstalled = true;
      }
      final match = aiApps.matchLaunchQuery('open claude');
      expect(match, isNotNull);
      expect(match!.id, equals('claude'));
      expect(match.packageName, equals('com.anthropic.claude'));
    });

    test('Matches launch query for ChatGPT app', () {
      for (final app in aiApps.catalog) {
        if (app.id == 'chatgpt') app.isInstalled = true;
      }
      final match = aiApps.matchLaunchQuery('launch chatgpt');
      expect(match, isNotNull);
      expect(match!.id, equals('chatgpt'));
      expect(match.packageName, equals('com.openai.chatgpt'));
    });

    test('Returns null for non-launch queries', () {
      final match = aiApps.matchLaunchQuery('what is the meaning of life?');
      expect(match, isNull);
    });
  });
}
