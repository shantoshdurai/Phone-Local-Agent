import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/model_downloader_service.dart';
import '../services/device_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'splash_screen.dart';

/// 04 · Pick a model — main entry point when no model is loaded yet.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ModelDownloaderService _downloader = ModelDownloaderService();
  final DeviceService _deviceService = DeviceService();

  final Map<String, bool> _isDownloaded = {};
  final Map<String, bool> _hasPartial = {};
  String? _downloadingFileName;
  double _downloadProgress = 0.0;
  String _downloadSpeed = '';
  String _downloadedStr = '';
  String _totalStr = '';

  Map<String, dynamic> _stats = {};

  @override
  void initState() {
    super.initState();
    _checkModels();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await _deviceService.getQuickStats();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _checkModels() async {
    final dir = await _downloader.getModelsDirectory();
    final downloaded = <String, bool>{};
    final partial = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      final isDone = await _downloader.isModelDownloaded(spec.fileName);
      downloaded[spec.fileName] = isDone;
      partial[spec.fileName] =
          !isDone && await File('$dir/${spec.fileName}.part').exists();
    }
    if (!mounted) return;
    setState(() {
      _isDownloaded
        ..clear()
        ..addAll(downloaded);
      _hasPartial
        ..clear()
        ..addAll(partial);
    });
  }

  void _startDownload(ModelSpec spec) {
    setState(() {
      _downloadingFileName = spec.fileName;
      _downloadProgress = 0.0;
      _downloadSpeed = 'Starting...';
    });
    _downloader.downloadModel(
      url: spec.url,
      fileName: spec.fileName,
      onProgress: (p, s, d, t) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = p;
          _downloadSpeed = s;
          _downloadedStr = d;
          _totalStr = t;
        });
      },
      onComplete: () {
        if (!mounted) return;
        setState(() => _downloadingFileName = null);
        _checkModels();
      },
      onError: (err) {
        if (!mounted) return;
        setState(() => _downloadingFileName = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        _checkModels();
      },
    );
  }

  void _cancelDownload() {
    _downloader.cancelDownload();
    setState(() => _downloadingFileName = null);
    _checkModels();
  }

  Future<void> _startChat(ModelSpec spec) async {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
          builder: (_) => SplashScreen(modelFileName: spec.fileName)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final recommended = ModelRegistry.defaultForDevice(_stats['ramGB'] as int?);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: Navigator.canPop(context)
                    ? () => Navigator.pop(context)
                    : null,
              ),
              title: Text(
                'Local Agent',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Model',
                      style: GoogleFonts.interTight(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.7,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Download an AI model to run locally on your device.',
                      style: GoogleFonts.interTight(
                        fontSize: 14,
                        height: 1.55,
                        color: AppTheme.ink2,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ...ModelRegistry.all.map((spec) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _modelCard(
                            spec: spec,
                            recommended: spec.id == recommended.id,
                          ),
                        )),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelCard({required ModelSpec spec, required bool recommended}) {
    final downloaded = _isDownloaded[spec.fileName] ?? false;
    final hasPartial = _hasPartial[spec.fileName] ?? false;
    final downloading = _downloadingFileName == spec.fileName;
    final otherDownloading = _downloadingFileName != null && !downloading;

    return DesignCard(
      selected: recommended,
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
              if (recommended) const Pill('RECOMMENDED', style: PillStyle.solid),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            spec.tagline,
            style: GoogleFonts.interTight(
              fontSize: 12.5,
              color: AppTheme.ink2,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ModelChip(icon: Icons.memory_rounded, label: spec.sizeLabel),
              ModelChip(
                icon: Icons.bolt_rounded,
                label: spec.supportsVision ? 'GPU · Vision' : 'GPU · Fast',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (downloading)
            _downloadProgressView()
          else
            PrimaryButton(
              onPressed: otherDownloading
                  ? null
                  : () =>
                      downloaded ? _startChat(spec) : _startDownload(spec),
              label: downloaded
                  ? 'Start Chat'
                  : (hasPartial ? 'Resume Download' : 'Download Model'),
              icon: downloaded
                  ? null
                  : Icons.download_rounded,
              leading: downloaded ? const SparkleIcon(size: 14) : null,
              background: downloaded ? AppTheme.ink : AppTheme.surface3,
              foreground: downloaded ? AppTheme.bg : AppTheme.ink,
            ),
        ],
      ),
    );
  }

  Widget _downloadProgressView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _downloadProgress,
            minHeight: 6,
            backgroundColor: AppTheme.surface3,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.ink),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$_downloadSpeed · ${(_downloadProgress * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                color: AppTheme.muted,
                letterSpacing: 0.4,
              ),
            ),
            Text(
              '$_downloadedStr / $_totalStr',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                color: AppTheme.muted,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _cancelDownload,
            child: Text(
              'Cancel',
              style: GoogleFonts.interTight(
                  color: AppTheme.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
