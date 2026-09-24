import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/launch.dart';
import 'services/app_settings.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.load();
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
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
    return ValueListenableBuilder<AppPalette>(
      valueListenable: ThemeController.instance,
      builder: (context, palette, _) => MaterialApp(
        title: 'Local Agent',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        home: screenFor(start),
      ),
    );
  }
}
