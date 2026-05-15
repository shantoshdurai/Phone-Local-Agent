
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/model_downloader_service.dart';
import '../services/device_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final ModelDownloaderService _downloader = ModelDownloaderService();
  final DeviceService _deviceService = DeviceService();

  bool _isModelDownloaded = false;
  bool _hasModelPartial = false;

  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadSpeed = '';
  String _downloadedStr = '';
  String _totalStr = '';

  // Device stats
  Map<String, dynamic> _stats = {};
  bool _statsLoading = true;

  static const String _modelUrl =
      "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm";

  static const String _modelFile = "gemma-4-E2B-it.litertlm";

  // Animations
  late AnimationController _entranceController;
  late List<Animation<double>> _fadeAnims;
  late List<Animation<Offset>> _slideAnims;

  @override
  void initState() {
    super.initState();
    _checkModels();
    _loadStats();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    // 4 sections: badge, title, performance, model
    _fadeAnims = List.generate(4, (i) {
      final start = i * 0.15;
      final end = (start + 0.4).clamp(0.0, 1.0);
      return Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _entranceController, curve: Interval(start, end, curve: Curves.easeOut)),
      );
    });
    _slideAnims = List.generate(4, (i) {
      final start = i * 0.15;
      final end = (start + 0.4).clamp(0.0, 1.0);
      return Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
        CurvedAnimation(parent: _entranceController, curve: Interval(start, end, curve: Curves.easeOut)),
      );
    });

    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final stats = await _deviceService.getQuickStats();
    if (mounted) {
      setState(() {
        _stats = stats;
        _statsLoading = false;
      });
    }
  }

  Future<void> _checkModels() async {
    final downloaded = await _downloader.isModelDownloaded(_modelFile);
    final dir = await _downloader.getModelsDirectory();
    final hasPart = await File('$dir/$_modelFile.part').exists();

    setState(() {
      _isModelDownloaded = downloaded;
      _hasModelPartial = hasPart && !downloaded;
    });
  }

  void _startDownload() {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadSpeed = 'Starting...';
    });

    _downloader.downloadModel(
      url: _modelUrl,
      fileName: _modelFile,
      onProgress: (progress, speed, downloaded, total) {
        if (mounted) {
          setState(() {
            _downloadProgress = progress;
            _downloadSpeed = speed;
            _downloadedStr = downloaded;
            _totalStr = total;
          });
        }
      },
      onComplete: () {
        if (mounted) {
          setState(() => _isDownloading = false);
          _checkModels();
        }
      },
      onError: (err) {
        if (mounted) {
          setState(() => _isDownloading = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(err),
            behavior: SnackBarBehavior.floating,
          ));
          _checkModels();
        }
      },
    );
  }

  void _cancelDownload() {
    _downloader.cancelDownload();
    setState(() => _isDownloading = false);
    _checkModels();
  }

  Future<void> _startChat() async {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => ChatScreen(modelFileName: _modelFile)),
      (route) => false,
    );
  }

  String _performanceLabel() {
    final ram = _stats['ramGB'] as int?;
    if (ram == null) return 'Checking...';
    if (ram >= 8) return 'Optimal';
    if (ram >= 4) return 'Good';
    return 'Limited';
  }

  Color _performanceColor() {
    final ram = _stats['ramGB'] as int?;
    if (ram == null) return Colors.white24;
    if (ram >= 8) return const Color(0xFF34D399);
    if (ram >= 4) return const Color(0xFFFBBF24);
    return const Color(0xFFF87171);
  }

  // ─── Build helpers ───

  Widget _animatedSection(int index, Widget child) {
    return FadeTransition(
      opacity: _fadeAnims[index],
      child: SlideTransition(position: _slideAnims[index], child: child),
    );
  }

  Widget _buildBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF3B82F6).withValues(alpha: 0.25),
            const Color(0xFF8B5CF6).withValues(alpha: 0.15),
          ],
        ),
        border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF3B82F6),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'LOCAL AGENT SETUP',
            style: GoogleFonts.outfit(
              color: const Color(0xFF93C5FD),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            colors: [Colors.white, Color(0xFFD1D5DB)],
          ).createShader(rect),
          child: Text(
            'Welcome to Fully\nOffline AI',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Experience uncompromised privacy and zero latency. '
          'Onyx Intelligence runs directly on your hardware, '
          'ensuring your data never leaves your device.',
          style: GoogleFonts.outfit(
            color: Colors.white54,
            fontSize: 14,
            height: 1.6,
          ),
        ),
      ],
    );
  }

  Widget _buildPerformanceCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.07),
                Colors.white.withValues(alpha: 0.03),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            children: [
              // Title row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.grid_view_rounded, color: Colors.white70, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Device Performance Assessment',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Performance badge
                  _statsLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white24),
                        )
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _performanceColor().withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _performanceColor().withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            _performanceLabel(),
                            style: GoogleFonts.outfit(
                              color: _performanceColor(),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ],
              ),
              const SizedBox(height: 20),
              // Metric tiles
              Row(
                children: [
                  Expanded(child: _metricTile('AVAILABLE RAM', _statsLoading ? '...' : '${_stats['ramGB'] ?? '?'} GB')),
                  const SizedBox(width: 12),
                  Expanded(child: _metricTile('CPU THREADS', _statsLoading ? '...' : '${_stats['cpuCores'] ?? '?'} Cores')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _metricTile(
                      'BATTERY',
                      _statsLoading ? '...' : '${_stats['battery'] ?? '?'}%',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _metricTile(
                      'FREE STORAGE',
                      _statsLoading
                          ? '...'
                          : _stats['storageFree'] != null
                              ? '${(_stats['storageFree'] / 1024).toStringAsFixed(1)} GB'
                              : '? GB',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.outfit(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelCard({
    required String name,
    required String tag,
    required String description,
    required String size,
    required String speed,
    required bool isDownloaded,
    required bool hasPartial,
    required bool isPrimary,
  }) {
    String btnText = 'Download Model';
    if (isDownloaded) {
        btnText = 'Start Chat';
    } else if (hasPartial) {
        btnText = 'Resume Download';
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isPrimary
                  ? [
                      const Color(0xFF3B82F6).withValues(alpha: 0.08),
                      Colors.white.withValues(alpha: 0.03),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.05),
                      Colors.white.withValues(alpha: 0.02),
                    ],
            ),
            border: Border.all(
              color: isPrimary
                  ? const Color(0xFF3B82F6).withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Name row
              Row(
                children: [
                  Text(
                    name,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isPrimary
                          ? const Color(0xFF3B82F6).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tag,
                      style: GoogleFonts.outfit(
                        color: isPrimary ? const Color(0xFF93C5FD) : Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (isPrimary) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.star_rounded, color: Color(0xFFFBBF24), size: 16),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(
                description,
                style: GoogleFonts.outfit(
                  color: Colors.white54,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              // Chips
              Row(
                children: [
                  _chip(Icons.download_rounded, size),
                  const SizedBox(width: 10),
                  _chip(Icons.bolt_rounded, speed),
                ],
              ),
              const SizedBox(height: 18),
              // Download progress or action button
              if (_isDownloading)
                _buildDownloadProgress()
              else
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isDownloading
                        ? null
                        : () {
                            if (isDownloaded) {
                              _startChat();
                            } else {
                              _startDownload();
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDownloaded
                          ? const Color(0xFF3B82F6)
                          : isPrimary
                              ? const Color(0xFF3B82F6)
                              : Colors.white.withValues(alpha: 0.1),
                      foregroundColor: isDownloaded || isPrimary ? Colors.white : Colors.white70,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      btnText,
                      style: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white38),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.outfit(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _downloadProgress,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '$_downloadSpeed  ·  ${(_downloadProgress * 100).toStringAsFixed(1)}%',
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
            ),
            Text(
              '$_downloadedStr / $_totalStr',
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _cancelDownload,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFF87171),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('Cancel', style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top bar
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white54, size: 20),
                    onPressed: () {
                      if (Navigator.canPop(context)) Navigator.pop(context);
                    },
                  ),
                  const Spacer(),
                  Text(
                    'Onyx Intelligence',
                    style: GoogleFonts.outfit(
                      color: Colors.white60,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48), // balance
                ],
              ),
              const SizedBox(height: 24),

              // Badge
              _animatedSection(0, _buildBadge()),
              const SizedBox(height: 20),

              // Title + subtitle
              _animatedSection(1, _buildHeader()),
              const SizedBox(height: 28),

              // Performance card
              _animatedSection(2, _buildPerformanceCard()),
              const SizedBox(height: 32),

              // Section label
              _animatedSection(
                3,
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'SELECT INFERENCE MODEL',
                    style: GoogleFonts.outfit(
                      color: Colors.white30,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),

              // Model card
              _animatedSection(
                3,
                _buildModelCard(
                  name: 'Gemma 4 E2B',
                  tag: 'Primary',
                  description:
                      "Google's edge-optimized 2B model with native function calling. "
                      "Handles real reasoning and multi-turn conversation — "
                      "not just keyword matching.",
                  size: '~2.59 GB',
                  speed: 'GPU Accelerated',
                  isDownloaded: _isModelDownloaded,
                  hasPartial: _hasModelPartial,
                  isPrimary: true,
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
