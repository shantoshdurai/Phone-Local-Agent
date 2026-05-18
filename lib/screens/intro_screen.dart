import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import 'permissions_screen.dart';

/// First screen on a fresh install. Welcome + a single CTA into the
/// permission flow. No work is done here — keeping it cheap means the very
/// first thing the user sees paints fast.
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
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 28.0,
                vertical: 24.0,
              ),
              child: Column(
                children: [
                  const Spacer(),
                  _logoMark()
                      .animate()
                      .scale(
                        duration: 800.ms,
                        curve: Curves.easeOutBack,
                      ),
                  const SizedBox(height: 48),
                  Text(
                    'Welcome to\nLocal Agent',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.heading.copyWith(
                      fontSize: 40,
                      color: AppTheme.glassInk,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.4,
                    ),
                  )
                      .animate()
                      .fadeIn(delay: 300.ms)
                      .moveY(begin: 20, end: 0),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'A private AI agent that lives on your phone.\nNo cloud, no telemetry — unless you choose otherwise.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.body.copyWith(
                        color: AppTheme.glassInk2.withValues(alpha: 0.85),
                        fontSize: 15,
                      ),
                    ),
                  )
                      .animate()
                      .fadeIn(delay: 500.ms)
                      .moveY(begin: 20, end: 0),
                  const Spacer(),
                  GradientButton(
                    onPressed: () => _start(context),
                    label: 'GET STARTED',
                  )
                      .animate()
                      .fadeIn(delay: 800.ms)
                      .moveY(begin: 40, end: 0),
                  const SizedBox(height: 16),
                  Text(
                    'Takes about 30 seconds.',
                    style: AppTextStyles.small.copyWith(
                      color: AppTheme.glassMuted,
                    ),
                  ).animate().fadeIn(delay: 1100.ms),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logoMark() {
    return Container(
      width: 124,
      height: 124,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFF1A2540), AppTheme.glassBg],
          stops: [0.0, 1.0],
        ),
        border: Border.all(
          color: AppTheme.glassAccent.withValues(alpha: 0.5),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.glassAccent.withValues(alpha: 0.45),
            blurRadius: 60,
            spreadRadius: 4,
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.auto_awesome_rounded,
          size: 52,
          color: AppTheme.glassAccent2,
        ),
      ),
    );
  }
}
