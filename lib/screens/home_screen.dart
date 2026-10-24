import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/device_capability.dart';
import '../services/model_benchmarks.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'provider_setup_screen.dart';
import 'splash_screen.dart';

/// Model store: what this phone can actually run, how fast, and how big.
///
/// Every card is driven by [DeviceCapability], so the "recommended" badge is a
/// real RAM/storage/speed decision rather than a constant.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ModelDownloaderService _downloader = ModelDownloaderService();

  DeviceProfile? _profile;
  List<ModelFit> _fits = const [];
  bool _loading = true;

  final Map<String, bool> _isDownloaded = {};
  final Map<String, int> _partialBytes = {};
  final Map<String, String> _errors = {};

  String? _downloadingFileName;
  double _downloadProgress = 0.0;
  String _downloadSpeed = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = DeviceCapability.cached ?? await DeviceCapability.scan();
    final measured = await ModelBenchmarks.load();
    final fits = DeviceCapability.rank(profile, measured: measured);
    final installed = <String, bool>{};
    final partials = <String, int>{};
    for (final spec in ModelRegistry.all) {
      installed[spec.fileName] =
          await _downloader.isModelDownloaded(spec.fileName);
      if (!installed[spec.fileName]!) {
        partials[spec.fileName] =
            await _downloader.partialBytes(spec.fileName);
      }
    }
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _fits = fits;
      _isDownloaded
        ..clear()
        ..addAll(installed);
      _partialBytes
        ..clear()
        ..addAll(partials);
      _loading = false;
    });
  }

  Future<void> _refreshInstalled() async {
    final installed = <String, bool>{};
    final partials = <String, int>{};
    for (final spec in ModelRegistry.all) {
      installed[spec.fileName] =
          await _downloader.isModelDownloaded(spec.fileName);
      if (!installed[spec.fileName]!) {
        partials[spec.fileName] =
            await _downloader.partialBytes(spec.fileName);
      }
    }
    if (!mounted) return;
    setState(() {
      _isDownloaded
        ..clear()
        ..addAll(installed);
      _partialBytes
        ..clear()
        ..addAll(partials);
    });
  }

  Future<void> _startDownload(ModelFit fit) async {
    final spec = fit.spec;
    setState(() {
      _downloadingFileName = spec.fileName;
      _downloadProgress = 0.0;
      _downloadSpeed = 'Starting…';
      _errors.remove(spec.fileName);
    });

    await _downloader.downloadModel(
      url: spec.url,
      fileName: spec.fileName,
      expectedSizeMB: spec.sizeMB,
      onProgress: (p, speed, downloaded, total) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = p;
          _downloadSpeed = '$speed · $downloaded / $total';
        });
      },
      onComplete: () async {
        if (!mounted) return;
        setState(() {
          _downloadingFileName = null;
          _errors.remove(spec.fileName);
        });
        await _refreshInstalled();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${spec.displayName} is ready.')),
        );
      },
      onError: (err) async {
        if (!mounted) return;
        setState(() {
          _downloadingFileName = null;
          _errors[spec.fileName] = err;
        });
        await _refreshInstalled();
      },
    );
  }

  void _cancelDownload() {
    _downloader.cancelDownload();
    setState(() => _downloadingFileName = null);
    _refreshInstalled();
  }

  Future<void> _startChat(ModelSpec spec) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SplashScreen(modelFileName: spec.fileName)),
    );
  }

  Future<void> _deleteModel(ModelSpec spec) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Delete ${spec.displayName}?',
          style: GoogleFonts.interTight(
              color: AppTheme.ink, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          'This frees ${spec.sizeLabel}. You can download it again later.',
          style: GoogleFonts.interTight(color: AppTheme.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep',
                style: GoogleFonts.interTight(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: GoogleFonts.interTight(
                    color: AppTheme.error, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _downloader.deleteModel(spec.fileName);
    await _refreshInstalled();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              // Always give a way out. When this screen is reached with
              // `pushAndRemoveUntil` (onboarding → "run on this phone"), there
              // is nothing to pop, which used to leave the user stuck with only
              // a refresh button.
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () {
                  final nav = Navigator.of(context);
                  if (nav.canPop()) {
                    nav.pop();
                  } else {
                    nav.pushReplacement(
                      MaterialPageRoute(
                        builder: (_) =>
                            const ProviderSetupScreen(fromOnboarding: true),
                      ),
                    );
                  }
                },
              ),
              title: Text(
                'Models',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
              trailing: HeaderIconButton(
                icon: Icons.refresh_rounded,
                size: 18,
                onPressed: _downloadingFileName == null
                    ? () async {
                        setState(() => _loading = true);
                        await _load();
                      }
                    : null,
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
                  : SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Model store',
                            style: GoogleFonts.interTight(
                              fontSize: 27,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.8,
                              color: AppTheme.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Models run entirely on this phone. '
                            'Sizes are downloads; each needs roughly that much '
                            'free storage.',
                            style: GoogleFonts.interTight(
                              fontSize: 13,
                              height: 1.5,
                              color: AppTheme.ink2,
                            ),
                          ),
                          if (_profile != null) ...[
                            const SizedBox(height: 14),
                            _PhoneStrip(profile: _profile!),
                          ],
                          const SizedBox(height: 22),
                          ..._fits.map((fit) => Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: _ModelCard(
                                  fit: fit,
                                  downloaded:
                                      _isDownloaded[fit.spec.fileName] ?? false,
                                  partialBytes:
                                      _partialBytes[fit.spec.fileName] ?? 0,
                                  downloading: _downloadingFileName ==
                                      fit.spec.fileName,
                                  blockedByOther:
                                      _downloadingFileName != null &&
                                          _downloadingFileName !=
                                              fit.spec.fileName,
                                  progress: _downloadProgress,
                                  speed: _downloadSpeed,
                                  error: _errors[fit.spec.fileName],
                                  onDownload: () => _startDownload(fit),
                                  onCancel: _cancelDownload,
                                  onChat: () => _startChat(fit.spec),
                                  onDelete: () => _deleteModel(fit.spec),
                                ),
                              )),
                          const SizedBox(height: 4),
                          Text(
                            'Estimates are based on this phone\'s CPU cores, '
                            'RAM and free storage — actual speed varies with '
                            'thermal state and background apps.',
                            style: GoogleFonts.interTight(
                              fontSize: 11,
                              height: 1.5,
                              color: AppTheme.muted2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ProviderSetupScreen(),
                                ),
                              ),
                              child: Text(
                                'No download? Use Agent in the cloud instead',
                                textAlign: TextAlign.center,
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
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneStrip extends StatelessWidget {
  final DeviceProfile profile;
  const _PhoneStrip({required this.profile});

  @override
  Widget build(BuildContext context) {
    final free = profile.freeStorageGB;
    final parts = <String>[
      if (profile.ramGB != null) '${profile.ramGB} GB RAM',
      '${profile.cpuCores} cores',
      if (free != null) '${free.toStringAsFixed(free >= 10 ? 0 : 1)} GB free',
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in parts)
          ModelChip(icon: Icons.memory_rounded, label: p),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  final ModelFit fit;
  final bool downloaded;
  final int partialBytes;
  final bool downloading;
  final bool blockedByOther;
  final double progress;
  final String speed;
  final String? error;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onChat;
  final VoidCallback onDelete;

  const _ModelCard({
    required this.fit,
    required this.downloaded,
    required this.partialBytes,
    required this.downloading,
    required this.blockedByOther,
    required this.progress,
    required this.speed,
    required this.error,
    required this.onDownload,
    required this.onCancel,
    required this.onChat,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final spec = fit.spec;
    final usable = fit.isUsable;
    final hasPartial = partialBytes > 1024 * 1024;

    return Opacity(
      opacity: usable ? 1 : 0.62,
      child: DesignCard(
        selected: fit.isRecommended,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    spec.displayName,
                    style: GoogleFonts.interTight(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: AppTheme.ink,
                    ),
                  ),
                ),
                if (downloaded)
                  const Pill('INSTALLED', style: PillStyle.success)
                else if (fit.isRecommended)
                  const Pill('BEST FIT', style: PillStyle.solid)
                else
                  Pill(fit.verdictLabel),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              spec.tagline,
              style: GoogleFonts.interTight(
                fontSize: 12.5,
                height: 1.45,
                color: AppTheme.ink2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ModelChip(
                    icon: Icons.storage_rounded,
                    label: '${spec.sizeLabel} file'),
                ModelChip(
                  icon: Icons.speed_rounded,
                  label: usable
                      ? '${fit.speedLabel} ${fit.isMeasured ? "measured" : "est."}'
                      : 'too slow',
                ),
                ModelChip(
                  icon: Icons.sd_storage_outlined,
                  label:
                      '${(fit.requiredStorageMB / 1024).toStringAsFixed(1)} GB needed',
                ),
                ModelChip(
                  icon: spec.supportsTools
                      ? Icons.build_outlined
                      : Icons.chat_bubble_outline_rounded,
                  label: spec.supportsTools ? 'Tool calls' : 'Chat only',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              usable
                  ? fit.verdictDetail
                  : 'Needs ${(fit.requiredStorageMB / 1024).toStringAsFixed(1)} GB '
                      'free and at least ${spec.minRamGB} GB RAM. Free up space '
                      'or pick a smaller model.',
              style: GoogleFonts.interTight(
                fontSize: 11.5,
                height: 1.45,
                color: usable ? AppTheme.muted : AppTheme.error,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  error!,
                  style: GoogleFonts.interTight(
                      fontSize: 11.5, height: 1.4, color: AppTheme.ink),
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 6,
                  backgroundColor: AppTheme.surface3,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(AppTheme.ink),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      speed,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.jetBrainsMono(
                          fontSize: 10.5, color: AppTheme.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: onCancel,
                    child: Text('Pause',
                        style: GoogleFonts.interTight(
                            fontSize: 12,
                            color: AppTheme.ink,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ] else if (downloaded)
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      onPressed: onChat,
                      label: 'New chat',
                      leading: const SparkleIcon(size: 14),
                      background: AppTheme.ink,
                      foreground: AppTheme.bg,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    height: 48,
                    child: IconButton(
                      tooltip: 'Delete model',
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline_rounded,
                          size: 18, color: AppTheme.muted),
                    ),
                  ),
                ],
              )
            else
              PrimaryButton(
                onPressed: usable && !blockedByOther ? onDownload : null,
                label: !usable
                    ? 'Not compatible'
                    : (hasPartial ? 'Resume download' : 'Download'),
                icon: usable ? Icons.arrow_downward_rounded : null,
                background: AppTheme.surface3,
                foreground: AppTheme.ink,
              ),
          ],
        ),
      ),
    );
  }
}
