import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'permissions_screen.dart';

/// 01 · Intro — first run welcome.
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
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              const BrandMark.large(),
              const SizedBox(height: 28),
              const Eyebrow('LOCAL AGENT · v0.4'),
              const SizedBox(height: 18),
              Text(
                "Hello.\nI'm your\nlocal AI agent.",
                style: GoogleFonts.interTight(
                  fontSize: 42,
                  fontWeight: FontWeight.w600,
                  height: 1.05,
                  letterSpacing: -1.4,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 320,
                child: Text(
                  'A private intelligence that lives entirely on your device. '
                  'No cloud processing. No telemetry.',
                  style: GoogleFonts.interTight(
                    fontSize: 14,
                    height: 1.55,
                    color: AppTheme.ink2,
                  ),
                ),
              ),
              const Spacer(),
              PrimaryButton(
                onPressed: () => _start(context),
                label: 'Continue',
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.success,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.success.withValues(alpha: 0.12),
                          blurRadius: 0,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'RUNS 100% OFFLINE ON THIS DEVICE',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 10,
                      letterSpacing: 1.4,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
