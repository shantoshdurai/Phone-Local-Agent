import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import 'permissions_screen.dart';

/// Minimalist welcome screen replacing the glowing aurora theme.
class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key});

  void _start(BuildContext context) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const PermissionsScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.glassBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 32.0,
            vertical: 24.0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.glassSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.glassBorder),
                ),
                child: const Center(
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 24,
                    color: AppTheme.glassInk,
                  ),
                ),
              ).animate().fadeIn(duration: 600.ms).moveY(begin: 10, end: 0),
              const SizedBox(height: 32),
              Text(
                'Hello. I\'m your\nlocal AI agent.',
                style: AppTextStyles.heading.copyWith(
                  fontSize: 42,
                  color: AppTheme.glassInk,
                  height: 1.1,
                  letterSpacing: -1.2,
                ),
              )
                  .animate()
                  .fadeIn(delay: 200.ms)
                  .moveY(begin: 10, end: 0),
              const SizedBox(height: 24),
              Text(
                'A private intelligence that lives entirely on your device.\nNo cloud processing. No telemetry.',
                style: AppTextStyles.body.copyWith(
                  color: AppTheme.glassInk2,
                  fontSize: 16,
                ),
              )
                  .animate()
                  .fadeIn(delay: 400.ms)
                  .moveY(begin: 10, end: 0),
              const Spacer(),
              GradientButton(
                onPressed: () => _start(context),
                label: 'CONTINUE',
              )
                  .animate()
                  .fadeIn(delay: 600.ms)
                  .moveY(begin: 20, end: 0),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
