import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/agent_mode.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import 'api_key_setup_screen.dart';
import 'home_screen.dart';
import 'intro_screen.dart';

/// Settings — visual language ported from ClassNow (Fraunces title,
/// Inter body, JetBrains Mono labels, GlassCard surfaces). Adds the
/// new "Backend" section that exposes the local-vs-cloud choice and
/// the Gemini API key.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DeviceService _deviceService = DeviceService();
  final ModelDownloaderService _downloader = ModelDownloaderService();

  Map<String, dynamic> _stats = {};
  bool _statsLoading = true;
  final Map<String, bool> _modelReady = {};
  AgentMode _mode = AgentMode.local;
  String? _apiKeyMasked;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final stats = await _deviceService.getQuickStats();
    final ready = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      ready[spec.fileName] =
          await _downloader.isModelDownloaded(spec.fileName);
    }
    final mode = await AgentModeStore.read() ?? AgentMode.local;
    final key = await AgentModeStore.readApiKey();
    if (mounted) {
      setState(() {
        _stats = stats;
        _statsLoading = false;
        _modelReady
          ..clear()
          ..addAll(ready);
        _mode = mode;
        _apiKeyMasked = (key != null && key.length > 4)
            ? '••••${key.substring(key.length - 4)}'
            : null;
      });
    }
  }

  Future<void> _toggleMode() async {
    final next = _mode == AgentMode.local ? AgentMode.cloud : AgentMode.local;
    await AgentModeStore.write(next);
    if (!mounted) return;
    setState(() => _mode = next);
    if (next == AgentMode.cloud && _apiKeyMasked == null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const ApiKeySetupScreen(),
      ));
      _loadData();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Switched to ${next == AgentMode.local ? 'local' : 'cloud'} mode. Restart chat to apply.',
          style: AppTextStyles.body.copyWith(color: AppTheme.glassInk),
        ),
        backgroundColor: AppTheme.glassBg2,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _editApiKey() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const ApiKeySetupScreen(),
    ));
    _loadData();
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.glassBg,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _topBar()
                      .animate()
                      .fadeIn(duration: 400.ms),
                  const SizedBox(height: 24),
                  _sectionLabel('BACKEND'),
                  _buildBackendSection()
                      .animate()
                      .fadeIn(delay: 80.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                  _sectionLabel('LOCAL MODELS'),
                  _buildModelsSection()
                      .animate()
                      .fadeIn(delay: 160.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                  _sectionLabel('DEVICE'),
                  _buildDeviceSection()
                      .animate()
                      .fadeIn(delay: 240.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                  _sectionLabel('STORAGE'),
                  _buildStorageSection()
                      .animate()
                      .fadeIn(delay: 320.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                  _sectionLabel('ONBOARDING'),
                  _buildOnboardingSection()
                      .animate()
                      .fadeIn(delay: 400.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                  _sectionLabel('ABOUT'),
                  _buildAboutSection()
                      .animate()
                      .fadeIn(delay: 480.ms)
                      .moveY(begin: 12, end: 0),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded,
              color: AppTheme.glassInk2, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        const Spacer(),
        Text(
          'Settings',
          style: AppTextStyles.title.copyWith(
            color: AppTheme.glassInk,
            fontSize: 22,
          ),
        ),
        const Spacer(),
        const SizedBox(width: 48),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Text(
        text,
        style: AppTextStyles.mono.copyWith(
          color: AppTheme.glassMuted,
          fontSize: 10,
        ),
      ),
    );
  }

  // ─── Backend section (new) ───
  Widget _buildBackendSection() {
    final isCloud = _mode == AgentMode.cloud;
    final accent = isCloud ? AppTheme.glassMagenta : AppTheme.glassAccent;
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: isCloud ? Icons.cloud_rounded : Icons.smartphone_rounded,
            title: 'Mode',
            color: accent,
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _toggleMode,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isCloud ? 'Cloud (Gemini)' : 'Local (on-device)',
                            style: AppTextStyles.bodyStrong.copyWith(
                              color: AppTheme.glassInk,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isCloud
                                ? 'Smarter, uses your API key.'
                                : 'Private, runs on this device.',
                            style: AppTextStyles.small.copyWith(
                              color: AppTheme.glassInk2.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: accent.withValues(alpha: 0.18),
                      ),
                      child: Text(
                        'TAP TO SWITCH',
                        style: AppTextStyles.mono.copyWith(
                          color: accent,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isCloud) ...[
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _editApiKey,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.glassBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.key_rounded,
                          size: 18, color: AppTheme.glassInk2),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gemini API key',
                              style: AppTextStyles.bodyStrong.copyWith(
                                color: AppTheme.glassInk,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _apiKeyMasked ?? 'Not set — tap to add',
                              style: AppTextStyles.small.copyWith(
                                color: _apiKeyMasked != null
                                    ? AppTheme.accentSuccess
                                    : AppTheme.accentError,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: AppTheme.glassMuted),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Local models section ───
  Widget _buildModelsSection() {
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.memory_rounded,
            title: 'Downloaded models',
            color: AppTheme.glassAccent,
          ),
          const SizedBox(height: 16),
          for (int i = 0; i < ModelRegistry.all.length; i++) ...[
            _modelRow(
              ModelRegistry.all[i].displayName,
              ModelRegistry.all[i].supportsVision ? 'Vision' : 'Lite',
              ModelRegistry.all[i].sizeLabel,
              _modelReady[ModelRegistry.all[i].fileName] ?? false,
            ),
            if (i < ModelRegistry.all.length - 1) const SizedBox(height: 12),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HomeScreen()),
                );
              },
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(
                'Manage models',
                style: AppTextStyles.bodyStrong.copyWith(fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.glassAccent,
                side: BorderSide(
                  color: AppTheme.glassAccent.withValues(alpha: 0.3),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
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
                  Text(
                    name,
                    style: AppTextStyles.bodyStrong
                        .copyWith(color: AppTheme.glassInk, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      tag,
                      style: AppTextStyles.mono.copyWith(
                        color: AppTheme.glassMuted,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                size,
                style: AppTextStyles.small
                    .copyWith(color: AppTheme.glassMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: downloaded
                ? AppTheme.accentSuccess.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                downloaded
                    ? Icons.check_circle_rounded
                    : Icons.cloud_download_outlined,
                size: 14,
                color: downloaded
                    ? AppTheme.accentSuccess
                    : AppTheme.glassMuted,
              ),
              const SizedBox(width: 4),
              Text(
                downloaded ? 'Ready' : 'Not downloaded',
                style: AppTextStyles.bodyStrong.copyWith(
                  color: downloaded
                      ? AppTheme.accentSuccess
                      : AppTheme.glassMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Device info ───
  Widget _buildDeviceSection() {
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.phone_android_rounded,
            title: 'Device information',
            color: AppTheme.glassMagenta,
          ),
          const SizedBox(height: 16),
          if (_statsLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.glassMuted,
                ),
              ),
            )
          else ...[
            _infoRow(Icons.devices_rounded, 'Device',
                '${_capitalize(_stats['brand'] ?? '?')} ${_stats['model'] ?? ''}'),
            _infoRow(Icons.android_rounded, 'OS', _stats['os'] ?? 'Unknown'),
            _infoRow(Icons.memory_rounded, 'RAM',
                '${_stats['ramGB'] ?? '?'} GB'),
            _infoRow(Icons.developer_board_rounded, 'CPU threads',
                '${_stats['cpuCores'] ?? '?'}'),
            _infoRow(Icons.battery_charging_full_rounded, 'Battery',
                '${_stats['battery'] ?? '?'}%'),
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

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.glassMuted, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body.copyWith(
                color: AppTheme.glassInk2,
                fontSize: 13,
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: AppTextStyles.bodyStrong.copyWith(
                color: AppTheme.glassInk,
                fontSize: 13,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Storage ───
  Widget _buildStorageSection() {
    final totalMB = _stats['storageTotal'] as double?;
    final freeMB = _stats['storageFree'] as double?;
    double usedFraction = 0;
    double modelUsageGB = 0;
    for (final spec in ModelRegistry.all) {
      if (_modelReady[spec.fileName] == true) {
        modelUsageGB += spec.sizeMB / 1024.0;
      }
    }
    if (totalMB != null && freeMB != null) {
      usedFraction = 1.0 - (freeMB / totalMB);
    }
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.pie_chart_rounded,
            title: 'Storage usage',
            color: const Color(0xFFFBBF24),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: usedFraction.clamp(0.0, 1.0),
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation<Color>(
                  usedFraction > 0.85
                      ? AppTheme.accentError
                      : AppTheme.glassAccent,
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
                    : 'Calculating…',
                style: AppTextStyles.small
                    .copyWith(color: AppTheme.glassInk2, fontSize: 12),
              ),
              Text(
                totalMB != null
                    ? '${(totalMB / 1024).toStringAsFixed(1)} GB total'
                    : '',
                style: AppTextStyles.small
                    .copyWith(color: AppTheme.glassInk2, fontSize: 12),
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
                const Icon(Icons.folder_rounded,
                    color: AppTheme.glassMuted, size: 16),
                const SizedBox(width: 10),
                Text(
                  'AI models',
                  style: AppTextStyles.body
                      .copyWith(color: AppTheme.glassInk2, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  '${modelUsageGB.toStringAsFixed(2)} GB',
                  style: AppTextStyles.bodyStrong
                      .copyWith(color: AppTheme.glassInk, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Onboarding (replay) ───
  Widget _buildOnboardingSection() {
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.replay_rounded,
            title: 'Replay intro',
            color: AppTheme.glassCyan,
          ),
          const SizedBox(height: 14),
          Text(
            'Step back through the welcome → permissions → mode selection flow. Your API key, mode, and downloaded models are kept — nothing is wiped.',
            style: AppTextStyles.small.copyWith(
              color: AppTheme.glassInk2.withValues(alpha: 0.75),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _replayIntro,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.glassCyan.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.glassCyan.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.play_arrow_rounded,
                        color: AppTheme.glassCyan, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Show me the intro again',
                      style: AppTextStyles.bodyStrong.copyWith(
                        color: AppTheme.glassCyan,
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.chevron_right_rounded,
                        color: AppTheme.glassMuted),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _replayIntro() async {
    // Just clear the "you've seen the intro" flag — leave mode + key alone
    // so the user lands back where they were once they finish walking
    // through the screens again.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('onboarding_seen_v1');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const IntroScreen()),
      (_) => false,
    );
  }

  // ─── About ───
  Widget _buildAboutSection() {
    return GlassCard(
      blur: 25,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.info_outline_rounded,
            title: 'About',
            color: AppTheme.accentSuccess,
          ),
          const SizedBox(height: 16),
          _aboutRow('App version', '1.0.0'),
          _aboutRow('Local engine', 'LiteRT-LM (GPU)'),
          _aboutRow('Cloud engine', 'google_generative_ai'),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Powered by Gemma + Gemini · BYO-key',
              style: AppTextStyles.small.copyWith(
                color: AppTheme.glassMuted,
                fontSize: 11,
              ),
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
          Text(
            label,
            style: AppTextStyles.body
                .copyWith(color: AppTheme.glassInk2, fontSize: 13),
          ),
          Text(
            value,
            style: AppTextStyles.bodyStrong
                .copyWith(color: AppTheme.glassInk, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader({
    required IconData icon,
    required String title,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: AppTextStyles.title.copyWith(
            color: AppTheme.glassInk,
            fontSize: 17,
          ),
        ),
      ],
    );
  }
}
