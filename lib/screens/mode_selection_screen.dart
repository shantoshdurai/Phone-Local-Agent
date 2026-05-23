import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../services/agent_mode.dart';
import 'api_key_setup_screen.dart';
import 'home_screen.dart';

const _kOnboardingSeenKey = 'onboarding_seen_v1';

class ModeSelectionScreen extends StatefulWidget {
  const ModeSelectionScreen({super.key});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  AgentMode? _selected;
  bool _saving = false;

  Future<void> _confirm() async {
    if (_selected == null || _saving) return;
    setState(() => _saving = true);

    await AgentModeStore.write(_selected!);

    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingSeenKey, true);

    if (!mounted) return;

    if (_selected == AgentMode.cloud) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const ApiKeySetupScreen(fromOnboarding: true),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.glassBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Text('Step 2 of 2', style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 12))
                    .animate().fadeIn(duration: 400.ms),
              ),
              const SizedBox(height: 32),
              Text(
                'Where should\nthe agent run?',
                style: AppTextStyles.heading.copyWith(fontSize: 32, color: AppTheme.glassInk, letterSpacing: -1.0, height: 1.1),
              ).animate().fadeIn(delay: 100.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 12),
              Text(
                'You can switch later in Settings. Local stays private; Cloud is faster and smarter, but uses your own API key.',
                style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 14),
              ).animate().fadeIn(delay: 200.ms),
              const SizedBox(height: 32),
              _modeCard(
                mode: AgentMode.local,
                icon: Icons.smartphone_rounded,
                badge: 'PRIVATE',
                title: 'Run on this device',
                bullets: const [
                  ('Offline', 'No internet needed once model is downloaded.'),
                  ('Free', 'No usage costs, ever.'),
                  ('Limited', 'Small phone models miss tool calls sometimes.'),
                ],
              ).animate().fadeIn(delay: 300.ms).moveY(begin: 14, end: 0),
              const SizedBox(height: 16),
              _modeCard(
                mode: AgentMode.cloud,
                icon: Icons.cloud_rounded,
                badge: 'BYO KEY',
                title: 'Use Gemini (your key)',
                bullets: const [
                  ('Smarter', 'Reliable tool calling, multi-step agent flows.'),
                  ('Generous', 'ai.google.dev gives 1,500 requests/day at no cost.'),
                  ('Cloud', 'Your chats are sent to Google with your API key.'),
                ],
              ).animate().fadeIn(delay: 400.ms).moveY(begin: 14, end: 0),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selected == null ? null : _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.glassInk,
                    foregroundColor: AppTheme.glassBg,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: AppTheme.glassBg, strokeWidth: 2))
                      : Text(
                          _selected == AgentMode.cloud ? 'CONTINUE TO API SETUP' : 'CONTINUE',
                          style: AppTextStyles.bodyStrong.copyWith(fontSize: 14),
                        ),
                ),
              ).animate().fadeIn(delay: 600.ms),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeCard({
    required AgentMode mode,
    required IconData icon,
    required String badge,
    required String title,
    required List<(String, String)> bullets,
  }) {
    final selected = _selected == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _selected = mode),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: selected ? AppTheme.glassSurface2 : AppTheme.glassBg2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.glassInk : AppTheme.glassBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppTheme.glassInk, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppTextStyles.heading.copyWith(color: AppTheme.glassInk, fontSize: 18)),
                      const SizedBox(height: 4),
                      Text(badge, style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: selected ? AppTheme.glassInk : AppTheme.glassMuted,
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final b in bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 6, right: 10),
                      width: 4, height: 4,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: AppTheme.glassMuted),
                    ),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 13, height: 1.4),
                          children: [
                            TextSpan(text: '${b.$1}  ', style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk)),
                            TextSpan(text: b.$2),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
