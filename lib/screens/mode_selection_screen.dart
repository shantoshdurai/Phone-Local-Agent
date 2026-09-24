import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/launch.dart';
import '../services/app_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'model_hub_screen.dart';

/// 03 · Where should the agent run — step 2 of 2.
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
    await AppSettings.setMode(_selected);
    await AppSettings.setOnboardingSeen();
    if (!mounted) return;
    // Local → pick/download a model. Cloud → add a key; saving it starts the
    // chat directly (the old flow dropped cloud users on the local model
    // downloader with no way into a chat).
    resetTo(
      context,
      _selected == AgentMode.cloud ? const ApiKeySetupScreen() : const ModelHubScreen(),
    );
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
              const Eyebrow('STEP 2 OF 2'),
              const SizedBox(height: 14),
              Text(
                'Where should\nthe AI run?',
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
                'You can switch any time in Settings.',
                style: GoogleFonts.interTight(fontSize: 14, height: 1.55, color: AppTheme.ink2),
              ),
              const SizedBox(height: 24),
              _modeCard(
                mode: AgentMode.local,
                icon: Icons.smartphone_outlined,
                title: 'On this phone',
                badge: 'PRIVATE · OFFLINE',
                bullets: const [
                  ('Private.', 'Nothing leaves your phone.'),
                  ('Free.', 'A one-time model download (0.6–2.5 GB).'),
                  ('Needs a good phone.', 'Slower and less capable than cloud models.'),
                ],
              ),
              const SizedBox(height: 12),
              _modeCard(
                mode: AgentMode.cloud,
                icon: Icons.cloud_outlined,
                title: 'Cloud, with your API key',
                badge: 'FAST · SMART',
                bullets: const [
                  ('Works on any phone.', 'Fast, reliable multi-step tool use.'),
                  ('Your key, your data.', 'Gemini has a free tier; Claude, OpenAI and others are paid.'),
                ],
              ),
              const Spacer(),
              const SizedBox(height: 18),
              PrimaryButton(onPressed: _saving ? null : _confirm, label: 'Continue', isLoading: _saving),
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
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 22, color: AppTheme.ink)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: GoogleFonts.interTight(
                            fontSize: 16, fontWeight: FontWeight.w600, height: 1.2, color: AppTheme.ink)),
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
                    decoration: BoxDecoration(color: AppTheme.muted, shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: GoogleFonts.interTight(fontSize: 12.5, height: 1.45, color: AppTheme.ink2),
                        children: [
                          TextSpan(
                            text: '${b.$1} ',
                            style: GoogleFonts.interTight(
                                fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.ink),
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
        border: Border.all(color: selected ? AppTheme.ink : AppTheme.muted, width: 1.5),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: AppTheme.bg, shape: BoxShape.circle),
              ),
            )
          : null,
    );
  }
}
