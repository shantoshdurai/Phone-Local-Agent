import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/agent_mode.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'home_screen.dart';
import 'package:url_launcher/url_launcher.dart';

/// 09 · Settings — agent mode toggle, active model, behavior switches, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DeviceService _deviceService = DeviceService();
  final ModelDownloaderService _downloader = ModelDownloaderService();

  Map<String, dynamic> _stats = {};
  final Map<String, bool> _modelReady = {};
  AgentMode _mode = AgentMode.local;
  String? _apiKeyMasked;

  // Local toggles — persisted lightly through SharedPreferences in a real app;
  // here they're memory-only and just drive the UI per the design.
  bool _confirmActions = true;
  bool _streamTokens = true;
  bool _saveHistory = true;

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
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _modelReady
        ..clear()
        ..addAll(ready);
      _mode = mode;
      _apiKeyMasked = (key != null && key.length > 4)
          ? '••••${key.substring(key.length - 4)}'
          : null;
    });
  }

  Future<void> _switchMode(AgentMode next) async {
    if (next == _mode) return;
    await AgentModeStore.write(next);
    if (!mounted) return;
    setState(() => _mode = next);
    if (next == AgentMode.cloud && _apiKeyMasked == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ApiKeySetupScreen()),
      );
      _loadData();
    }
  }

  int _readyCount() => _modelReady.values.where((v) => v).length;

  double _totalGB() {
    double total = 0;
    for (final spec in ModelRegistry.all) {
      if (_modelReady[spec.fileName] == true) total += spec.sizeMB / 1024.0;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final isCloud = _mode == AgentMode.cloud;
    final active = ModelRegistry.defaultForDevice(_stats['ramGB'] as int?);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.canPop(context)
                    ? Navigator.pop(context)
                    : null,
              ),
              title: Text(
                'Settings',
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
                padding: const EdgeInsets.only(top: 6, bottom: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader('AGENT MODE'),
                    _modeToggle(isCloud),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Text(
                        isCloud
                            ? 'Using Gemini via your API key. Switch to Local to run entirely on-device.'
                            : 'Running entirely on-device. Switch to Cloud to use a Gemini API key for stronger tool calling.',
                        style: GoogleFonts.interTight(
                          fontSize: 11.5,
                          height: 1.45,
                          color: AppTheme.muted,
                        ),
                      ),
                    ),
                    const SectionHeader('ACTIVE MODEL'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: active.displayName,
                        subtitle: active.supportsVision
                            ? 'Vision-capable · default for this device'
                            : 'Text · default for this device',
                        trailing: Text(
                          active.sizeLabel,
                          style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5, color: AppTheme.ink2),
                        ),
                      ),
                      SettingsCell(
                        title: 'Inference engine',
                        subtitle: 'MediaPipe · GPU delegate',
                        trailing: Text(
                          'GPU',
                          style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5, color: AppTheme.ink2),
                        ),
                      ),
                      SettingsCell(
                        title: 'Manage models',
                        subtitle:
                            '${_readyCount()} downloaded · ${_totalGB().toStringAsFixed(1)} GB total',
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.muted, size: 22),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const HomeScreen()),
                        ),
                      ),
                    ]),
                    if (isCloud) ...[
                      const SectionHeader('API KEY'),
                      SettingsGroup(children: [
                        SettingsCell(
                          isFirst: true,
                          title: 'Gemini API key',
                          subtitle: _apiKeyMasked ?? 'Not set — tap to add',
                          trailing: const Icon(Icons.chevron_right_rounded,
                              color: AppTheme.muted, size: 22),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const ApiKeySetupScreen(),
                            ));
                            _loadData();
                          },
                        ),
                      ]),
                    ],
                    const SectionHeader('BEHAVIOR'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'Confirm before actions',
                        subtitle:
                            'Ask before file edits, app launches, settings changes',
                        trailing: DesignSwitch(
                          value: _confirmActions,
                          onChanged: (v) => setState(() => _confirmActions = v),
                        ),
                      ),
                      SettingsCell(
                        title: 'Stream tokens',
                        subtitle: 'Show response as it generates',
                        trailing: DesignSwitch(
                          value: _streamTokens,
                          onChanged: (v) => setState(() => _streamTokens = v),
                        ),
                      ),
                      SettingsCell(
                        title: 'Save chat history',
                        subtitle: 'Stored locally · never uploaded',
                        trailing: DesignSwitch(
                          value: _saveHistory,
                          onChanged: (v) => setState(() => _saveHistory = v),
                        ),
                      ),
                    ]),
                    const SectionHeader('ABOUT'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'Version',
                        trailing: Text(
                          '0.4.2 · build 217',
                          style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5, color: AppTheme.ink2),
                        ),
                      ),
                      SettingsCell(
                        title: 'Source on GitHub',
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.muted, size: 22),
                        onTap: () => launchUrl(
                          Uri.parse(
                              'https://github.com/shantoshdurai/local-agent'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeToggle(bool isCloud) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(child: _toggleBtn(label: 'LOCAL', icon: Icons.smartphone_outlined, selected: !isCloud, onTap: () => _switchMode(AgentMode.local))),
          Expanded(child: _toggleBtn(label: 'CLOUD', icon: Icons.cloud_outlined, selected: isCloud, onTap: () => _switchMode(AgentMode.cloud))),
        ],
      ),
    );
  }

  Widget _toggleBtn({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? AppTheme.ink : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 12, color: selected ? AppTheme.bg : AppTheme.ink2),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: selected ? AppTheme.bg : AppTheme.ink2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
