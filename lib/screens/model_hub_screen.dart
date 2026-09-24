import 'dart:async';
import 'dart:io';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/launch.dart';
import '../services/agent/agent_service.dart';
import '../services/local/device_profile.dart';
import '../services/local/hf_hub.dart';
import '../services/local/local_model.dart';
import '../services/local/model_catalog.dart';
import '../services/model_downloader_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'model_settings_screen.dart';
import 'settings_screen.dart';

/// Browse, download and manage on-device models: curated picks for this
/// phone, the whole Hugging Face GGUF catalog, and what's downloaded.
class ModelHubScreen extends StatefulWidget {
  final int initialTab;
  const ModelHubScreen({super.key, this.initialTab = 0});

  @override
  State<ModelHubScreen> createState() => _ModelHubScreenState();
}

class _ModelHubScreenState extends State<ModelHubScreen> with SingleTickerProviderStateMixin {
  final _downloader = ModelDownloaderService();
  late final TabController _tabs =
      TabController(length: 3, vsync: this, initialIndex: widget.initialTab);

  DeviceProfile? _device;
  double? _freeGB;
  List<LocalModel> _downloaded = [];
  final Set<String> _partial = {};
  final Set<String> _visionReady = {};
  List<File> _legacy = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final device = await DeviceProfile.load(refresh: true);
    double? free;
    try {
      final mb = await DiskSpace.getFreeDiskSpace;
      if (mb != null) free = mb / 1024;
    } catch (_) {}
    final downloaded = await ModelCatalog.downloaded();
    final partial = <String>{};
    final vision = <String>{};
    for (final m in await ModelCatalog.all()) {
      if (await _downloader.hasPartialDownload(m.localFileName)) partial.add(m.id);
      if (await _downloader.isVisionDownloaded(m)) vision.add(m.id);
    }
    final legacy = await ModelCatalog.legacyFiles();
    if (!mounted) return;
    setState(() {
      _device = device;
      _freeGB = free;
      _downloaded = downloaded;
      _partial
        ..clear()
        ..addAll(partial);
      _visionReady
        ..clear()
        ..addAll(vision);
      _legacy = legacy;
      _loading = false;
    });
  }

  bool _isDownloaded(LocalModel m) => _downloaded.any((d) => d.id == m.id);

  bool _inUse(LocalModel m) {
    final t = AgentService().target;
    return t is LocalTarget && t.model.id == m.id;
  }

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), action: action, behavior: SnackBarBehavior.floating));
  }

  Future<void> _download(LocalModel model, {bool withVision = true}) async {
    if (!model.curated) await ModelCatalog.addHubModel(model);
    try {
      await _downloader.download(model, withVision: withVision);
      await _refresh();
      _snack(
        '${model.name} is ready.',
        action: SnackBarAction(label: 'USE', onPressed: () => _use(model)),
      );
    } catch (e) {
      await _refresh();
      _snack('$e');
    }
  }

  void _use(LocalModel model) {
    if (!mounted) return;
    launchAgent(context, LocalTarget(model));
  }

  Future<void> _delete(LocalModel model, {bool visionOnly = false}) async {
    final what = visionOnly ? 'image support for ${model.name}' : model.name;
    final ok = await _confirm(
      'Delete $what?',
      visionOnly
          ? 'Frees ${formatBytes(model.mmprojSizeBytes ?? 0)}. The model keeps working for text.'
          : 'Frees ${formatBytes(await _downloader.bytesOnDisk(model))}. You can download it again later.',
      'Delete',
    );
    if (ok != true) return;
    if (_inUse(model)) await AgentService().unloadLocal();
    await _downloader.deleteModel(model, visionOnly: visionOnly);
    if (!visionOnly && !model.curated) await ModelCatalog.removeHubModel(model.id);
    await _refresh();
  }

  Future<bool?> _confirm(String title, String body, String action) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text(title, style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
          content: Text(body, style: GoogleFonts.interTight(color: AppTheme.ink2, height: 1.45)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Cancel', style: GoogleFonts.interTight(color: AppTheme.muted))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action,
                    style: GoogleFonts.interTight(color: AppTheme.error, fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Future<void> _deleteLegacy() async {
    var total = 0;
    for (final f in _legacy) {
      try {
        total += await f.length();
      } catch (_) {}
    }
    final ok = await _confirm(
      'Delete old model files?',
      'These ${_legacy.length} files (${formatBytes(total)}) came from an earlier version of the app '
          'and can\'t be used any more.',
      'Delete',
    );
    if (ok != true) return;
    for (final f in _legacy) {
      try {
        await f.delete();
      } catch (_) {}
    }
    await _refresh();
  }

  Future<void> _benchmark(LocalModel model) async {
    _snack('Measuring speed with ${model.name}…');
    try {
      final stats = await AgentService().benchmark();
      await _refresh();
      final tps = stats.tokensPerSecond;
      final prompt = stats.promptTokensPerSecond;
      _snack(tps == null
          ? 'Couldn\'t measure the speed.'
          : '${model.name}: ${tps.toStringAsFixed(1)} tokens/s'
              '${prompt == null ? '' : ' · reads ${prompt.toStringAsFixed(0)} tokens/s'}');
    } catch (e) {
      _snack(AgentService.friendlyError(e));
    }
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
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
              title: Text('Models',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
              trailing: HeaderIconButton(
                icon: Icons.settings_outlined,
                size: 19,
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ),
            _downloadBanner(),
            TabBar(
              controller: _tabs,
              labelColor: AppTheme.ink,
              unselectedLabelColor: AppTheme.muted,
              indicatorColor: AppTheme.primary,
              dividerColor: AppTheme.border,
              labelStyle: GoogleFonts.interTight(fontSize: 13.5, fontWeight: FontWeight.w600),
              tabs: [
                const Tab(text: 'For you'),
                const Tab(text: 'Explore'),
                Tab(text: _downloaded.isEmpty ? 'Downloaded' : 'Downloaded · ${_downloaded.length}'),
              ],
            ),
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: AppTheme.muted))
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _forYouTab(),
                        _ExploreTab(device: _device!, onDownload: _download, isDownloaded: _isDownloaded),
                        _downloadedTab(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadBanner() {
    return ValueListenableBuilder<DownloadProgress?>(
      valueListenable: _downloader.progress,
      builder: (context, p, _) {
        if (p == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.download_rounded, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Downloading ${p.label}',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.interTight(
                            fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                  ),
                  TextButton(
                    onPressed: _downloader.cancelDownload,
                    child: Text('Pause',
                        style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: p.fraction,
                    minHeight: 5,
                    backgroundColor: AppTheme.surface3,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(p.fraction * 100).toStringAsFixed(0)}% · ${p.amountLabel} · ${p.speedLabel}'
                '${p.etaLabel == null ? '' : ' · ${p.etaLabel}'}',
                style: GoogleFonts.jetBrainsMono(fontSize: 10.5, color: AppTheme.muted),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _deviceCard() {
    final d = _device!;
    final measured = d.speedIsMeasured;
    return DesignCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smartphone_rounded, size: 18, color: AppTheme.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(d.socName ?? 'This phone',
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.interTight(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.ink)),
              ),
              Pill(d.archLabel, style: PillStyle.outline),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ModelChip(
                icon: Icons.memory_rounded,
                label: '${d.marketedRamGB} GB RAM · ~${d.usableForAiGB.toStringAsFixed(1)} GB for AI',
              ),
              ModelChip(icon: Icons.developer_board_rounded, label: d.cpuLabel),
              if (d.gpuName != null) ModelChip(icon: Icons.blur_on_rounded, label: d.gpuName!),
              if (_freeGB != null)
                ModelChip(icon: Icons.sd_storage_outlined, label: '${_freeGB!.toStringAsFixed(1)} GB free'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            measured
                ? 'Speeds below are based on what this phone actually measured.'
                : 'Speeds below are estimates for this kind of phone. Run a speed test from Downloaded '
                    'for real numbers.',
            style: GoogleFonts.interTight(fontSize: 11.5, height: 1.4, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  Widget _forYouTab() {
    final d = _device!;
    final recommended = ModelCatalog.recommendedFor(d);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          _deviceCard(),
          const SizedBox(height: 16),
          if (!d.arm64 && !d.x86)
            _notice('On-device models need a 64-bit phone. You can still use a cloud model.')
          else if (recommended == null)
            _notice('This phone doesn\'t have enough free memory for an on-device model. '
                'A cloud model will work much better.'),
          for (final m in ModelCatalog.curated)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _ModelCard(
                model: m,
                device: d,
                recommended: m.id == recommended?.id,
                downloaded: _isDownloaded(m),
                partial: _partial.contains(m.id),
                visionReady: _visionReady.contains(m.id),
                inUse: _inUse(m),
                onDownload: (withVision) => _download(m, withVision: withVision),
                onUse: () => _use(m),
                onDelete: () => _delete(m),
              ),
            ),
          _cloudCta(),
        ],
      ),
    );
  }

  Widget _downloadedTab() {
    final d = _device!;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          if (_downloaded.isEmpty)
            _notice('Nothing downloaded yet. Pick a model in For you, or search Hugging Face in Explore.'),
          for (final m in _downloaded)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _ModelCard(
                model: m,
                device: d,
                downloaded: true,
                visionReady: _visionReady.contains(m.id),
                partial: false,
                inUse: _inUse(m),
                onDownload: (withVision) => _download(m, withVision: withVision),
                onUse: () => _use(m),
                onDelete: () => _delete(m),
                onDeleteVision: _visionReady.contains(m.id) ? () => _delete(m, visionOnly: true) : null,
                onSettings: _inUse(m)
                    ? () async {
                        await Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const ModelSettingsScreen()));
                        _refresh();
                      }
                    : null,
                onBenchmark: _inUse(m) ? () => _benchmark(m) : null,
              ),
            ),
          if (_legacy.isNotEmpty)
            DesignCard(
              onTap: _deleteLegacy,
              child: Row(
                children: [
                  Icon(Icons.cleaning_services_outlined, color: AppTheme.ink, size: 20),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Delete ${_legacy.length} old model file${_legacy.length == 1 ? '' : 's'} from the previous '
                      'version of the app',
                      style: GoogleFonts.interTight(fontSize: 13.5, color: AppTheme.ink, height: 1.4),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(String text) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: AppTheme.ink2),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: GoogleFonts.interTight(fontSize: 13, height: 1.45, color: AppTheme.ink2)),
            ),
          ],
        ),
      );

  Widget _cloudCta() {
    return DesignCard(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiKeySetupScreen())),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, color: AppTheme.ink, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Phone too slow? Use a cloud model',
                    style: GoogleFonts.interTight(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                const SizedBox(height: 4),
                Text('Gemini (free tier), Claude, OpenAI, Groq, OpenRouter or your own server.',
                    style: GoogleFonts.interTight(fontSize: 12.5, height: 1.4, color: AppTheme.ink2)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
  }
}

String _fitLabel(ModelFit fit) => switch (fit) {
      ModelFit.good => 'Runs well',
      ModelFit.tight => 'Tight fit',
      ModelFit.tooBig => 'Too big',
    };

Color _fitColor(ModelFit fit) => switch (fit) {
      ModelFit.good => AppTheme.successInk,
      ModelFit.tight => const Color(0xFFE0A030),
      ModelFit.tooBig => AppTheme.error,
    };

String _speedLabel(double tps) => tps >= 10 ? '~${tps.round()} tok/s' : '~${tps.toStringAsFixed(1)} tok/s';

class _ModelCard extends StatefulWidget {
  final LocalModel model;
  final DeviceProfile device;
  final bool recommended;
  final bool downloaded;
  final bool partial;
  final bool visionReady;
  final bool inUse;
  final void Function(bool withVision) onDownload;
  final VoidCallback onUse;
  final VoidCallback onDelete;
  final VoidCallback? onDeleteVision;
  final VoidCallback? onSettings;
  final VoidCallback? onBenchmark;

  const _ModelCard({
    required this.model,
    required this.device,
    this.recommended = false,
    required this.downloaded,
    required this.partial,
    required this.visionReady,
    required this.inUse,
    required this.onDownload,
    required this.onUse,
    required this.onDelete,
    this.onDeleteVision,
    this.onSettings,
    this.onBenchmark,
  });

  @override
  State<_ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends State<_ModelCard> {
  late bool _withVision = widget.model.supportsVision;

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final d = widget.device;
    final fit = d.fitOf(m, withVision: _withVision && m.supportsVision);
    final tps = d.estimateTokensPerSecond(m);
    final downloader = ModelDownloaderService();

    return DesignCard(
      selected: widget.recommended,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (m.tier != null) Pill(m.tier!, style: PillStyle.outline) else Pill(m.quant, style: PillStyle.outline),
              const Spacer(),
              if (widget.recommended) const Pill('BEST FOR YOUR PHONE', style: PillStyle.solid),
              if (widget.inUse) ...[const SizedBox(width: 6), const Pill('IN USE', style: PillStyle.success)],
            ],
          ),
          const SizedBox(height: 12),
          Text(m.name,
              style: GoogleFonts.interTight(
                  fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
          const SizedBox(height: 4),
          Text(
            m.tagline ?? '${m.author} · ${m.license ?? 'license: see model page'}',
            style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2, height: 1.4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ModelChip(icon: Icons.download_rounded, label: m.sizeLabel),
              ModelChip(
                icon: Icons.memory_rounded,
                label: 'RAM ~${m.ramNeededGB(withVision: _withVision && m.supportsVision).toStringAsFixed(1)} GB',
              ),
              ModelChip(icon: Icons.speed_rounded, label: _speedLabel(tps)),
              if (m.supportsVision) const ModelChip(icon: Icons.image_outlined, label: 'Sees photos'),
              if (m.toolUse == ToolUse.full) const ModelChip(icon: Icons.touch_app_outlined, label: 'Phone actions'),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: _fitColor(fit), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  switch (fit) {
                    ModelFit.good => 'Runs well on this phone',
                    ModelFit.tight => 'Tight fit: close other apps before chatting',
                    ModelFit.tooBig => 'Probably too big for this phone\'s memory',
                  },
                  style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.ink2),
                ),
              ),
              Text(_fitLabel(fit).toUpperCase(),
                  style: GoogleFonts.jetBrainsMono(fontSize: 9.5, letterSpacing: 1, color: _fitColor(fit))),
            ],
          ),
          if (m.supportsVision && !widget.downloaded) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _withVision = !_withVision),
              child: Row(
                children: [
                  Checkbox(
                    value: _withVision,
                    onChanged: (v) => setState(() => _withVision = v ?? true),
                    activeColor: AppTheme.primary,
                    checkColor: AppTheme.onPrimary,
                    side: BorderSide(color: AppTheme.border2),
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: Text(
                      'Include image support (+${formatBytes(m.mmprojSizeBytes ?? 0)})',
                      style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          ValueListenableBuilder<DownloadProgress?>(
            valueListenable: downloader.progress,
            builder: (context, progress, _) {
              if (progress != null && progress.modelId == m.id) {
                return Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.fraction,
                          minHeight: 6,
                          backgroundColor: AppTheme.surface3,
                          valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${(progress.fraction * 100).toStringAsFixed(0)}%',
                        style: GoogleFonts.jetBrainsMono(fontSize: 11, color: AppTheme.ink2)),
                  ],
                );
              }
              if (widget.downloaded) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: PrimaryButton(
                            onPressed: widget.onUse,
                            label: widget.inUse ? 'Continue chatting' : 'Use this model',
                            leading: SparkleIcon(size: 14, color: AppTheme.onPrimary),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: widget.onDelete,
                          icon: Icon(Icons.delete_outline_rounded, color: AppTheme.ink2),
                        ),
                      ],
                    ),
                    if (widget.onSettings != null || widget.onBenchmark != null ||
                        (m.supportsVision && !widget.visionReady) || widget.onDeleteVision != null)
                      Wrap(
                        spacing: 4,
                        children: [
                          if (widget.onSettings != null)
                            _smallAction(Icons.tune_rounded, 'Settings', widget.onSettings!),
                          if (widget.onBenchmark != null)
                            _smallAction(Icons.speed_rounded, 'Speed test', widget.onBenchmark!),
                          if (m.supportsVision && !widget.visionReady)
                            _smallAction(Icons.image_outlined,
                                'Add image support (${formatBytes(m.mmprojSizeBytes ?? 0)})',
                                progress == null ? () => widget.onDownload(true) : null),
                          if (widget.onDeleteVision != null)
                            _smallAction(Icons.hide_image_outlined, 'Remove image support', widget.onDeleteVision!),
                        ],
                      ),
                  ],
                );
              }
              final size = m.sizeBytes + (_withVision && m.supportsVision ? (m.mmprojSizeBytes ?? 0) : 0);
              return PrimaryButton(
                onPressed: progress != null ? null : () => widget.onDownload(_withVision),
                label: widget.partial ? 'Resume download' : 'Download · ${formatBytes(size)}',
                icon: Icons.download_rounded,
                background: widget.recommended ? null : AppTheme.surface3,
                foreground: widget.recommended ? null : AppTheme.ink,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _smallAction(IconData icon, String label, VoidCallback? onTap) => TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16, color: AppTheme.ink2),
        label: Text(label, style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2)),
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
      );
}

