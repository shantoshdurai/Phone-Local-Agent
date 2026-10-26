import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/agent_mode.dart';
import '../../services/agent_service.dart' show kCloudModelSentinel;
import '../../services/llm/provider_config.dart';
import '../../services/needle/needle_service.dart';
import '../../services/permission_flow.dart';
import '../../theme/app_theme.dart';
import '../../widgets/design_components.dart';
import '../splash_screen.dart';

/// Opal-style onboarding: three smooth slides introducing the dual-engine setup:
/// - Slide 1: Welcome & vision
/// - Slide 2: How it works (DeepSeek Cloud + Cactus Needle 3 Edge Assistant + Model Hub)
/// - Slide 3: Permissions & instant launch into DeepSeek Chat
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, howItWorks, permissions }

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  _Step _step = _Step.welcome;
  bool _micGranted = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshMic();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _Step.permissions) {
      _refreshMic();
    }
  }

  Future<void> _refreshMic() async {
    final ok = await PermissionFlow.isGranted(PermTopic.microphone);
    if (!mounted) return;
    setState(() => _micGranted = ok);
  }

  void _goTo(_Step step) {
    if (_step == step) return;
    setState(() => _step = step);
  }

  Future<void> _finishIntoChat() async {
    if (_finishing) return;
    setState(() => _finishing = true);

    final openRouterKey = ProviderConfig.openRouterFreeKey;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingSeenPref, true);
    await ProviderStore.writeProvider(LlmProvider.openrouter);
    await ProviderStore.writeKey(LlmProvider.openrouter, openRouterKey);
    await ProviderStore.writeModel(
      LlmProvider.openrouter,
      'deepseek/deepseek-v4.1-flash',
    );
    await AgentModeStore.write(AgentMode.cloud);

    // Warm up Needle 3 in background for power-button assistant / phone tools
    unawaited(NeedleService.instance.ensureReady());

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 360),
        pageBuilder: (_, __, ___) =>
            const SplashScreen(modelFileName: kCloudModelSentinel),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: _AuroraBackground(animate: !reduceMotion),
          ),
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final slide = Tween<Offset>(
                        begin: const Offset(0, 0.035),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(position: slide, child: child),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(_step.name),
                      child: _buildStep(),
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

  Widget _topBar() {
    final canBack = _step != _Step.welcome;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: canBack
                ? IconButton(
                    onPressed: () => _goTo(
                      _step == _Step.permissions
                          ? _Step.howItWorks
                          : _Step.welcome,
                    ),
                    icon: Icon(Icons.arrow_back_rounded,
                        size: 20, color: AppTheme.ink2),
                    tooltip: 'Back',
                  )
                : null,
          ),
          Expanded(
            child: Center(
              child: _StepDots(
                count: 3,
                current: _step.index,
              ),
            ),
          ),
          const SizedBox(width: 52),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.welcome:
        return _welcome();
      case _Step.howItWorks:
        return _howItWorks();
      case _Step.permissions:
        return _permissions();
    }
  }

  // ── Step 1: Welcome & Vision ──────────────────────────────────────────────

  Widget _welcome() {
    return _ScrollableStep(
      center: true,
      children: [
        const SizedBox(height: 32),
        Center(
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFF8A8A8A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.18),
                  blurRadius: 42,
                  spreadRadius: -6,
                ),
              ],
            ),
            child: const Center(
              child: SparkleIcon(size: 38, color: Color(0xFF0A0A0A)),
            ),
          ),
        ).animate().fadeIn(duration: 500.ms).scale(
              begin: const Offset(0.86, 0.86),
              curve: Curves.easeOutBack,
              duration: 700.ms,
            ),
        const SizedBox(height: 32),
        const Eyebrow('LOCAL AGENT'),
        const SizedBox(height: 10),
        Text(
          'Your phone,\nfinally thinking.',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 38,
            height: 1.06,
            letterSpacing: -1.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ).animate(delay: 120.ms).fadeIn(duration: 460.ms).slideY(
              begin: 0.16,
              end: 0,
              curve: Curves.easeOutCubic,
              duration: 620.ms,
            ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'A fast, intelligent AI that actually acts on your phone — calls, '
            'WhatsApp, device settings, alarms, and live web research.',
            textAlign: TextAlign.center,
            style: GoogleFonts.interTight(
              fontSize: 15,
              height: 1.55,
              color: AppTheme.ink2,
            ),
          ),
        ).animate(delay: 210.ms).fadeIn(duration: 460.ms).slideY(
              begin: 0.12,
              end: 0,
              duration: 620.ms,
              curve: Curves.easeOutCubic,
            ),
        const SizedBox(height: 28),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill('Cloud Agent', style: PillStyle.outline),
            Pill('Needle 3 Edge', style: PillStyle.success),
            Pill('Open Models', style: PillStyle.outline),
          ],
        ).animate(delay: 300.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 36),
        PrimaryButton(
          onPressed: () => _goTo(_Step.howItWorks),
          label: 'Continue',
          icon: Icons.arrow_forward_rounded,
        ).animate(delay: 380.ms).fadeIn(duration: 400.ms).slideY(begin: 0.2),
        const SizedBox(height: 12),
        Text(
          'No credit card. Free unlimited conversational intelligence.',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 12,
            color: AppTheme.muted,
          ),
        ).animate(delay: 460.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── Step 2: How It Works (Dual Engine) ───────────────────────────────────

  Widget _howItWorks() {
    return _ScrollableStep(
      children: [
        const SizedBox(height: 8),
        const Eyebrow('DUAL ENGINE'),
        const SizedBox(height: 10),
        Text(
          'Two engines.\nZero compromises.',
          style: GoogleFonts.interTight(
            fontSize: 30,
            height: 1.1,
            letterSpacing: -1.0,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
        const SizedBox(height: 10),
        Text(
          'Deep conversation in the cloud, paired with instant on-device tools '
          'at your fingertips.',
          style: GoogleFonts.interTight(
            fontSize: 14.5,
            height: 1.5,
            color: AppTheme.ink2,
          ),
        ).animate(delay: 100.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 22),

        // Card 1: Cloud Agent
        _FeatureCard(
          icon: Icons.bolt_rounded,
          badge: 'DEFAULT CHAT',
          badgeStyle: PillStyle.solid,
          title: 'Cloud Agent',
          description:
              'Free, unlimited conversational AI. Ask anything, '
              'reason through complex questions, and search the live web.',
        ).animate(delay: 160.ms).fadeIn(duration: 450.ms).slideY(begin: 0.08),

        const SizedBox(height: 12),

        // Card 2: Cactus Needle 3
        _FeatureCard(
          icon: Icons.power_settings_new_rounded,
          badge: 'BUILT-IN · 34 MB',
          badgeStyle: PillStyle.success,
          title: 'Cactus Needle 3 (Assistant)',
          description:
              'Long-press your phone\'s power button anytime. Needle 3 runs 100% offline '
              'to open apps, call contacts, send WhatsApp, and toggle settings with 0ms lag.',
        ).animate(delay: 240.ms).fadeIn(duration: 450.ms).slideY(begin: 0.08),

        const SizedBox(height: 12),

        // Card 3: Open Model Hub
        _FeatureCard(
          icon: Icons.hub_rounded,
          badge: 'IN SETTINGS',
          badgeStyle: PillStyle.outline,
          title: 'Open Model Hub (Optional)',
          description:
              'Want to experiment with full on-device weights? Download Qwen 2.5 or '
              'Phi-4 mini from Settings whenever you prefer 100% offline chat.',
        ).animate(delay: 320.ms).fadeIn(duration: 450.ms).slideY(begin: 0.08),

        const SizedBox(height: 28),
        PrimaryButton(
          onPressed: () => _goTo(_Step.permissions),
          label: 'Continue',
          icon: Icons.arrow_forward_rounded,
        ).animate(delay: 400.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 16),
      ],
    );
  }

  // ── Step 3: Permissions & Instant Launch ─────────────────────────────────

  Widget _permissions() {
    final info = kPermTopics[PermTopic.microphone]!;

    return _ScrollableStep(
      children: [
        const SizedBox(height: 8),
        const Eyebrow('MAKE IT YOURS'),
        const SizedBox(height: 10),
        Text(
          'Ready to roll.',
          style: GoogleFonts.interTight(
            fontSize: 30,
            height: 1.1,
            letterSpacing: -1.0,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
        const SizedBox(height: 10),
        Text(
          'Enable voice mode so your assistant can hear your commands. Audio '
          'is processed locally on your phone and never stored.',
          style: GoogleFonts.interTight(
            fontSize: 14.5,
            height: 1.5,
            color: AppTheme.ink2,
          ),
        ).animate(delay: 100.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 22),

        // Microphone permission
        _PermissionTile(
          info: info,
          granted: _micGranted,
          onTap: () async {
            final ok = await PermissionFlow.request(
              PermTopic.microphone,
              onPermanentlyDenied: () => _showSettingsHint(),
            );
            if (!mounted) return;
            setState(() => _micGranted = ok);
          },
        ).animate(delay: 160.ms).fadeIn(duration: 450.ms),

        const SizedBox(height: 14),

        // Assistant tip
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.touch_app_rounded, size: 18, color: AppTheme.ink),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hold Power Button',
                      style: GoogleFonts.interTight(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Set Local Agent as your default assistant in settings for '
                      'one-touch voice actions anywhere on your phone.',
                      style: GoogleFonts.interTight(
                        fontSize: 12,
                        height: 1.45,
                        color: AppTheme.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ).animate(delay: 240.ms).fadeIn(duration: 450.ms),

        const SizedBox(height: 32),

        PrimaryButton(
          onPressed: _finishing ? null : _finishIntoChat,
          label: 'Start Chatting',
          icon: Icons.chat_bubble_outline_rounded,
          isLoading: _finishing,
        ).animate(delay: 320.ms).fadeIn(duration: 400.ms).slideY(begin: 0.1),

        const SizedBox(height: 12),

        Center(
          child: Text(
            'Cloud Agent · Free unlimited tier',
            style: GoogleFonts.interTight(
              fontSize: 11.5,
              color: AppTheme.muted,
            ),
          ),
        ).animate(delay: 400.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 16),
      ],
    );
  }

  void _showSettingsHint() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Microphone is blocked. Enable it in Settings.'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => PermissionFlow.openSettings(),
        ),
      ),
    );
  }
}

