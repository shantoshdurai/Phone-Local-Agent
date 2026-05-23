import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/agent_mode.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart'; // we might not use glass anymore but keep it
import 'api_key_setup_screen.dart';
import 'home_screen.dart';
import 'intro_screen.dart';

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
      ready[spec.fileName] = await _downloader.isModelDownloaded(spec.fileName);
    }
    final mode = await AgentModeStore.read() ?? AgentMode.local;
    final key = await AgentModeStore.readApiKey();
    if (mounted) {
      setState(() {
        _stats = stats;
        _statsLoading = false;
        _modelReady..clear()..addAll(ready);
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
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _topBar().animate().fadeIn(duration: 400.ms),
              const SizedBox(height: 32),
              _sectionLabel('BACKEND'),
              _buildBackendSection().animate().fadeIn(delay: 80.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 32),
              _sectionLabel('LOCAL MODELS'),
              _buildModelsSection().animate().fadeIn(delay: 160.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 32),
              _sectionLabel('DEVICE'),
              _buildDeviceSection().animate().fadeIn(delay: 240.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 32),
              _sectionLabel('ONBOARDING'),
              _buildOnboardingSection().animate().fadeIn(delay: 320.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 32),
              _sectionLabel('ABOUT'),
              _buildAboutSection().animate().fadeIn(delay: 400.ms).moveY(begin: 12, end: 0),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppTheme.glassInk, size: 20),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              // Fallback
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
            }
          },
        ),
        const Spacer(),
        Text(
          'Settings',
          style: AppTextStyles.heading.copyWith(color: AppTheme.glassInk, fontSize: 20),
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
        style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 11, letterSpacing: 1.0),
      ),
    );
  }

  Widget _flatCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.glassBg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.glassBorder, width: 1),
      ),
      child: child,
    );
  }

  Widget _buildBackendSection() {
    final isCloud = _mode == AgentMode.cloud;
    return _flatCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: isCloud ? Icons.cloud_rounded : Icons.smartphone_rounded,
            title: 'Mode',
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _toggleMode,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.glassSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.glassBorder2),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isCloud ? 'Cloud (Gemini)' : 'Local (on-device)',
                          style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isCloud ? 'Smarter, uses your API key.' : 'Private, runs on this device.',
                          style: AppTextStyles.small.copyWith(color: AppTheme.glassInk2, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.swap_horiz_rounded, color: AppTheme.glassInk),
                ],
              ),
            ),
          ),
          if (isCloud) ...[
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _editApiKey,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.glassSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.glassBorder2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.key_rounded, size: 20, color: AppTheme.glassInk2),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Gemini API key',
                            style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk, fontSize: 15),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _apiKeyMasked ?? 'Not set — tap to add',
                            style: AppTextStyles.mono.copyWith(color: AppTheme.glassInk2, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppTheme.glassMuted),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModelsSection() {
    return _flatCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(icon: Icons.memory_rounded, title: 'Downloaded models'),
          const SizedBox(height: 20),
          for (int i = 0; i < ModelRegistry.all.length; i++) ...[
            _modelRow(
              ModelRegistry.all[i].displayName,
              ModelRegistry.all[i].supportsVision ? 'Vision' : 'Lite',
              ModelRegistry.all[i].sizeLabel,
              _modelReady[ModelRegistry.all[i].fileName] ?? false,
            ),
            if (i < ModelRegistry.all.length - 1) const SizedBox(height: 16),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HomeScreen()),
                );
              },
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text('Manage models', style: AppTextStyles.bodyStrong.copyWith(fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.glassInk,
                foregroundColor: AppTheme.glassBg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
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
                  Text(name, style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk, fontSize: 15)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.glassSurface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(tag, style: AppTextStyles.mono.copyWith(color: AppTheme.glassInk2, fontSize: 10)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(size, style: AppTextStyles.mono.copyWith(color: AppTheme.glassMuted, fontSize: 11)),
            ],
          ),
        ),
        Icon(
          downloaded ? Icons.check_circle_rounded : Icons.cloud_download_outlined,
          size: 20,
          color: downloaded ? AppTheme.glassInk : AppTheme.glassMuted,
        ),
      ],
    );
  }

  Widget _buildDeviceSection() {
    return _flatCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(icon: Icons.phone_android_rounded, title: 'Device information'),
          const SizedBox(height: 20),
          if (_statsLoading)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: AppTheme.glassInk)))
          else ...[
            _infoRow(Icons.devices_rounded, 'Device', '${_capitalize(_stats['brand'] ?? '?')} ${_stats['model'] ?? ''}'),
            _infoRow(Icons.android_rounded, 'OS', _stats['os'] ?? 'Unknown'),
            _infoRow(Icons.memory_rounded, 'RAM', '${_stats['ramGB'] ?? '?'} GB'),
            _infoRow(Icons.developer_board_rounded, 'CPU threads', '${_stats['cpuCores'] ?? '?'}'),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.glassMuted, size: 20),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 14))),
          Flexible(
            child: Text(
              value,
              style: AppTextStyles.mono.copyWith(color: AppTheme.glassInk, fontSize: 13),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnboardingSection() {
    return _flatCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(icon: Icons.replay_rounded, title: 'Replay intro'),
          const SizedBox(height: 16),
          Text(
            'Step back through the welcome → permissions → mode selection flow.',
            style: AppTextStyles.small.copyWith(color: AppTheme.glassInk2, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _replayIntro,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.glassSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.glassBorder2),
              ),
              child: Row(
                children: [
                  const Icon(Icons.play_arrow_rounded, color: AppTheme.glassInk, size: 20),
                  const SizedBox(width: 12),
                  Text('Show me the intro again', style: AppTextStyles.bodyStrong.copyWith(color: AppTheme.glassInk, fontSize: 15)),
                  const Spacer(),
                  const Icon(Icons.chevron_right_rounded, color: AppTheme.glassMuted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _replayIntro() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('onboarding_seen_v1');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const IntroScreen()),
      (_) => false,
    );
  }

  Widget _buildAboutSection() {
    return _flatCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(icon: Icons.info_outline_rounded, title: 'About'),
          const SizedBox(height: 20),
          _aboutRow('App version', '1.0.0'),
          _aboutRow('Local engine', 'LiteRT-LM (GPU)'),
          _aboutRow('Cloud engine', 'google_generative_ai'),
        ],
      ),
    );
  }

  Widget _aboutRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTextStyles.body.copyWith(color: AppTheme.glassInk2, fontSize: 14)),
          Text(value, style: AppTextStyles.mono.copyWith(color: AppTheme.glassInk, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _sectionHeader({required IconData icon, required String title}) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.glassInk, size: 22),
        const SizedBox(width: 12),
        Text(title, style: AppTextStyles.title.copyWith(color: AppTheme.glassInk, fontSize: 18)),
      ],
    );
  }
}
