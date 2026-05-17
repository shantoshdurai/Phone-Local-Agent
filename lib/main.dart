import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/model_downloader_service.dart';
import 'services/model_registry.dart';

const _kOnboardingSeenKey = 'onboarding_seen_v1';
const _kLastModelKey = 'last_used_model_file';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the boot path lean — only do the cheap, sync-ish work needed to
  // pick the first route. FlutterGemma + FlutterBackground native init are
  // deferred into AgentService and run lazily the first time chat opens.
  await dotenv.load(fileName: ".env").catchError((_) {});

  final prefs = await SharedPreferences.getInstance();
  final onboardingSeen = prefs.getBool(_kOnboardingSeenKey) ?? false;
  final lastModel = prefs.getString(_kLastModelKey);

  final downloader = ModelDownloaderService();

  // Prefer the model the user last opened; otherwise jump into whichever
  // registered model is already downloaded. If none, fall through to Home.
  String? initialModel;
  if (lastModel != null &&
      await downloader.isModelDownloaded(lastModel)) {
    initialModel = lastModel;
  } else {
    for (final spec in ModelRegistry.all) {
      if (await downloader.isModelDownloaded(spec.fileName)) {
        initialModel = spec.fileName;
        break;
      }
    }
  }

  runApp(MyApp(
    initialModel: initialModel,
    showOnboarding: !onboardingSeen,
  ));
}

class MyApp extends StatelessWidget {
  final String? initialModel;
  final bool showOnboarding;
  const MyApp({super.key, this.initialModel, this.showOnboarding = false});

  Widget _resolveHome() {
    if (showOnboarding) {
      return OnboardingScreen(
        onFinished: () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_kOnboardingSeenKey, true);
        },
      );
    }
    if (initialModel != null) {
      return SplashScreen(modelFileName: initialModel!);
    }
    return const HomeScreen();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: _resolveHome(),
    );
  }
}
