import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/agent_mode.dart';
import '../../services/device_capability.dart';
import '../../services/model_benchmarks.dart';
import '../../services/model_downloader_service.dart';
import '../../services/model_registry.dart';
import '../../services/permission_flow.dart';
import '../../theme/app_theme.dart';
import '../../widgets/design_components.dart';
import '../api_key_setup_screen.dart';
import '../home_screen.dart';
import '../provider_setup_screen.dart';
import '../splash_screen.dart';

/// Opal-style onboarding: three screens, one decision each.
///
/// Design rules:
/// - Never ask for a permission before the user has seen the feature it
///   unlocks. Onboarding only *offers* the microphone, and it is skippable.
/// - Never claim a model "runs great" without checking RAM and free storage.
/// - Every transition is a cross-fade + small vertical drift, so steps feel
///   like one continuous surface rather than a stack of pages.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { welcome, device, permissions }

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  _Step _step = _Step.welcome;

  DeviceProfile? _profile;
  bool _scanning = true;
  List<ModelFit> _fits = const [];
  ModelSpec? _selected;

  bool _downloading = false;
  double _progress = 0;
  String _speed = '';
  String _downloaded = '';
  String _total = '';
  String? _downloadError;

  bool _micGranted = false;
  bool _finishing = false;

  final ModelDownloaderService _downloader = ModelDownloaderService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a permission dialog or system settings: refresh the
    // toggle so it doesn't show a stale "off".
    if (state == AppLifecycleState.resumed && _step == _Step.permissions) {
      _refreshMic();
    }
  }

  Future<void> _scan() async {
    final profile = await DeviceCapability.scan();
    final measured = await ModelBenchmarks.load();
    if (!mounted) return;
    PermissionFlow.configure(sdkInt: profile.sdkInt);
    final fits = DeviceCapability.rank(profile, measured: measured);
    setState(() {
      _profile = profile;
      _fits = fits;
      _scanning = false;
      _selected = DeviceCapability.recommendedSpec(profile) ??
          (fits.isNotEmpty ? fits.first.spec : null);
    });
  }

  Future<void> _refreshMic() async {
    final granted = await PermissionFlow.isGranted(PermTopic.microphone);
    if (mounted) setState(() => _micGranted = granted);
  }

  ModelFit? get _selectedFit {
    for (final f in _fits) {
      if (f.spec.fileName == _selected?.fileName) return f;
    }
    return _fits.isEmpty ? null : _fits.first;
  }

  // ── Navigation ───────────────────────────────────────────────────────────

  void _goTo(_Step step) {
    if (_step == step) return;
    setState(() => _step = step);
  }

  Future<void> _finishLocal(ModelSpec spec) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingSeenPref, true);
    await prefs.setString(kLastModelPref, spec.fileName);
    await AgentModeStore.write(AgentMode.local);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => SplashScreen(modelFileName: spec.fileName),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
      (_) => false,
    );
  }

  Future<void> _finishCloud() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingSeenPref, true);
    await AgentModeStore.write(AgentMode.cloud);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => const ApiKeySetupScreen(fromOnboarding: true)),
      (_) => false,
    );
  }

  Future<void> _browseAllModels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingSeenPref, true);
    await AgentModeStore.write(AgentMode.local);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  // ── Download ─────────────────────────────────────────────────────────────

  Future<void> _startDownload(ModelSpec spec) async {
    setState(() {
      _downloading = true;
      _downloadError = null;
      _progress = 0;
      _speed = 'Starting…';
    });
    final already = await _downloader.isModelDownloaded(spec.fileName);
    if (already) {
      if (!mounted) return;
      setState(() => _downloading = false);
      _goTo(_Step.permissions);
      return;
    }

    await _downloader.downloadModel(
      url: spec.url,
      fileName: spec.fileName,
      expectedSizeMB: spec.sizeMB,
      onProgress: (p, speed, downloaded, total) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          _speed = speed;
          _downloaded = downloaded;
          _total = total;
        });
      },
      onComplete: () {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _progress = 1;
        });
        _goTo(_Step.permissions);
      },
      onError: (err) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
          _downloadError = err;
        });
      },
    );
  }

  void _cancelDownload() {
    _downloader.cancelDownload();
    setState(() {
      _downloading = false;
      _downloadError = 'Download paused. You can resume from the model screen.';
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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
                      key: ValueKey('${_step.name}-$_downloading'),
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
    final canBack = _step != _Step.welcome && !_downloading;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: canBack
                ? IconButton(
                    onPressed: () => _goTo(
                      _step == _Step.permissions ? _Step.device : _Step.welcome,
                    ),
                    icon: const Icon(Icons.arrow_back_rounded,
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
          SizedBox(
            width: 52,
            child: _step == _Step.device && !_downloading
                ? TextButton(
                    onPressed: _browseAllModels,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 48),
                    ),
                    child: Text(
                      'SKIP',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10,
                        letterSpacing: 1.2,
                        color: AppTheme.muted,
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.welcome:
        return _welcome();
      case _Step.device:
        return _device();
      case _Step.permissions:
        return _permissions();
    }
  }

  // ── Step 1: welcome ──────────────────────────────────────────────────────

  Widget _welcome() {
    return _ScrollableStep(
      center: true,
      children: [
        const SizedBox(height: 44),
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
        const SizedBox(height: 34),
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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'A fast AI that can actually act on your phone — call, message, '
            'open apps, search, set alarms. Cloud-fast, or fully offline if '
            'you prefer.',
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
        const SizedBox(height: 40),
        PrimaryButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ProviderSetupScreen(fromOnboarding: true),
              ),
            );
          },
          label: 'Start with cloud AI',
          icon: Icons.bolt_rounded,
        ).animate(delay: 380.ms).fadeIn(duration: 400.ms).slideY(begin: 0.2),
        const SizedBox(height: 10),
        SecondaryButton(
          onPressed: () => _goTo(_Step.device),
          label: 'Run on this phone instead',
        ).animate(delay: 440.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 12),
        Text(
          'No account. A free demo is included; on-device works fully offline.',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 12,
            color: AppTheme.muted,
          ),
        ).animate(delay: 500.ms).fadeIn(duration: 400.ms),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── Step 2: device check + model ─────────────────────────────────────────

  Widget _device() {
    if (_downloading) return _downloadView();

    final profile = _profile;
    final fit = _selectedFit;

    return _ScrollableStep(
      children: [
        const SizedBox(height: 6),
        Eyebrow(_scanning ? 'CHECKING YOUR PHONE' : 'YOUR PHONE'),
        const SizedBox(height: 12),
        Text(
          _scanning ? 'Finding the best model…' : 'Here\'s what runs well.',
          style: GoogleFonts.interTight(
            fontSize: 27,
            height: 1.12,
            letterSpacing: -0.9,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ),
        const SizedBox(height: 18),
        if (_scanning)
          const _ScanCard()
        else if (profile != null) ...[
          _DeviceCard(profile: profile),
          const SizedBox(height: 16),
          if (fit != null) _RecommendedCard(fit: fit),
          if (fit == null) ...[
            _NoFitCard(profile: profile),
          ],
        ],
        if (!_scanning && _fits.length > 1) ...[
          const SizedBox(height: 22),
          const Eyebrow('OTHER MODELS'),
          const SizedBox(height: 10),
          ..._fits
              .where((f) => f.spec.fileName != _selected?.fileName)
              .take(3)
              .map((f) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _AltModelRow(
                      fit: f,
                      onTap: f.isUsable
                          ? () => setState(() => _selected = f.spec)
                          : null,
                    ),
                  )),
        ],
        if (_downloadError != null) ...[
          const SizedBox(height: 14),
          _ErrorNote(message: _downloadError!),
        ],
        const SizedBox(height: 24),
        if (!_scanning) ...[
          PrimaryButton(
            onPressed: fit == null || !fit.isUsable
                ? null
                : () => _startDownload(fit.spec),
            label: fit == null
                ? 'No compatible model'
                : 'Download ${fit.spec.displayName}',
            icon: Icons.arrow_downward_rounded,
          ),
          const SizedBox(height: 10),
          SecondaryButton(
            onPressed: _browseAllModels,
            label: 'See the full model store',
          ),
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: _finishCloud,
              child: Text(
                'Use Gemini with my own API key instead',
                style: GoogleFonts.interTight(
                  fontSize: 12.5,
                  color: AppTheme.muted,
                  decoration: TextDecoration.underline,
                  decorationColor: AppTheme.muted2,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _downloadView() {
    final spec = _selected;
    return _ScrollableStep(
      children: [
        const SizedBox(height: 20),
        Eyebrow('INSTALLING'),
        const SizedBox(height: 12),
        Text(
          'Downloading\n${spec?.displayName ?? 'model'}',
          style: GoogleFonts.interTight(
            fontSize: 28,
            height: 1.1,
            letterSpacing: -0.9,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Keep the app open. You can pause and resume at any time.',
          style: GoogleFonts.interTight(
            fontSize: 13.5,
            height: 1.5,
            color: AppTheme.ink2,
          ),
        ),
        const SizedBox(height: 36),
        _ProgressRing(progress: _progress),
        const SizedBox(height: 28),
        _DownloadStats(
          progress: _progress,
          speed: _speed,
          downloaded: _downloaded,
          total: _total,
        ),
        const SizedBox(height: 32),
        SecondaryButton(onPressed: _cancelDownload, label: 'Pause download'),
      ],
    );
  }

  // ── Step 3: permissions ──────────────────────────────────────────────────

  Widget _permissions() {
    final info = kPermTopics[PermTopic.microphone]!;
    return _ScrollableStep(
      children: [
        const SizedBox(height: 6),
        const Eyebrow('ONE LAST THING'),
        const SizedBox(height: 12),
        Text(
          'Talk, don\'t type.',
          style: GoogleFonts.interTight(
            fontSize: 28,
            height: 1.12,
            letterSpacing: -0.9,
            fontWeight: FontWeight.w600,
            color: AppTheme.ink,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Voice mode lets you have a hands-free conversation. Everything is '
          'transcribed on your phone.',
          style: GoogleFonts.interTight(
            fontSize: 14,
            height: 1.55,
            color: AppTheme.ink2,
          ),
        ),
        const SizedBox(height: 26),
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
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: AppTheme.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Contacts, calendar and photos are only requested the first '
                  'time you ask the agent to use them. Nothing is uploaded.',
                  style: GoogleFonts.interTight(
                    fontSize: 12,
                    height: 1.5,
                    color: AppTheme.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        PrimaryButton(
          onPressed: _finishing || _selected == null
              ? null
              : () => _finishLocal(_selected!),
          label: _micGranted ? 'Start chatting' : 'Continue without voice',
          isLoading: _finishing,
        ),
        const SizedBox(height: 10),
        if (!_micGranted)
          Center(
            child: TextButton(
              onPressed: () async {
                await PermissionFlow.openSettings();
              },
              child: Text(
                'Already denied? Open settings',
                style: GoogleFonts.interTight(
                    fontSize: 12, color: AppTheme.muted),
              ),
            ),
          ),
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

/// Scrolls on short screens / large text, but stays centered on tall ones.
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
          padding: const EdgeInsets.fromLTRB(26, 8, 26, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0.0, constraints.maxHeight - 32),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment:
                  center ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: children,
            ),
          ),
        );
      },
    );
  }
}

/// Soft, slowly drifting gradient field. Two blur-free radial gradients are
/// cheaper than a full-screen BackdropFilter and read the same at this scale.
class _AuroraBackground extends StatefulWidget {
  final bool animate;
  const _AuroraBackground({required this.animate});

  @override
  State<_AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<_AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _AuroraBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.animate && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value * 2 * math.pi;
          return Stack(
            children: [
              const ColoredBox(color: AppTheme.bg),
              Positioned(
                left: -140 + 40 * math.cos(t),
                top: -160 + 60 * math.sin(t),
                child: _glow(const Color(0xFF2B2B38), 520),
              ),
              Positioned(
                right: -180 + 50 * math.cos(t + 1.6),
                bottom: -120 + 40 * math.sin(t + 1.6),
                child: _glow(const Color(0xFF1A2226), 560),
              ),
              Positioned(
                left: 40 + 30 * math.sin(t * 0.7),
                bottom: 120 + 40 * math.cos(t * 0.7),
                child: _glow(const Color(0xFF241E1A), 380),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _glow(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)],
          ),
        ),
      ),
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
        final active = i <= current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: i == current ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? AppTheme.ink : AppTheme.border2,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(height: 16),
          _shimmer(width: 140),
          const SizedBox(height: 10),
          _shimmer(width: 220),
          const SizedBox(height: 10),
          _shimmer(width: 180),
        ],
      ),
    );
  }

  Widget _shimmer({required double width}) => Container(
        width: width,
        height: 10,
        decoration: BoxDecoration(
          color: AppTheme.surface3,
          borderRadius: BorderRadius.circular(4),
        ),
      ).animate(onPlay: (c) => c.repeat(reverse: true)).fadeIn(
          duration: 900.ms, begin: 0.35);
}

class _DeviceCard extends StatelessWidget {
  final DeviceProfile profile;
  const _DeviceCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final ram = profile.ramGB;
    final free = profile.freeStorageGB;
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smartphone_rounded,
                  size: 18, color: AppTheme.ink2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  profile.deviceLabel,
                  style: GoogleFonts.interTight(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Pill('CHECKED', style: PillStyle.success),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ModelChip(
                icon: Icons.memory_rounded,
                label: ram == null ? 'RAM unknown' : '$ram GB RAM',
              ),
              ModelChip(
                icon: Icons.storage_rounded,
                label: free == null
                    ? 'Storage unknown'
                    : '${free.toStringAsFixed(free >= 10 ? 0 : 1)} GB free',
              ),
              ModelChip(
                icon: Icons.developer_board_rounded,
                label: '${profile.cpuCores} cores',
              ),
              if (profile.sdkInt > 0)
                ModelChip(
                  icon: Icons.android_rounded,
                  label: 'Android ${_androidName(profile.sdkInt)}',
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _androidName(int sdk) {
    switch (sdk) {
      case >= 36:
        return '16';
      case 35:
        return '15';
      case 34:
        return '14';
      case 33:
        return '13';
      case 32:
      case 31:
        return '12';
      case 30:
        return '11';
      case 29:
        return '10';
      case 28:
        return '9';
      default:
        return '$sdk';
    }
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    // Blur is bounded to this card, so it costs one small offscreen pass
    // instead of re-blurring the whole screen every frame.
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _RecommendedCard extends StatelessWidget {
  final ModelFit fit;
  const _RecommendedCard({required this.fit});

  @override
  Widget build(BuildContext context) {
    final spec = fit.spec;
    final minutes = _estimateMinutes(spec.sizeMB);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.displayName,
                  style: GoogleFonts.interTight(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Pill(fit.verdictLabel,
                  style: fit.isRecommended
                      ? PillStyle.solid
                      : PillStyle.surface),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            spec.tagline,
            style: GoogleFonts.interTight(
              fontSize: 12.5,
              height: 1.45,
              color: AppTheme.ink2,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _Metric(
                value: fit.speedLabel,
                label: fit.speedSourceLabel,
                icon: Icons.speed_rounded,
              ),
              _divider(),
              _Metric(
                value: spec.sizeLabel,
                label: 'download',
                icon: Icons.cloud_download_outlined,
              ),
              _divider(),
              _Metric(
                value: minutes == null ? '—' : '~$minutes min',
                label: 'on Wi-Fi',
                icon: Icons.timer_outlined,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            fit.verdictDetail,
            style: GoogleFonts.interTight(
              fontSize: 11.5,
              height: 1.45,
              color: AppTheme.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: Colors.white.withValues(alpha: 0.08),
      );

  int? _estimateMinutes(int sizeMB) {
    // 20 Mbps effective throughput is a realistic median for a phone on Wi-Fi.
    final seconds = sizeMB * 8 / 20;
    final minutes = (seconds / 60).ceil();
    return minutes.clamp(1, 90);
  }
}

class _Metric extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  const _Metric(
      {required this.value, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: AppTheme.muted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: GoogleFonts.interTight(
              fontSize: 10,
              color: AppTheme.muted2,
            ),
          ),
        ],
      ),
    );
  }
}

class _AltModelRow extends StatelessWidget {
  final ModelFit fit;
  final VoidCallback? onTap;
  const _AltModelRow({required this.fit, this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 16, color: AppTheme.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    fit.spec.displayName,
                    style: GoogleFonts.interTight(
                      fontSize: 13.5,
                      color: AppTheme.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  fit.speedLabel,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10.5,
                    color: AppTheme.muted,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  fit.spec.sizeLabel,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10.5,
                    color: AppTheme.muted2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoFitCard extends StatelessWidget {
  final DeviceProfile profile;
  const _NoFitCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: AppTheme.error),
              const SizedBox(width: 10),
              Text(
                'Not enough room for a local model',
                style: GoogleFonts.interTight(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Both models need more free storage or RAM than this phone '
            'reports. You can free up space and come back, or use Gemini '
            'with your own API key.',
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

class _ProgressRing extends StatelessWidget {
  final double progress;
  const _ProgressRing({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 156,
        height: 156,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 156,
              height: 156,
              child: CircularProgressIndicator(
                value: progress <= 0 ? null : progress,
                strokeWidth: 3,
                backgroundColor: AppTheme.surface3,
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.ink),
              ),
            ),
            Text(
              '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: AppTheme.ink,
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadStats extends StatelessWidget {
  final double progress;
  final String speed;
  final String downloaded;
  final String total;
  const _DownloadStats({
    required this.progress,
    required this.speed,
    required this.downloaded,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          speed.isEmpty ? '—' : speed,
          style: GoogleFonts.jetBrainsMono(
              fontSize: 11, color: AppTheme.ink2),
        ),
        Text(
          downloaded.isEmpty ? '' : '$downloaded / $total',
          style: GoogleFonts.jetBrainsMono(
              fontSize: 11, color: AppTheme.muted),
        ),
      ],
    );
  }
}

class _ErrorNote extends StatelessWidget {
  final String message;
  const _ErrorNote({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 16, color: AppTheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.interTight(
                fontSize: 12,
                height: 1.45,
                color: AppTheme.ink,
              ),
            ),
          ),
        ],
      ),
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
                      const SizedBox(height: 3),
                      Text(
                        granted ? 'Allowed — tap to manage in Settings' : info.reason,
                        style: GoogleFonts.interTight(
                          fontSize: 11.5,
                          height: 1.45,
                          color: AppTheme.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (granted)
                  const Icon(Icons.check_circle_rounded,
                      size: 20, color: AppTheme.success)
                else
                  const Icon(Icons.chevron_right_rounded,
                      size: 20, color: AppTheme.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