// ── Building blocks ────────────────────────────────────────────────────────

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String badge;
  final PillStyle badgeStyle;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.badge,
    required this.badgeStyle,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.surface2,
                ),
                child: Icon(icon, size: 18, color: AppTheme.ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.interTight(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Pill(badge, style: badgeStyle),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: GoogleFonts.interTight(
              fontSize: 12.5,
              height: 1.5,
              color: AppTheme.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScrollableStep extends StatelessWidget {
  final List<Widget> children;
  final bool center;
  const _ScrollableStep({required this.children, this.center = false});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: center
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: children,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
          ),
        );
      },
    );
  }
}

class _AuroraBackground extends StatefulWidget {
  final bool animate;
  const _AuroraBackground({this.animate = true});

  @override
  State<_AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<_AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
    if (widget.animate) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      if (widget.animate) {
        _ctrl.repeat(reverse: true);
      } else {
        _ctrl.stop();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.palette;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final x1 = 0.5 + 0.28 * math.sin(t * 2 * math.pi);
        final y1 = 0.18 + 0.10 * math.cos(t * 2 * math.pi);
        final x2 = 0.35 + 0.22 * math.cos(t * 2 * math.pi);
        final y2 = 0.72 + 0.12 * math.sin(t * 2 * math.pi);

        return Stack(
          children: [
            Positioned(
              left: MediaQuery.of(context).size.width * x1 - 180,
              top: MediaQuery.of(context).size.height * y1 - 180,
              child: Container(
                width: 360,
                height: 360,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      palette.accent.withValues(alpha: 0.15),
                      palette.accent.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: MediaQuery.of(context).size.width * x2 - 200,
              top: MediaQuery.of(context).size.height * y2 - 200,
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.07),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
              child: const SizedBox.expand(),
            ),
          ],
        );
      },
    );
  }
}

