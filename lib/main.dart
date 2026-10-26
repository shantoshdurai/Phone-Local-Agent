import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/provider_setup_screen.dart';
import 'screens/splash_screen.dart';
import 'services/agent_mode.dart';
import 'services/agent_service.dart';
import 'services/app_settings.dart';
import 'services/assistant_service.dart';
import 'services/device_capability.dart';
import 'services/llm/provider_config.dart';
import 'services/model_downloader_service.dart';
import 'services/model_registry.dart';
import 'services/permission_flow.dart';
import 'services/startup_trace.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

void main() async {
  StartupTrace.mark('app_main');
  WidgetsFlutterBinding.ensureInitialized();

  // Boot path budget: everything before `runApp` is time the user spends
  // looking at the launcher icon. SharedPreferences and the mode/key read are
  // single platform-channel calls; the model check is only two `File.exists`
  // stats and only runs for an existing local install.
  final prefs = await SharedPreferences.getInstance();
  // Reuse the instance that is already open — no extra platform round trip.
  // ignore: discarded_futures
  AppSettings.load();
  await ThemeController.instance.load();
  final onboardingSeen = prefs.getBool(kOnboardingSeenPref) ?? false;
  final provider = await ProviderStore.readProvider();
  final hasRemoteCredential = provider == LlmProvider.local
      ? false
      : await ProviderStore.hasCredential(provider);
  final lastModel = prefs.getString(kLastModelPref);

  String? initialModel;

  if (onboardingSeen) {
    if (provider != LlmProvider.local) {
      // API-first: no model download, straight to chat once a credential
      // exists (user key or the optional build-time demo key).
      initialModel = hasRemoteCredential ? kCloudModelSentinel : null;
    } else {
      final downloader = ModelDownloaderService();
      final registryFileNames =
          ModelRegistry.all.map((s) => s.fileName).toSet();
      final lastModelKnown =
          lastModel != null && registryFileNames.contains(lastModel);

      if (lastModelKnown && await downloader.isModelDownloaded(lastModel)) {
        initialModel = lastModel;
      } else {
        if (lastModel != null && !lastModelKnown) {
          await prefs.remove(kLastModelPref);
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

  // Did we get here from the assistant gesture or a share sheet?
  await AssistantService.instance.init();
  final launchEvent = AssistantService.instance.takePending();

  // Kick off the device scan off the critical path. Onboarding and the model
  // store both consume the cached result; doing it here means the onboarding
  // "checking your phone" step is usually already resolved when it appears.
  // ignore: discarded_futures
  DeviceCapability.scan().then((p) {
    if (p.sdkInt > 0) PermissionFlow.configure(sdkInt: p.sdkInt);
  });

  runApp(MyApp(
    initialModel: initialModel,
    showOnboarding: !onboardingSeen,
    cloudNeedsKey:
        onboardingSeen && provider != LlmProvider.local && !hasRemoteCredential,
    launchEvent: launchEvent,
  ));
  // Measured after the first frame is actually painted, not when runApp is
  // called — those differ by tens of milliseconds on a cold process.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => StartupTrace.mark('first_frame'),
  );
}

class MyApp extends StatefulWidget {
  final String? initialModel;
  final bool showOnboarding;
  final bool cloudNeedsKey;
  final LaunchEvent? launchEvent;

  const MyApp({
    super.key,
    this.initialModel,
    this.showOnboarding = false,
    this.cloudNeedsKey = false,
    this.launchEvent,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<LaunchEvent>? _launchSub;

  @override
  void initState() {
    super.initState();
    // Assistant/share invocations while the app is alive land here when no
    // chat is on screen (e.g. the user shared text from Settings).
    _launchSub = AssistantService.instance.events.listen(_onLaunch);
  }

  @override
  void dispose() {
    _launchSub?.cancel();
    super.dispose();
  }

  void _onLaunch(LaunchEvent event) {
    // ChatScreen subscribes to the same stream and handles events itself;
    // pushing a second chat on top would lose the reply.
    if (ChatScreen.mountedCount > 0) return;

    final model = widget.initialModel;
    if (model == null) return; // still onboarding — nothing to route to

    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => SplashScreen(
          modelFileName: model,
          launchEvent: event,
        ),
      ),
    );
  }

  Widget _resolveHome() {
    if (widget.showOnboarding) {
      return const OnboardingScreen();
    }
    if (widget.cloudNeedsKey) {
      // fromOnboarding: true gives this screen a back target and makes a
      // skip fall back to local mode instead of leaving the app with
      // "cloud" selected and no key.
      return const ProviderSetupScreen(fromOnboarding: true);
    }
    if (widget.initialModel != null) {
      return SplashScreen(
        modelFileName: widget.initialModel!,
        launchEvent: widget.launchEvent,
      );
    }
    return const HomeScreen();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilding the whole MaterialApp on a palette change repaints every
    // screen while keeping navigation and state intact.
    return ValueListenableBuilder<AppPalette>(
      valueListenable: ThemeController.instance,
      builder: (context, palette, _) => MaterialApp(
        title: 'Agent',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        theme: AppTheme.darkTheme,
        home: _resolveHome(),
      ),
    );
  }
}
