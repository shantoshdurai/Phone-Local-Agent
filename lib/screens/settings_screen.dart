import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/launch.dart';
import '../services/agent/agent_service.dart';
import '../services/app_settings.dart';
import '../services/database_service.dart';
import '../services/utility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'model_picker_screen.dart';

const String kRepoUrl = 'https://github.com/shantoshdurai/Phone-Local-Agent';
const String kPrivacyUrl = '$kRepoUrl/blob/main/PRIVACY.md';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  final AgentService _agent = AgentService();

  bool _confirmActions = true;
  bool _instantCommands = true;
  bool _useGpu = false;
  bool _notificationAccess = false;
  CloudTarget? _cloud;
  LocalTarget? _local;
  String _version = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system "Notification access" screen.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    final confirm = await AppSettings.confirmActions();
    final instant = await AppSettings.instantCommands();
    final gpu = await AppSettings.useGpu();
    final notifications = await UtilityService().hasNotificationAccess();
    final cloud = await savedCloudTarget();
    final local = await savedLocalTarget();
    if (!mounted) return;
    setState(() {
      _version = '${info.version} (${info.buildNumber})';
      _confirmActions = confirm;
      _instantCommands = instant;
      _useGpu = gpu;
      _notificationAccess = notifications;
      _cloud = cloud;
      _local = local;
    });
  }

  Future<void> _switchMode(bool cloud) async {
    final current = _agent.target;
    if (cloud == (current?.isCloud ?? false)) return;
    if (cloud) {
      if (_cloud != null) {
        launchAgent(context, _cloud!);
      } else {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const ApiKeySetupScreen()));
        _load();
      }
    } else {
      if (_local != null) {
        launchAgent(context, _local!);
      } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ModelPickerScreen()));
      }
    }
  }

  Future<void> _setGpu(bool value) async {
    await AppSettings.setUseGpu(value);
    setState(() => _useGpu = value);
    final target = _agent.target;
    if (target is LocalTarget && mounted) {
      // Reload so the change takes effect now.
      launchAgent(context, target);
    }
  }

  Future<void> _clearChats() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Delete all chats?',
            style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
        content: Text('Every conversation on this phone will be erased.',
            style: GoogleFonts.interTight(color: AppTheme.ink2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.interTight(color: AppTheme.muted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete all',
                  style: GoogleFonts.interTight(color: AppTheme.error, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    await DatabaseService().clearAll();
    await _agent.startBlankSession();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All chats deleted.'), behavior: SnackBarBehavior.floating));
    }
  }

  Widget _chevron() => const Icon(Icons.chevron_right_rounded, color: AppTheme.muted, size: 22);

  @override
  Widget build(BuildContext context) {
    final target = _agent.target;
    final isCloud = target?.isCloud ?? false;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.maybePop(context)),
              title: Text('Settings',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
            ),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: 6, bottom: 28),
                children: [
                  const SectionHeader('WHERE THE AI RUNS'),
                  _modeToggle(isCloud),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Text(
                      isCloud
                          ? 'Messages go to ${_cloud?.config.preset.name ?? 'your provider'} using your key. '
                              'Switch to On-device to keep everything on your phone.'
                          : 'Everything stays on your phone. Switch to Cloud for faster, smarter answers with your own API key.',
                      style: GoogleFonts.interTight(fontSize: 11.5, height: 1.45, color: AppTheme.muted),
                    ),
                  ),
                  const SectionHeader('ON-DEVICE MODEL'),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: _local?.spec.displayName ?? 'No model downloaded',
                      subtitle: _local == null
                          ? 'Download one to use Local Agent offline'
                          : '${_local!.spec.sizeLabel} · ${_local!.spec.tier.toLowerCase()}',
                      trailing: _chevron(),
                      onTap: () async {
                        await Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const ModelPickerScreen()));
                        _load();
                      },
                    ),
                    SettingsCell(
                      title: 'Use GPU',
                      subtitle: 'Faster on many flagship phones. Turn off if the model crashes or freezes.',
                      trailing: DesignSwitch(value: _useGpu, onChanged: _setGpu),
                    ),
                  ]),
                  const SectionHeader('CLOUD MODEL'),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: _cloud == null ? 'Add an API key' : _cloud!.config.preset.name,
                      subtitle: _cloud == null
                          ? 'Gemini, Claude, OpenAI, Groq, OpenRouter or your own server'
                          : _cloud!.config.model,
                      trailing: _chevron(),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ApiKeySetupScreen(initialProvider: _cloud?.config.providerId)),
                        );
                        _load();
                      },
                    ),
                  ]),
                  const SectionHeader('BEHAVIOR'),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: 'Confirm before actions',
                      subtitle: 'Ask before calling, messaging, adding events or uninstalling apps',
                      trailing: DesignSwitch(
                        value: _confirmActions,
                        onChanged: (v) async {
                          await AppSettings.setConfirmActions(v);
                          setState(() => _confirmActions = v);
                        },
                      ),
                    ),
                    SettingsCell(
                      title: 'Instant commands',
                      subtitle: '"Flashlight on", "timer 5 min", "battery?" run instantly without the AI',
                      trailing: DesignSwitch(
                        value: _instantCommands,
                        onChanged: (v) async {
                          await AppSettings.setInstantCommands(v);
                          setState(() => _instantCommands = v);
                        },
                      ),
                    ),
                    SettingsCell(
                      title: 'Notification access',
                      subtitle: _notificationAccess
                          ? 'On — the agent can read your notifications when you ask'
                          : 'Off — needed for "read my notifications"',
                      trailing: _notificationAccess
                          ? const Pill('ON', style: PillStyle.success)
                          : _chevron(),
                      onTap: () => UtilityService().requestNotificationAccess(),
                    ),
                  ]),
                  const SectionHeader('DATA'),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: 'Delete all chats',
                      subtitle: 'Chats are stored only on this phone',
                      trailing: const Icon(Icons.delete_outline_rounded, color: AppTheme.muted, size: 20),
                      onTap: _clearChats,
                    ),
                  ]),
                  const SectionHeader('ABOUT'),
                  SettingsGroup(children: [
                    SettingsCell(
                      isFirst: true,
                      title: 'Version',
                      trailing: Text(_version,
                          style: GoogleFonts.jetBrainsMono(fontSize: 11.5, color: AppTheme.ink2)),
                    ),
                    SettingsCell(
                      title: 'Privacy policy',
                      trailing: _chevron(),
                      onTap: () => launchUrl(Uri.parse(kPrivacyUrl), mode: LaunchMode.externalApplication),
                    ),
                    SettingsCell(
                      title: 'Source code',
                      trailing: _chevron(),
                      onTap: () => launchUrl(Uri.parse(kRepoUrl), mode: LaunchMode.externalApplication),
                    ),
                  ]),
                ],
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
          Expanded(
            child: _toggleBtn(
                label: 'ON-DEVICE', icon: Icons.smartphone_outlined, selected: !isCloud, onTap: () => _switchMode(false)),
          ),
          Expanded(
            child: _toggleBtn(label: 'CLOUD', icon: Icons.cloud_outlined, selected: isCloud, onTap: () => _switchMode(true)),
          ),
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
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: selected ? AppTheme.bg : AppTheme.ink2),
              const SizedBox(width: 6),
              Text(label,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                    color: selected ? AppTheme.bg : AppTheme.ink2,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
