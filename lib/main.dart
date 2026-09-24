import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/launch.dart';
import 'services/app_settings.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  // Only cheap work here: pick the first screen. Model loading happens on
  // the splash screen with visible progress.
  await KeyStore.migrateLegacyKeys();
  final start = await resolveStartDestination();
  runApp(LocalAgentApp(start: start));
}

class LocalAgentApp extends StatelessWidget {
  final StartDestination start;
  const LocalAgentApp({super.key, required this.start});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: screenFor(start),
    );
  }
}
