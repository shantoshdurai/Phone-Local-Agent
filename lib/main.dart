import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/model_downloader_service.dart';

const _kOnboardingSeenKey = 'onboarding_seen_v1';
const String kGemmaModelFile = 'gemma-4-E2B-it.litertlm';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the boot path lean — only do the cheap, sync-ish work needed to
  // pick the first route. FlutterGemma + FlutterBackground native init are
  // deferred into AgentService and run lazily the first time chat opens.
  await dotenv.load(fileName: ".env").catchError((_) {});

  final prefs = await SharedPreferences.getInstance();
  final onboardingSeen = prefs.getBool(_kOnboardingSeenKey) ?? false;

  final downloader = ModelDownloaderService();
  final modelReady = await downloader.isModelDownloaded(kGemmaModelFile);

  runApp(MyApp(
    initialModel: modelReady ? kGemmaModelFile : null,
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
      return ChatScreen(modelFileName: initialModel!);
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
