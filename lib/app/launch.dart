import 'package:flutter/material.dart';

import '../screens/api_key_setup_screen.dart';
import '../screens/intro_screen.dart';
import '../screens/model_hub_screen.dart';
import '../screens/splash_screen.dart';
import '../services/agent/agent_types.dart';
import '../services/app_settings.dart';
import '../services/llm/providers.dart';
import '../services/local/model_catalog.dart';

/// Central navigation: where the app starts and how every screen switches
/// backends. All "start chatting on X" paths go through [launchAgent], so a
/// mode or model change always reloads the agent instead of leaving the old
/// backend running behind a new label.

sealed class StartDestination {
  const StartDestination();
}

class StartOnboarding extends StartDestination {
  const StartOnboarding();
}

class StartModelPicker extends StartDestination {
  const StartModelPicker();
}

class StartCloudSetup extends StartDestination {
  const StartCloudSetup();
}

class StartAgent extends StartDestination {
  final AgentTarget target;
  const StartAgent(this.target);
}

Future<StartDestination> resolveStartDestination() async {
  if (!await AppSettings.onboardingSeen()) return const StartOnboarding();

  if (await AppSettings.mode() == AgentMode.cloud) {
    final cloud = await savedCloudTarget();
    return cloud == null ? const StartCloudSetup() : StartAgent(cloud);
  }

  final local = await savedLocalTarget();
  return local == null ? const StartModelPicker() : StartAgent(local);
}

/// The saved cloud config, if its key is present. Upgrades installs from the
/// Gemini-only build, which stored just a key.
Future<CloudTarget?> savedCloudTarget() async {
  var config = await AppSettings.cloudConfig();
  if (config == null && await KeyStore.read('gemini') != null) {
    config = const CloudConfig(providerId: 'gemini', model: 'gemini-flash-latest');
    await AppSettings.setCloudConfig(config);
  }
  if (config == null) return null;
  if (config.preset.keyRequired && await KeyStore.read(config.providerId) == null) {
    return null;
  }
  return CloudTarget(config);
}

/// The last-used downloaded model, else any downloaded model.
Future<LocalTarget?> savedLocalTarget() async {
  final downloaded = await ModelCatalog.downloaded();
  if (downloaded.isEmpty) return null;
  final lastId = await AppSettings.lastLocalModel();
  for (final m in downloaded) {
    if (m.id == lastId) return LocalTarget(m);
  }
  return LocalTarget(downloaded.first);
}

Widget screenFor(StartDestination destination) => switch (destination) {
      StartOnboarding() => const IntroScreen(),
      StartModelPicker() => const ModelHubScreen(),
      StartCloudSetup() => const ApiKeySetupScreen(),
      StartAgent(:final target) => SplashScreen(target: target),
    };

Route<T> fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      transitionDuration: const Duration(milliseconds: 250),
    );

/// Loads [target] and opens the chat, replacing the whole navigation stack.
void launchAgent(BuildContext context, AgentTarget target) {
  Navigator.of(context).pushAndRemoveUntil(
    fadeRoute(SplashScreen(target: target)),
    (_) => false,
  );
}

/// Replaces the stack with [page] (used when there's nothing to go back to).
void resetTo(BuildContext context, Widget page) {
  Navigator.of(context).pushAndRemoveUntil(fadeRoute(page), (_) => false);
}