/// Searches the Hugging Face hub for GGUF chat models.
class _ExploreTab extends StatefulWidget {
  final DeviceProfile device;
  final Future<void> Function(LocalModel model, {bool withVision}) onDownload;
  final bool Function(LocalModel model) isDownloaded;
  const _ExploreTab({required this.device, required this.onDownload, required this.isDownloaded});

  @override
  State<_ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<_ExploreTab> with AutomaticKeepAliveClientMixin {
  final _hub = HfHubClient();
  final _query = TextEditingController();
  HubSort _sort = HubSort.popular;
  bool _fitsOnly = true;
  bool _loading = false;
  String? _error;
  List<HubModelSummary> _results = [];
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await _hub.search(query: _query.text, sort: _sort);
      if (!mounted || gen != _generation) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  bool _fits(HubModelSummary m) {
    final gb = m.approxQ4GB;
    // Unknown size: keep it; the file list shows exact sizes.
    return gb == null || gb * 1.05 + 0.5 <= widget.device.usableForAiGB;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shown = _fitsOnly ? _results.where(_fits).toList() : _results;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            style: GoogleFonts.interTight(color: AppTheme.ink),
            decoration: InputDecoration(
              hintText: 'Search thousands of models (e.g. qwen, gemma, llama)',
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.muted),
              suffixIcon: IconButton(
                icon: Icon(Icons.arrow_forward_rounded, color: AppTheme.ink2),
                onPressed: _search,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final s in HubSort.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(s.label),
                    selected: _sort == s,
                    onSelected: (_) {
                      setState(() => _sort = s);
                      _search();
                    },
                    selectedColor: AppTheme.primary,
                    backgroundColor: AppTheme.surface,
                    labelStyle: GoogleFonts.interTight(
                        fontSize: 12.5,
                        color: _sort == s ? AppTheme.onPrimary : AppTheme.ink2,
                        fontWeight: FontWeight.w600),
                    side: BorderSide(color: AppTheme.border),
                    showCheckmark: false,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  label: const Text('Fits my phone'),
                  selected: _fitsOnly,
                  onSelected: (v) => setState(() => _fitsOnly = v),
                  selectedColor: AppTheme.surface3,
                  backgroundColor: AppTheme.surface,
                  checkmarkColor: AppTheme.ink,
                  labelStyle: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2, fontWeight: FontWeight.w600),
                  side: BorderSide(color: AppTheme.border),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: AppTheme.muted))
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.interTight(color: AppTheme.ink2, height: 1.45)),
                            const SizedBox(height: 12),
                            TextButton(onPressed: _search, child: const Text('Try again')),
                          ],
                        ),
                      ),
                    )
                  : shown.isEmpty
                      ? Center(
                          child: Text(
                            _results.isEmpty ? 'No models found.' : 'Nothing here fits this phone. Turn off "Fits my phone".',
                            style: GoogleFonts.interTight(color: AppTheme.muted),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, i) => _resultTile(shown[i]),
                        ),
        ),
      ],
    );
  }

  Widget _resultTile(HubModelSummary m) {
    final params = m.paramsB;
    return DesignCard(
      padding: const EdgeInsets.all(14),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => _RepoSheet(
          summary: m,
          device: widget.device,
          onDownload: widget.onDownload,
          isDownloaded: widget.isDownloaded,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(m.name,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.interTight(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.ink)),
              ),
              if (m.gated) Icon(Icons.lock_outline_rounded, size: 15, color: AppTheme.muted),
            ],
          ),
          const SizedBox(height: 3),
          Text('by ${m.author}', style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.primary)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (params != null) Pill('${params % 1 == 0 ? params.toInt() : params}B', style: PillStyle.outline),
              if (m.vision) const Pill('IMAGE + TEXT', style: PillStyle.surface),
              Text('↓ ${_compact(m.downloads)}  ♥ ${_compact(m.likes)}'
                  '${m.created == null ? '' : '  · ${_date(m.created!)}'}',
                  style: GoogleFonts.jetBrainsMono(fontSize: 11, color: AppTheme.muted)),
            ],
          ),
        ],
      ),
    );
  }

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K'
          : '$n';

  static String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

