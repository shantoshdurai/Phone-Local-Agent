import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/launch.dart';
import '../services/agent/agent_service.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'settings_screen.dart';

/// Download, choose and delete on-device models.
class ModelPickerScreen extends StatefulWidget {
  const ModelPickerScreen({super.key});

  @override
  State<ModelPickerScreen> createState() => _ModelPickerScreenState();
}

class _ModelPickerScreenState extends State<ModelPickerScreen> {
  final ModelDownloaderService _downloader = ModelDownloaderService();
  final DeviceService _device = DeviceService();

  final Map<String, bool> _downloaded = {};
  final Map<String, bool> _partial = {};
  int? _ramGB;
  double? _freeGB;
  bool _arm64 = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final stats = await _device.getQuickStats();
    final downloaded = <String, bool>{};
    final partial = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      downloaded[spec.fileName] = await _downloader.isModelDownloaded(spec.fileName);
      partial[spec.fileName] = await _downloader.hasPartialDownload(spec.fileName);
    }
    if (!mounted) return;
    setState(() {
      _ramGB = stats['ramGB'] as int?;
      final freeMB = stats['storageFreeMB'] as double?;
      _freeGB = freeMB == null ? null : freeMB / 1024;
      _arm64 = stats['arm64'] as bool? ?? true;
      _downloaded
        ..clear()
        ..addAll(downloaded);
      _partial
        ..clear()
        ..addAll(partial);
      _loading = false;
    });
  }

  Future<void> _download(ModelSpec spec) async {
    try {
      await _downloader.download(spec);
      if (!mounted) return;
      _snack('${spec.displayName} is ready.');
    } catch (e) {
      if (mounted) _snack('$e');
    }
    _refresh();
  }

  Future<void> _delete(ModelSpec spec) async {
    final current = AgentService().target;
    final inUse = current is LocalTarget && current.spec.fileName == spec.fileName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Delete ${spec.displayName}?',
            style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
        content: Text(
          'Frees ${spec.sizeLabel}. You can download it again later.'
          '${inUse ? '\n\nIt\'s the model you\'re using now; you\'ll pick another one next.' : ''}',
          style: GoogleFonts.interTight(color: AppTheme.ink2, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.interTight(color: AppTheme.muted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete',
                  style: GoogleFonts.interTight(color: AppTheme.error, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    await _downloader.deleteModel(spec.fileName);
    await _refresh();
    if (inUse && mounted) resetTo(context, const ModelPickerScreen());
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final recommended = ModelRegistry.recommendedFor(ramGB: _ramGB, arm64: _arm64);
    final legacy = ModelRegistry.all.where((s) => s.legacy && (_downloaded[s.fileName] ?? false)).toList();
    final canPop = Navigator.canPop(context);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: canPop
                  ? HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.pop(context))
                  : null,
              title: Text('On-device models',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
              trailing: HeaderIconButton(
                icon: Icons.settings_outlined,
                size: 19,
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: AppTheme.muted))
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                        children: [
                          Text(
                            'Run AI privately on your phone. Pick a model that suits your phone — '
                            'bigger models are smarter but slower.',
                            style: GoogleFonts.interTight(fontSize: 14, height: 1.55, color: AppTheme.ink2),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (_ramGB != null) ModelChip(icon: Icons.memory_rounded, label: '$_ramGB GB RAM'),
                              if (_freeGB != null)
                                ModelChip(
                                    icon: Icons.sd_storage_outlined,
                                    label: '${_freeGB!.toStringAsFixed(1)} GB free'),
                            ],
                          ),
                          const SizedBox(height: 20),
                          for (final spec in ModelRegistry.downloadable)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: _card(spec, recommended: spec.id == recommended.id),
                            ),
                          if (legacy.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.only(top: 8, bottom: 10),
                              child: Eyebrow('OLDER DOWNLOADS'),
                            ),
                            for (final spec in legacy)
                              Padding(padding: const EdgeInsets.only(bottom: 14), child: _card(spec)),
                          ],
                          const SizedBox(height: 8),
                          _cloudCta(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cloudCta() {
    return DesignCard(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiKeySetupScreen())),
      child: Row(
        children: [
          const Icon(Icons.cloud_outlined, color: AppTheme.ink, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Phone too slow? Use an API key',
                    style: GoogleFonts.interTight(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                const SizedBox(height: 4),
                Text('Gemini (free tier), Claude, OpenAI, Groq, OpenRouter or your own server.',
                    style: GoogleFonts.interTight(fontSize: 12.5, height: 1.4, color: AppTheme.ink2)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
  }

  Widget _card(ModelSpec spec, {bool recommended = false}) {
    final downloaded = _downloaded[spec.fileName] ?? false;
    final partial = _partial[spec.fileName] ?? false;
    final unsupported = spec.arm64Only && !_arm64;
    final lowRam = _ramGB != null && _ramGB! < spec.minRamGB;
    final current = AgentService().target;
    final inUse = current is LocalTarget && current.spec.fileName == spec.fileName;

    return DesignCard(
      selected: recommended,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(spec.tier, style: PillStyle.outline),
              const Spacer(),
              if (recommended) const Pill('RECOMMENDED', style: PillStyle.solid),
              if (inUse) ...[const SizedBox(width: 6), const Pill('IN USE', style: PillStyle.success)],
            ],
          ),
          const SizedBox(height: 12),
          Text(spec.displayName,
              style: GoogleFonts.interTight(
                  fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
          const SizedBox(height: 6),
          Text(spec.tagline, style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2, height: 1.4)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ModelChip(icon: Icons.download_rounded, label: spec.sizeLabel),
              ModelChip(icon: Icons.memory_rounded, label: '${spec.minRamGB}+ GB RAM'),
              if (spec.supportsVision) const ModelChip(icon: Icons.image_outlined, label: 'Images'),
              ModelChip(icon: Icons.build_outlined, label: '${spec.toolBudget >= 20 ? 'All' : spec.toolBudget} tools'),
            ],
          ),
          if (unsupported || lowRam) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, size: 15, color: AppTheme.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    unsupported
                        ? 'Not supported on this phone\'s processor (needs 64-bit ARM).'
                        : 'Your phone has $_ramGB GB RAM; this model may be slow or fail to load.',
                    style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.muted, height: 1.4),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          ValueListenableBuilder<DownloadProgress?>(
            valueListenable: _downloader.progress,
            builder: (context, progress, _) {
              if (progress != null && progress.fileName == spec.fileName) {
                return _progressView(progress);
              }
              final otherDownloading = progress != null;
              if (downloaded) {
                return Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        onPressed: unsupported ? null : () => launchAgent(context, LocalTarget(spec)),
                        label: inUse ? 'Continue chatting' : 'Use this model',
                        leading: const SparkleIcon(size: 14),
                        background: AppTheme.ink,
                        foreground: AppTheme.bg,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Tooltip(
                      message: 'Delete',
                      child: IconButton(
                        onPressed: () => _delete(spec),
                        icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.ink2),
                      ),
                    ),
                  ],
                );
              }
              if (spec.legacy) return const SizedBox.shrink();
              return PrimaryButton(
                onPressed: (otherDownloading || unsupported) ? null : () => _download(spec),
                label: partial ? 'Resume download' : 'Download · ${spec.sizeLabel}',
                icon: Icons.download_rounded,
                background: AppTheme.surface3,
                foreground: AppTheme.ink,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _progressView(DownloadProgress p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: p.fraction,
            minHeight: 6,
            backgroundColor: AppTheme.surface3,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.ink),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${(p.fraction * 100).toStringAsFixed(0)}% · ${p.speedLabel}',
                style: GoogleFonts.jetBrainsMono(fontSize: 10.5, color: AppTheme.muted)),
            Text(p.amountLabel, style: GoogleFonts.jetBrainsMono(fontSize: 10.5, color: AppTheme.muted)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text('Keep the app open until it finishes.',
                  style: GoogleFonts.interTight(fontSize: 11.5, color: AppTheme.muted)),
            ),
            TextButton(
              onPressed: _downloader.cancelDownload,
              child: Text('Pause',
                  style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ],
    );
  }
}
