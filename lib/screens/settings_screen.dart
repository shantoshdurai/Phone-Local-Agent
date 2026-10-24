import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/agent_mode.dart';
import '../services/app_settings.dart';
import '../services/assistant_service.dart';
import '../services/device_capability.dart';
import '../services/device_service.dart';
import '../services/llm/provider_config.dart';
import '../services/memory_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'ai_apps_screen.dart';
import 'api_key_setup_screen.dart';
import 'assistant_setup_screen.dart';
import 'home_screen.dart';
import 'memory_screen.dart';
import 'provider_setup_screen.dart';
import 'package:url_launcher/url_launcher.dart';

/// 09 · Settings — agent mode toggle, active model, behavior switches, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  final DeviceService _deviceService = DeviceService();
  final ModelDownloaderService _downloader = ModelDownloaderService();

  Map<String, dynamic> _stats = {};
  final Map<String, bool> _modelReady = {};
  AgentMode _mode = AgentMode.local;
  LlmProvider _provider = LlmProvider.local;
  String? _apiKeyMasked;
  bool _isDefaultAssistant = false;
  int _memoryCount = 0;

  // Persisted in SharedPreferences via AppSettings; the previous versions were
  // State-only, so every visit reset them and "Confirm before actions" had no
  // implementation behind it at all.
  bool _confirmActions = AppSettings.confirmBeforeActions;
  bool _streamTokens = AppSettings.streamTokens;
  bool _saveHistory = AppSettings.saveHistory;
  ModelSpec _activeSpec = ModelRegistry.qwen2_5_1_5b;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the system "choose your assistant" dialog.
    if (state == AppLifecycleState.resumed) _refreshAssistant();
  }

  Future<void> _refreshAssistant() async {
    final isDefault = await AssistantService.instance.isDefaultAssistant();
    if (!mounted) return;
    setState(() => _isDefaultAssistant = isDefault);
  }

  Future<void> _loadData() async {
    final stats = await _deviceService.getQuickStats();
    final ready = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      ready[spec.fileName] = await _downloader.isModelDownloaded(spec.fileName);
    }
    final provider = await ProviderStore.readProvider();
    final mode =
        provider == LlmProvider.local ? AgentMode.local : AgentMode.cloud;
    final key = await ProviderStore.readKey(provider);
    final isAssistant = await AssistantService.instance.isDefaultAssistant();
    final memoryCount = await MemoryService.instance.count();
    final prefs = await SharedPreferences.getInstance();
    final lastModel = prefs.getString(kLastModelPref);
    final profile = DeviceCapability.cached ?? await DeviceCapability.scan();
    final active = (lastModel != null &&
            ready[lastModel] == true &&
            ModelRegistry.all.any((s) => s.fileName == lastModel))
        ? ModelRegistry.byFileName(lastModel)
        : DeviceCapability.recommendedSpec(profile) ??
            ModelRegistry.qwen2_5_1_5b;
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _modelReady
        ..clear()
        ..addAll(ready);
      _mode = mode;
      _provider = provider;
      _activeSpec = active;
      _isDefaultAssistant = isAssistant;
      _memoryCount = memoryCount;
      _confirmActions = AppSettings.confirmBeforeActions;
      _streamTokens = AppSettings.streamTokens;
      _saveHistory = AppSettings.saveHistory;
      _apiKeyMasked = (key != null && key.length > 4)
          ? '••••${key.substring(key.length - 4)}'
          : null;
    });
  }

  Future<void> _switchMode(AgentMode next) async {
    if (next == _mode) return;
    if (next == AgentMode.cloud) {
      // "Cloud" now means "pick a provider"; a bare mode flag cannot express
      // Groq vs DeepSeek vs Gemini.
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const ProviderSetupScreen()),
      );
      if (changed == true) await _loadData();
      return;
    }
    await ProviderStore.writeProvider(LlmProvider.local);
    if (!mounted) return;
    setState(() => _mode = next);
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
    final active = _activeSpec;
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
                            ? 'Using a cloud model with your own key. Switch to Local to run entirely on-device.'
                            : 'Running on-device. Switch to Cloud for stronger tool calling — no model download.',
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
                        title: _provider == LlmProvider.local
                            ? active.displayName
                            : 'Agent',
                        subtitle: _provider == LlmProvider.local
                            ? (active.supportsVision
                                ? 'Vision-capable · on-device'
                                : 'Text · on-device')
                            : 'Cloud model · private to you',
                        trailing: _provider == LlmProvider.local
                            ? Text(
                                active.sizeLabel,
                                style: GoogleFonts.jetBrainsMono(
                                    fontSize: 11.5, color: AppTheme.ink2),
                              )
                            : const Pill('API', style: PillStyle.outline),
                      ),
                      if (_provider == LlmProvider.local)
                        SettingsCell(
                          title: 'Inference engine',
                          subtitle: 'LiteRT-LM · on-device',
                          trailing: Text(
                            active.preferredBackend.name.toUpperCase(),
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
                    if (_provider == LlmProvider.gemini) ...[
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
                    const SectionHeader('THIS DEVICE'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'Memory',
                        subtitle: 'Used to pick a model that fits',
                        trailing: Text(
                          _stats['ramGB'] == null ? '—' : '${_stats['ramGB']} GB',
                          style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5, color: AppTheme.ink2),
                        ),
                      ),
                      SettingsCell(
                        title: 'Free storage',
                        subtitle: 'Models are stored on this device',
                        trailing: Text(
                          _stats['storageFree'] == null
                              ? '—'
                              : '${((_stats['storageFree'] as num) / 1024).toStringAsFixed(1)} GB',
                          style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5, color: AppTheme.ink2),
                        ),
                      ),
                    ]),
                    const SectionHeader('PERSONAL'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'AI provider',
                        subtitle: _provider == LlmProvider.local
                            ? 'On-device model · no network'
                            : 'Cloud · ${kProviderSpecs[_provider]!.label}',
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.muted, size: 22),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ProviderSetupScreen()),
                          );
                          _loadData();
                        },
                      ),
                      SettingsCell(
                        title: 'Memory',
                        subtitle: _memoryCount == 0
                            ? 'Nothing saved yet — say “my name is …”'
                            : '$_memoryCount '
                                '${_memoryCount == 1 ? "fact" : "facts"} remembered',
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.muted, size: 22),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const MemoryScreen()),
                          );
                          _loadData();
                        },
                      ),
                      SettingsCell(
                        title: 'Assistant setup',
                        subtitle: _isDefaultAssistant
                            ? 'Agent is your assistant'
                            : 'Permissions for the power-button gesture',
                        trailing: _isDefaultAssistant
                            ? const Pill('ACTIVE', style: PillStyle.success)
                            : const Icon(Icons.chevron_right_rounded,
                                color: AppTheme.muted, size: 22),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AssistantSetupScreen()),
                          );
                          _loadData();
                        },
                      ),
                      SettingsCell(
                        title: 'AI apps',
                        subtitle: 'Launch ChatGPT, Claude and others',
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: AppTheme.muted, size: 22),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AiAppsScreen()),
                        ),
                      ),
                    ]),
                    const SectionHeader('BEHAVIOR'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'Confirm before actions',
                        subtitle:
                            'Ask before calls, messages, uninstalls and calendar events',
                        trailing: DesignSwitch(
                          value: _confirmActions,
                          onChanged: (v) {
                            setState(() => _confirmActions = v);
                            AppSettings.setConfirmBeforeActions(v);
                          },
                        ),
                      ),
                      SettingsCell(
                        title: 'Stream tokens',
                        subtitle: 'Show response as it generates',
                        trailing: DesignSwitch(
                          value: _streamTokens,
                          onChanged: (v) {
                            setState(() => _streamTokens = v);
                            AppSettings.setStreamTokens(v);
                          },
                        ),
                      ),
                      SettingsCell(
                        title: 'Save chat history',
                        subtitle: 'Stored locally · never uploaded',
                        trailing: DesignSwitch(
                          value: _saveHistory,
                          onChanged: (v) {
                            setState(() => _saveHistory = v);
                            AppSettings.setSaveHistory(v);
                          },
                        ),
                      ),
                    ]),
                    const SectionHeader('ABOUT'),
                    SettingsGroup(children: [
                      SettingsCell(
                        isFirst: true,
                        title: 'Version',
                        trailing: Text(
                          '1.0.0 · build 1',
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
