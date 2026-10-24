import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/assistant_service.dart';
import '../services/permission_flow.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// Clear, one-screen explanation and granting of the four system gates the
/// assistant needs. Ported from the `experimental-ai-assistant` branch, which
/// did this better than a buried switch: each row says what it is for, shows
/// live state, and opens the exact system screen when Android won't show a
/// dialog.
class AssistantSetupScreen extends StatefulWidget {
  const AssistantSetupScreen({super.key});

  @override
  State<AssistantSetupScreen> createState() => _AssistantSetupScreenState();
}

class _AssistantSetupScreenState extends State<AssistantSetupScreen>
    with WidgetsBindingObserver {
  final AssistantService _assistant = AssistantService.instance;

  bool _loading = true;
  bool _isDefault = false;
  bool _overlay = false;
  bool _batteryOk = false;
  bool _mic = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final isDefault = await _assistant.isDefaultAssistant();
    final overlay = await _assistant.isOverlayGranted();
    final battery = await _assistant.isIgnoringBatteryOptimizations();
    final mic = await PermissionFlow.isGranted(PermTopic.microphone);
    if (!mounted) return;
    setState(() {
      _isDefault = isDefault;
      _overlay = overlay;
      _batteryOk = battery;
      _mic = mic;
      _loading = false;
    });
  }

  Future<void> _chooseAssistant() async {
    if (_isDefault) {
      await _assistant.openAssistantSettings();
      return;
    }
    final opened = await _assistant.requestDefaultAssistant();
    if (!opened) {
      // No ROLE_ASSISTANT dialog on this device — send them to the system
      // screen where the OEM exposes it.
      await _assistant.openAssistantSettings();
    }
    await _refresh();
  }

  Future<void> _grantMic() async {
    await PermissionFlow.request(
      PermTopic.microphone,
      onPermanentlyDenied: () => PermissionFlow.openSettings(),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(
                'Assistant',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppTheme.muted,
                        ),
                      ),
                    )
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      children: [
                        Text(
                          _isDefault
                              ? 'Agent is your assistant.'
                              : 'Make Agent your assistant.',
                          style: GoogleFonts.interTight(
                            fontSize: 26,
                            height: 1.14,
                            letterSpacing: -0.9,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Four system gates make the power-button gesture, '
                          'voice and long answers work. Each one is optional, '
                          'and each opens the exact Android screen.',
                          style: GoogleFonts.interTight(
                            fontSize: 13,
                            height: 1.5,
                            color: AppTheme.ink2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _gateCard(
                          icon: Icons.assistant_navigation,
                          title: 'Default assistant',
                          why: 'Long-press the power button (on phones that map '
                              'it to the assistant) opens Agent, listening.',
                          granted: _isDefault,
                          actionLabel: _isDefault ? 'Settings' : 'Choose',
                          onTap: _chooseAssistant,
                          highlight: true,
                        ),
                        _gateCard(
                          icon: Icons.mic_none_rounded,
                          title: 'Microphone',
                          why: 'Voice mode and the assistant gesture need it to '
                              'hear you. Audio is transcribed on-device.',
                          granted: _mic,
                          actionLabel: _mic ? 'Granted' : 'Allow',
                          onTap: _mic ? null : _grantMic,
                        ),
                        _gateCard(
                          icon: Icons.layers_outlined,
                          title: 'Display over other apps',
                          why: 'Lets the listening overlay appear above the app '
                              'you are in, instead of switching screens.',
                          granted: _overlay,
                          actionLabel: _overlay ? 'Granted' : 'Open',
                          onTap: _overlay
                              ? null
                              : () async {
                                  await _assistant.openOverlaySettings();
                                  await _refresh();
                                },
                        ),
                        _gateCard(
                          icon: Icons.battery_saver_outlined,
                          title: 'Battery optimisation',
                          why: 'Stops Android from killing a long answer when '
                              'the screen turns off.',
                          granted: _batteryOk,
                          actionLabel: _batteryOk ? 'Granted' : 'Open',
                          onTap: _batteryOk
                              ? null
                              : () async {
                                  await _assistant.openBatterySettings();
                                  await _refresh();
                                },
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'If your phone does not offer an assistant role, the '
                          'power-button gesture is controlled by the '
                          'manufacturer; the rest still works from the app icon.',
                          style: GoogleFonts.interTight(
                            fontSize: 11.5,
                            height: 1.55,
                            color: AppTheme.muted2,
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

  Widget _gateCard({
    required IconData icon,
    required String title,
    required String why,
    required bool granted,
    required String actionLabel,
    required VoidCallback? onTap,
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DesignCard(
        selected: highlight && granted,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: granted ? AppTheme.ink : AppTheme.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: GoogleFonts.interTight(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Pill(
                        granted ? 'ON' : 'OFF',
                        style: granted
                            ? PillStyle.success
                            : PillStyle.surface,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    why,
                    style: GoogleFonts.interTight(
                      fontSize: 11.5,
                      height: 1.45,
                      color: AppTheme.ink2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(
                actionLabel.toUpperCase(),
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: onTap == null ? AppTheme.muted : AppTheme.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
