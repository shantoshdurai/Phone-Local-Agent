
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  final DeviceService _deviceService = DeviceService();
  final ModelDownloaderService _downloader = ModelDownloaderService();

  Map<String, dynamic> _stats = {};
  bool _statsLoading = true;
  bool _isModelDownloaded = false;

  late AnimationController _entranceController;
  late List<Animation<double>> _fadeAnims;
  late List<Animation<Offset>> _slideAnims;

  @override
  void initState() {
    super.initState();
    _loadData();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

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
      return Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
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

  Future<void> _loadData() async {
    final stats = await _deviceService.getQuickStats();
    final modelReady = await _downloader.isModelDownloaded("gemma-4-E2B-it.litertlm");
    if (mounted) {
      setState(() {
        _stats = stats;
        _statsLoading = false;
        _isModelDownloaded = modelReady;
      });
    }
  }

  Widget _animatedSection(int index, Widget child) {
    return FadeTransition(
      opacity: _fadeAnims[index],
      child: SlideTransition(position: _slideAnims[index], child: child),
    );
  }

  Widget _glassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: double.infinity,
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
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: GoogleFonts.outfit(
          color: Colors.white30,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  // ─── Model Management Section ───
  Widget _buildModelsSection() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.memory_rounded, color: Color(0xFF3B82F6), size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                'Downloaded Models',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _modelRow(
            'Gemma 4 E2B',
            'Primary',
            '~2.59 GB',
            _isModelDownloaded,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const HomeScreen()),
                );
              },
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text('Manage Models', style: GoogleFonts.outfit(fontWeight: FontWeight.w600, fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF93C5FD),
                side: BorderSide(color: const Color(0xFF3B82F6).withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelRow(String name, String tag, String size, bool downloaded) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(name, style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(tag, style: GoogleFonts.outfit(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(size, style: GoogleFonts.outfit(color: Colors.white30, fontSize: 12)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: downloaded
                ? const Color(0xFF34D399).withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                downloaded ? Icons.check_circle_rounded : Icons.cloud_download_outlined,
                size: 14,
                color: downloaded ? const Color(0xFF34D399) : Colors.white30,
              ),
              const SizedBox(width: 4),
              Text(
                downloaded ? 'Ready' : 'Not Downloaded',
                style: GoogleFonts.outfit(
                  color: downloaded ? const Color(0xFF34D399) : Colors.white30,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Device Info Section ───
  Widget _buildDeviceSection() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.phone_android_rounded, color: Color(0xFF8B5CF6), size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                'Device Information',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_statsLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
              ),
            )
          else ...[
            _infoRow(Icons.devices_rounded, 'Device', '${_capitalize(_stats['brand'] ?? '?')} ${_stats['model'] ?? ''}'),
            _infoRow(Icons.android_rounded, 'Operating System', _stats['os'] ?? 'Unknown'),
            _infoRow(Icons.memory_rounded, 'RAM', '${_stats['ramGB'] ?? '?'} GB'),
            _infoRow(Icons.developer_board_rounded, 'CPU Threads', '${_stats['cpuCores'] ?? '?'}'),
            _infoRow(Icons.battery_charging_full_rounded, 'Battery', '${_stats['battery'] ?? '?'}%'),
            _infoRow(
              Icons.storage_rounded,
              'Storage',
              _stats['storageFree'] != null && _stats['storageTotal'] != null
                  ? '${(_stats['storageFree'] / 1024).toStringAsFixed(1)} GB free of ${(_stats['storageTotal'] / 1024).toStringAsFixed(1)} GB'
                  : 'Unknown',
            ),
          ],
        ],
      ),
    );
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: Colors.white24, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13)),
          ),
          Flexible(
            child: Text(
              value,
              style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Storage Section ───
  Widget _buildStorageSection() {
    final totalMB = _stats['storageTotal'] as double?;
    final freeMB = _stats['storageFree'] as double?;

    double usedFraction = 0;
    double modelUsageGB = 0;
    if (_isModelDownloaded) modelUsageGB += 2.59;

    if (totalMB != null && freeMB != null) {
      usedFraction = 1.0 - (freeMB / totalMB);
    }

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBBF24).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.pie_chart_rounded, color: Color(0xFFFBBF24), size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                'Storage Usage',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: usedFraction.clamp(0.0, 1.0),
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation<Color>(
                  usedFraction > 0.85 ? const Color(0xFFF87171) : const Color(0xFF3B82F6),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                totalMB != null
                    ? '${((totalMB - (freeMB ?? 0)) / 1024).toStringAsFixed(1)} GB used'
                    : 'Calculating...',
                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
              ),
              Text(
                totalMB != null ? '${(totalMB / 1024).toStringAsFixed(1)} GB total' : '',
                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_rounded, color: Colors.white24, size: 16),
                const SizedBox(width: 10),
                Text('AI Models', style: GoogleFonts.outfit(color: Colors.white54, fontSize: 13)),
                const Spacer(),
                Text(
                  '${modelUsageGB.toStringAsFixed(2)} GB',
                  style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── About Section ───
  Widget _buildAboutSection() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF34D399).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.info_outline_rounded, color: Color(0xFF34D399), size: 18),
              ),
              const SizedBox(width: 12),
              Text(
                'About',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _aboutRow('App Version', '1.0.0'),
          _aboutRow('Engine', 'LiteRT-LM (GPU)'),
          _aboutRow('Model', 'Gemma 4 E2B'),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Powered by Gemma 4 · 100% On-Device',
              style: GoogleFonts.outfit(color: Colors.white24, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13)),
          Text(value, style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
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
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  Text(
                    'Settings',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 28),

              // Models
              _animatedSection(0, _sectionLabel('MODELS')),
              _animatedSection(0, _buildModelsSection()),
              const SizedBox(height: 24),

              // Device
              _animatedSection(1, _sectionLabel('DEVICE')),
              _animatedSection(1, _buildDeviceSection()),
              const SizedBox(height: 24),

              // Storage
              _animatedSection(2, _sectionLabel('STORAGE')),
              _animatedSection(2, _buildStorageSection()),
              const SizedBox(height: 24),

              // About
              _animatedSection(3, _sectionLabel('ABOUT')),
              _animatedSection(3, _buildAboutSection()),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
