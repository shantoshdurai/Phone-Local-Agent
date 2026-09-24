import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/launch.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'permissions_screen.dart';

/// 01 · Intro — first-run welcome.
class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key});

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
              const Eyebrow('LOCAL AGENT'),
              const SizedBox(height: 18),
              Text(
                "Hello.\nI'm your\nphone's AI agent.",
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
                width: 330,
                child: Text(
                  'Ask questions and get things done on your phone — flashlight, timers, '
                  'calls, weather, search and more. Run the AI privately on this device, '
                  'or with your own API key. No account, no tracking.',
                  style: GoogleFonts.interTight(fontSize: 14, height: 1.55, color: AppTheme.ink2),
                ),
              ),
              const Spacer(),
              PrimaryButton(
                onPressed: () => Navigator.of(context).pushReplacement(fadeRoute(const PermissionsScreen())),
                label: 'Get started',
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
                        BoxShadow(color: AppTheme.success.withValues(alpha: 0.12), spreadRadius: 4),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ON-DEVICE OR BRING YOUR OWN KEY',
                    style: GoogleFonts.jetBrainsMono(fontSize: 10, letterSpacing: 1.4, color: AppTheme.muted),
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