/// One repository: pick a quantisation (and image support) to download.
class _RepoSheet extends StatefulWidget {
  final HubModelSummary summary;
  final DeviceProfile device;
  final Future<void> Function(LocalModel model, {bool withVision}) onDownload;
  final bool Function(LocalModel model) isDownloaded;
  const _RepoSheet({
    required this.summary,
    required this.device,
    required this.onDownload,
    required this.isDownloaded,
  });

  @override
  State<_RepoSheet> createState() => _RepoSheetState();
}

class _RepoSheetState extends State<_RepoSheet> {
  HubRepoDetails? _details;
  String? _error;
  HubFile? _picked;
  bool _withVision = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final details = await HfHubClient().details(widget.summary.repo);
      if (!mounted) return;
      setState(() {
        _details = details;
        _picked = HfHubClient.pickDefault(details.models, usableGB: widget.device.usableForAiGB);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Text(widget.summary.name,
              style: GoogleFonts.interTight(fontSize: 19, fontWeight: FontWeight.w600, color: AppTheme.ink)),
          const SizedBox(height: 4),
          Text(widget.summary.repo, style: GoogleFonts.jetBrainsMono(fontSize: 11, color: AppTheme.muted)),
          const SizedBox(height: 16),
          if (_error != null)
            Text(_error!, style: GoogleFonts.interTight(color: AppTheme.error))
          else if (details == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 1.6, color: AppTheme.muted)),
            )
          else if (details.models.isEmpty)
            Text('This repository has no single-file GGUF models this app can run.',
                style: GoogleFonts.interTight(color: AppTheme.ink2))
          else ...[
            if (details.gated)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'This model requires accepting its license on huggingface.co and a Hugging Face '
                  'access token (Settings → Hugging Face token).',
                  style: GoogleFonts.interTight(fontSize: 12.5, height: 1.45, color: AppTheme.ink2),
                ),
              ),
            if (details.license != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('License: ${details.license}',
                    style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2)),
              ),
            const Eyebrow('CHOOSE A VERSION'),
            const SizedBox(height: 8),
            Text(
              'Smaller files (Q3, Q4) run faster and use less memory; larger ones (Q6, Q8) are a little smarter.',
              style: GoogleFonts.interTight(fontSize: 12, height: 1.45, color: AppTheme.muted),
            ),
            const SizedBox(height: 8),
            for (final f in details.models) _fileTile(f),
            if (details.projectors.isNotEmpty) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _withVision,
                onChanged: (v) => setState(() => _withVision = v),
                title: Text('Image support', style: GoogleFonts.interTight(color: AppTheme.ink)),
                subtitle: Text(
                  'Adds ${formatBytes(HfHubClient.pickProjector(details.projectors)!.size)} so the model can look at photos.',
                  style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.muted),
                ),
              ),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              onPressed: _picked == null
                  ? null
                  : () {
                      final model = HfHubClient.toLocalModel(
                        details,
                        _picked!,
                        projector: _withVision ? HfHubClient.pickProjector(details.projectors) : null,
                      );
                      Navigator.pop(context);
                      if (widget.isDownloaded(model)) return;
                      widget.onDownload(model, withVision: _withVision);
                    },
              label: _picked == null ? 'Pick a version' : 'Download ${_picked!.quant} · ${formatBytes(_picked!.size)}',
              icon: Icons.download_rounded,
            ),
            const SizedBox(height: 10),
            Text(
              'Models from Hugging Face are made by their authors, not tested with this app. '
              'If a model misbehaves, delete it and try a curated one.',
              style: GoogleFonts.interTight(fontSize: 11.5, height: 1.45, color: AppTheme.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fileTile(HubFile f) {
    final ram = f.size / (1024 * 1024 * 1024) * 1.05 + 0.5;
    final fit = widget.device.fitFor(ram);
    final selected = _picked?.path == f.path;
    return InkWell(
      onTap: () => setState(() => _picked = f),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? AppTheme.primary : AppTheme.border),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                size: 18, color: selected ? AppTheme.primary : AppTheme.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(f.quant,
                  style: GoogleFonts.jetBrainsMono(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.ink)),
            ),
            Text(formatBytes(f.size), style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.ink2)),
            const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: _fitColor(fit), shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }
}
