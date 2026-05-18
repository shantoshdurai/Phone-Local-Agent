import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import '../services/agent_mode.dart';
import 'api_key_setup_screen.dart';
import 'home_screen.dart';

const _kOnboardingSeenKey = 'onboarding_seen_v1';

/// Step 2/2 — pick how the agent will think. Local (on-device) keeps
/// the privacy story; Cloud (Gemini, BYO key) trades that for better
/// quality on hard agent flows.
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

    // Mark onboarding complete *only* once the user picks a mode — that way
    // killing the app mid-flow brings them right back into mode selection
    // instead of the home screen with no mode wired up.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingSeenKey, true);

    if (!mounted) return;

    if (_selected == AgentMode.cloud) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) =>
              const ApiKeySetupScreen(fromOnboarding: true),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
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
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: const StepIndicator(step: 2, total: 2)
                        .animate()
                        .fadeIn(duration: 400.ms),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Where should\nthe agent run?',
                    style: AppTextStyles.heading.copyWith(
                      fontSize: 32,
                      color: AppTheme.glassInk,
                      letterSpacing: -1.0,
                      height: 1.1,
                    ),
                  ).animate().fadeIn(delay: 100.ms).moveY(begin: 12, end: 0),
                  const SizedBox(height: 10),
                  Text(
                    'You can switch later in Settings. Local stays private; Cloud is faster and smarter, but uses your own API key.',
                    style: AppTextStyles.body.copyWith(
                      color: AppTheme.glassInk2.withValues(alpha: 0.8),
                      fontSize: 14,
                    ),
                  ).animate().fadeIn(delay: 200.ms),
                  const SizedBox(height: 28),
                  _modeCard(
                    mode: AgentMode.local,
                    icon: Icons.smartphone_rounded,
                    badge: 'PRIVATE',
                    title: 'Run on this device',
                    bullets: const [
                      ('Offline', 'No internet needed once the model is downloaded.'),
                      ('Free', 'No usage costs, ever.'),
                      ('Limited', 'Small phone models miss tool calls sometimes.'),
                    ],
                    accent: AppTheme.glassAccent,
                  ).animate().fadeIn(delay: 300.ms).moveY(begin: 14, end: 0),
                  const SizedBox(height: 14),
                  _modeCard(
                    mode: AgentMode.cloud,
                    icon: Icons.cloud_rounded,
                    badge: 'BYO KEY',
                    title: 'Use Gemini (your key)',
                    bullets: const [
                      ('Smarter', 'Reliable tool calling, multi-step agent flows.'),
                      ('Generous free tier', 'ai.google.dev gives you 1,500 requests/day at no cost.'),
                      ('Leaves device', 'Your chats are sent to Google with your API key.'),
                    ],
                    accent: AppTheme.glassMagenta,
                  ).animate().fadeIn(delay: 400.ms).moveY(begin: 14, end: 0),
                  const SizedBox(height: 28),
                  GradientButton(
                    onPressed: _selected == null ? null : _confirm,
                    isLoading: _saving,
                    label: _selected == AgentMode.cloud
                        ? 'CONTINUE TO API SETUP'
                        : 'CONTINUE',
                  ).animate().fadeIn(delay: 600.ms),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeCard({
    required AgentMode mode,
    required IconData icon,
    required String badge,
    required String title,
    required List<(String, String)> bullets,
    required Color accent,
  }) {
    final selected = _selected == mode;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => setState(() => _selected = mode),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          borderRadius: BorderRadius.circular(22),
          blur: 25,
          opacity: selected ? 0.09 : 0.04,
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.6)
                : AppTheme.glassBorder,
            width: selected ? 1.5 : 0.9,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(alpha: 0.15),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.5),
                        width: 1,
                      ),
                    ),
                    child: Icon(icon, color: accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppTextStyles.title.copyWith(
                            color: AppTheme.glassInk,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: accent.withValues(alpha: 0.12),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.4),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            badge,
                            style: AppTextStyles.mono.copyWith(
                              color: accent,
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? accent : Colors.transparent,
                      border: Border.all(
                        color: selected ? accent : AppTheme.glassBorder2,
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? const Icon(Icons.check_rounded,
                            size: 14, color: Colors.white)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: AppTextStyles.small.copyWith(
                              color: AppTheme.glassInk2.withValues(alpha: 0.85),
                              fontSize: 13,
                              height: 1.4,
                            ),
                            children: [
                              TextSpan(
                                text: '${b.$1}  ',
                                style: AppTextStyles.bodyStrong.copyWith(
                                  color: AppTheme.glassInk,
                                  fontSize: 13,
                                ),
                              ),
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
      ),
    );
  }
}
