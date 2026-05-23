import 'dart:io';
import 'package:flutter/material.dart';
import '../services/model_downloader_service.dart';
import '../services/device_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import 'splash_screen.dart';

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
  bool _statsLoading = true;

  @override
  void initState() {
    super.initState();
    _checkModels();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final stats = await _deviceService.getQuickStats();
    if (mounted) setState(() { _stats = stats; _statsLoading = false; });
  }

  Future<void> _checkModels() async {
    final dir = await _downloader.getModelsDirectory();
    final downloaded = <String, bool>{};
    final partial = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      final isDone = await _downloader.isModelDownloaded(spec.fileName);
      downloaded[spec.fileName] = isDone;
      partial[spec.fileName] = !isDone && await File('$dir/${spec.fileName}.part').exists();
    }
    if (!mounted) return;
    setState(() {
      _isDownloaded..clear()..addAll(downloaded);
      _hasPartial..clear()..addAll(partial);
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
        if (mounted) setState(() { _downloadProgress = p; _downloadSpeed = s; _downloadedStr = d; _totalStr = t; });
      },
      onComplete: () {
        if (mounted) { setState(() => _downloadingFileName = null); _checkModels(); }
      },
      onError: (err) {
        if (mounted) {
          setState(() => _downloadingFileName = null);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
          _checkModels();
        }
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
      MaterialPageRoute(builder: (context) => SplashScreen(modelFileName: spec.fileName)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.glassBg,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppTheme.glassInk, size: 20),
                    onPressed: () {
                      if (Navigator.canPop(context)) Navigator.pop(context);
                      else {
                        // try to find first downloaded model and launch chat as fallback
                        final firstReady = ModelRegistry.all.where((s) => _isDownloaded[s.fileName] == true).firstOrNull;
                        if (firstReady != null) {
                          _startChat(firstReady);
                        }
                      }
                    },
                  ),
                  const Spacer(),
                  Text('Local Agent', style: AppTextStyles.heading.copyWith(color: AppTheme.glassInk, fontSize: 18)),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 32),
              Text(
                'Select Model',
                style: AppTextStyles.heading.copyWith(color: AppTheme.glassInk, fontSize: 32, letterSpacing: -1.0, height: 1.1),
              ),
              const SizedBox(height: 12),
              Text(
                'Download an AI model to run locally on your device.',
                style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 14),
              ),
              const SizedBox(height: 32),
              ...ModelRegistry.all.map((spec) {
                final isRecommended = spec.id == ModelRegistry.defaultForDevice(_stats['ramGB'] as int?).id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildModelCard(spec: spec, isPrimary: isRecommended),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelCard({required ModelSpec spec, required bool isPrimary}) {
    final isDownloaded = _isDownloaded[spec.fileName] ?? false;
    final hasPartial = _hasPartial[spec.fileName] ?? false;
    final isDownloading = _downloadingFileName == spec.fileName;
    final isOtherDownloading = _downloadingFileName != null && !isDownloading;
    
    String btnText = isDownloaded ? 'Start Chat' : (hasPartial ? 'Resume Download' : 'Download Model');

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.glassBg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isPrimary ? AppTheme.glassInk : AppTheme.glassBorder, width: isPrimary ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.displayName,
                  style: AppTextStyles.heading.copyWith(color: AppTheme.glassInk, fontSize: 22),
                ),
              ),
              if (isPrimary)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: AppTheme.glassInk, borderRadius: BorderRadius.circular(6)),
                  child: Text('RECOMMENDED', style: AppTextStyles.mono.copyWith(color: AppTheme.glassBg, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(spec.tagline, style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 14, height: 1.4)),
          const SizedBox(height: 20),
          Row(
            children: [
              _infoChip(Icons.memory_rounded, spec.sizeLabel),
              const SizedBox(width: 12),
              _infoChip(Icons.bolt_rounded, spec.supportsVision ? 'GPU Vision' : 'GPU Fast'),
            ],
          ),
          const SizedBox(height: 24),
          if (isDownloading)
            _buildDownloadProgress()
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isOtherDownloading ? null : () => isDownloaded ? _startChat(spec) : _startDownload(spec),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDownloaded ? AppTheme.glassInk : AppTheme.glassSurface2,
                  foregroundColor: isDownloaded ? AppTheme.glassBg : AppTheme.glassInk,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 0,
                ),
                child: Text(btnText, style: AppTextStyles.bodyStrong.copyWith(fontSize: 15)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.glassMuted),
        const SizedBox(width: 6),
        Text(text, style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 12)),
      ],
    );
  }

  Widget _buildDownloadProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _downloadProgress,
            minHeight: 6,
            backgroundColor: AppTheme.glassSurface,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.glassInk),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('$_downloadSpeed  ·  ${(_downloadProgress * 100).toStringAsFixed(1)}%', style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 12)),
            Text('$_downloadedStr / $_totalStr', style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _cancelDownload,
            child: Text('Cancel', style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk, fontSize: 14)),
          ),
        ),
      ],
    );
  }
}