class _StepDots extends StatelessWidget {
  final int count;
  final int current;
  const _StepDots({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (i) {
        final active = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 22 : 6,
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            color: active
                ? AppTheme.ink
                : AppTheme.border2.withValues(alpha: 0.5),
          ),
        );
      }),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final PermTopicInfo info;
  final bool granted;
  final VoidCallback onTap;
  const _PermissionTile({
    required this.info,
    required this.granted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${info.title}. ${granted ? "Allowed" : "Not allowed"}',
      child: Material(
        color: granted
            ? Colors.white.withValues(alpha: 0.06)
            : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: granted ? null : onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: granted
                    ? Colors.white.withValues(alpha: 0.16)
                    : AppTheme.border,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.surface2,
                  ),
                  child: Icon(info.icon, size: 19, color: AppTheme.ink),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title,
                        style: GoogleFonts.interTight(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        granted
                            ? 'Microphone enabled'
                            : 'Tap to grant microphone access',
                        style: GoogleFonts.interTight(
                          fontSize: 12.5,
                          color: granted ? AppTheme.ink2 : AppTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  granted
                      ? Icons.check_circle_rounded
                      : Icons.arrow_forward_ios_rounded,
                  size: granted ? 20 : 14,
                  color: granted ? AppTheme.accent : AppTheme.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
