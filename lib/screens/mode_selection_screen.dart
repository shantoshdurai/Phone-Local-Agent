import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import '../services/agent_mode.dart';
import 'api_key_setup_screen.dart';
import 'home_screen.dart';

const _kOnboardingSeenKey = 'onboarding_seen_v1';

/// 03 · Mode selection — step 02/02 of onboarding.
class ModeSelectionScreen extends StatefulWidget {
  const ModeSelectionScreen({super.key});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  AgentMode _selected = AgentMode.local;
  bool _saving = false;

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    await AgentModeStore.write(_selected);
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
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: const Eyebrow('STEP 02 / 02'),
              ),
              const SizedBox(height: 18),
              Text(
                'Where should\nthe agent run?',
                style: GoogleFonts.interTight(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.8,
                  height: 1.1,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You can switch later in Settings. Local stays private; '
                'Cloud is faster and smarter, but uses your own API key.',
                style: GoogleFonts.interTight(
                  fontSize: 14,
                  height: 1.55,
                  color: AppTheme.ink2,
                ),
              ),
              const SizedBox(height: 24),
              _modeCard(
                mode: AgentMode.local,
                icon: Icons.smartphone_outlined,
                title: 'Run on this device',
                badge: 'PRIVATE',
                bullets: const [
                  ('Offline.', 'No internet needed once the model is downloaded.'),
                  ('Free.', 'No usage costs, ever.'),
                  ('Limited.', 'Small phone models occasionally miss tool calls.'),
                ],
              ),
              const SizedBox(height: 12),
              _modeCard(
                mode: AgentMode.cloud,
                icon: Icons.cloud_outlined,
                title: 'Use API (your key)',
                badge: 'BYO KEY',
                bullets: const [
                  ('Smarter.', 'Reliable tool calling, multi-step agent flows.'),
                  ('Generous.', '1,500 free requests/day on ai.google.dev.'),
                ],
              ),
              const Spacer(),
              const SizedBox(height: 18),
              PrimaryButton(
                onPressed: _saving ? null : _confirm,
                label: 'Continue',
                isLoading: _saving,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeCard({
    required AgentMode mode,
    required IconData icon,
    required String title,
    required String badge,
    required List<(String, String)> bullets,
  }) {
    final selected = _selected == mode;
    return DesignCard(
      selected: selected,
      onTap: () => setState(() => _selected = mode),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 22, color: AppTheme.ink),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.interTight(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Eyebrow(badge),
                  ],
                ),
              ),
              _radio(selected),
            ],
          ),
          const SizedBox(height: 14),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 8, right: 10),
                    width: 4,
                    height: 4,
                    decoration: const BoxDecoration(
                      color: AppTheme.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: GoogleFonts.interTight(
                          fontSize: 12.5,
                          height: 1.45,
                          color: AppTheme.ink2,
                        ),
                        children: [
                          TextSpan(
                            text: '${b.$1} ',
                            style: GoogleFonts.interTight(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.ink,
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
    );
  }

  Widget _radio(bool selected) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppTheme.ink : Colors.transparent,
        border: Border.all(
          color: selected ? AppTheme.ink : AppTheme.muted,
          width: 1.5,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppTheme.bg,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}
