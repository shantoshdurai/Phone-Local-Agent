import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/api_key_setup_screen.dart';
import 'screens/home_screen.dart';
import 'screens/intro_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/voice_mode_screen.dart';
import 'services/agent_mode.dart';
import 'services/agent_service.dart';
import 'services/assistant_router_service.dart';
import 'services/database_service.dart';
import 'services/model_downloader_service.dart';
import 'services/model_registry.dart';
import 'theme/app_theme.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const _kOnboardingSeenKey = 'onboarding_seen_v1';
const _kLastModelKey = 'last_used_model_file';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the boot path lean — only the cheap sync-ish work needed to pick
  // the first route. FlutterGemma + FlutterBackground native init are
  // deferred into AgentService and run lazily the first time chat opens.
  await dotenv.load(fileName: ".env").catchError((_) {});

  final prefs = await SharedPreferences.getInstance();
  final onboardingSeen = prefs.getBool(_kOnboardingSeenKey) ?? false;
  final mode = await AgentModeStore.read();
  final apiKey = await AgentModeStore.readApiKey();
  final lastModel = prefs.getString(_kLastModelKey);

  String? initialModel;

  if (onboardingSeen) {
    if (mode == AgentMode.cloud && apiKey != null) {
      // Skip the local downloader path entirely — splash will init Gemini.
      initialModel = kCloudModelSentinel;
    } else if (mode == AgentMode.cloud) {
      // Cloud picked but key missing — handled below by routing to setup.
      initialModel = null;
    } else {
      // Local (or unset, which we treat as local for backwards-compat with
      // installs from before the mode picker existed).
      final downloader = ModelDownloaderService();

      // Only honor `lastModel` when it still matches a model the app
      // currently ships. Otherwise we'd hand the SDK a file whose modelType
      // / fileType no longer match anything in the registry — that's the
      // "is a LiteRT-LM model … not by EngineFactory" crash that hits
      // anyone upgrading from an install that still has the old Gemma 4
      // `.litertlm` lying around.
      final registryFileNames =
          ModelRegistry.all.map((s) => s.fileName).toSet();
      final lastModelKnown =
          lastModel != null && registryFileNames.contains(lastModel);

      if (lastModelKnown && await downloader.isModelDownloaded(lastModel)) {
        initialModel = lastModel;
      } else {
        // Stale or unknown — wipe so we don't keep re-resolving to it.
        if (lastModel != null && !lastModelKnown) {
          await prefs.remove(_kLastModelKey);
        }
        for (final spec in ModelRegistry.all) {
          if (await downloader.isModelDownloaded(spec.fileName)) {
            initialModel = spec.fileName;
            break;
          }
        }
      }
    }
  }

  int? assistantSessionId;
  final wasAssistant = await AssistantRouterService().wasLaunchedAsAssistant();
  if (wasAssistant) {
    try {
      assistantSessionId = await DatabaseService().createSession('Voice Assistant');
    } catch (_) {}
  }

  runApp(MyApp(
    initialModel: initialModel,
    showOnboarding: !onboardingSeen,
    cloudNeedsKey: onboardingSeen && mode == AgentMode.cloud && apiKey == null,
    assistantSessionId: assistantSessionId,
  ));
}

class MyApp extends StatefulWidget {
  final String? initialModel;
  final bool showOnboarding;
  final bool cloudNeedsKey;
  final int? assistantSessionId;
  const MyApp({
    super.key,
    this.initialModel,
    this.showOnboarding = false,
    this.cloudNeedsKey = false,
    this.assistantSessionId,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _assistantSub;

  @override
  void initState() {
    super.initState();
    _assistantSub =
        AssistantRouterService().assistantEvents.listen((event) async {
      if (event == 'assist') {
        try {
          final sessionId =
              await DatabaseService().createSession('Voice Assistant');
          appNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VoiceModeScreen(sessionId: sessionId),
            ),
          );
        } catch (_) {}
      }
    });
  }

  @override
  void dispose() {
    _assistantSub?.cancel();
    super.dispose();
  }

  Widget _resolveHome() {
    if (widget.assistantSessionId != null) {
      return VoiceModeScreen(sessionId: widget.assistantSessionId!);
    }
    if (widget.showOnboarding) {
      return const IntroScreen();
    }
    if (widget.cloudNeedsKey) {
      // Mode is cloud but no key on disk — drop straight into the key
      // entry screen. fromOnboarding=false so saving pops back; we then
      // catch them on the next launch via the splash path.
      return const ApiKeySetupScreen(fromOnboarding: false);
    }
    if (widget.initialModel != null) {
      return SplashScreen(modelFileName: widget.initialModel!);
    }
    return const HomeScreen();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Local Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: _resolveHome(),
    );
  }
}
