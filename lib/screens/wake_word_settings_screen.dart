import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/ai_apps_service.dart';
import '../services/assistant_router_service.dart';
import '../services/wake_word_launcher_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

class WakeWordSettingsScreen extends StatefulWidget {
  const WakeWordSettingsScreen({super.key});

  @override
  State<WakeWordSettingsScreen> createState() => _WakeWordSettingsScreenState();
}

class _WakeWordSettingsScreenState extends State<WakeWordSettingsScreen>
    with WidgetsBindingObserver {
  final WakeWordLauncherService _launcherService = WakeWordLauncherService();
  final AssistantRouterService _assistantRouter = AssistantRouterService();
  final AiAppsService _aiAppsService = AiAppsService();

  List<WakeWordAppBinding> _bindings = [];
  List<DiscoveredAiApp> _aiApps = [];
  List<Map<String, String>> _allPhoneApps = [];
  bool _loading = true;

  // Permissions state
  bool _micGranted = false;
  bool _overlayGranted = false;
  bool _batteryIgnored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      _scanApps();
    }
  }

  Future<void> _refreshAll() async {
    setState(() => _loading = true);
    await Future.wait([
      _loadBindings(),
      _checkPermissions(),
      _scanApps(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadBindings() async {
    final list = await _launcherService.getBindings();
    if (!mounted) return;
    setState(() => _bindings = list);
  }

  Future<void> _checkPermissions() async {
    final mic = await Permission.microphone.isGranted;
    final overlay = await _assistantRouter.isOverlayPermissionGranted();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() {
      _micGranted = mic;
      _overlayGranted = overlay;
      _batteryIgnored = battery;
    });
  }

  Future<void> _scanApps() async {
    final ai = await _aiAppsService.scanInstalledAiApps();
    final phone = await _launcherService.getSelectableApps();
    if (!mounted) return;
    setState(() {
      _aiApps = ai;
      _allPhoneApps = phone;
    });
  }

  /// Interactive App Picker Dialog: asks the user which app to launch for a wake word.
  void _openAppPickerDialog({
    required String wakeWordTitle,
    required Function(String packageName, String appName) onSelected,
  }) {
    String searchQuery = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final filteredApps = _allPhoneApps.where((app) {
            final name = app['name']?.toLowerCase() ?? '';
            final pkg = app['packageName']?.toLowerCase() ?? '';
            return name.contains(searchQuery.toLowerCase()) ||
                pkg.contains(searchQuery.toLowerCase());
          }).toList();

          return DraggableScrollableSheet(
            initialChildSize: 0.8,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollController) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 14),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    'Pick App for "$wakeWordTitle"',
                    style: GoogleFonts.interTight(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'When you speak this wake word, this app will launch automatically on your phone.',
                    style: GoogleFonts.inter(fontSize: 12.5, color: AppTheme.muted),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    onChanged: (val) => setModalState(() => searchQuery = val),
                    style: GoogleFonts.inter(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search installed apps...',
                      hintStyle: GoogleFonts.inter(color: AppTheme.muted),
                      prefixIcon: const Icon(Icons.search, color: AppTheme.muted),
                      filled: true,
                      fillColor: AppTheme.bg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('FEATURED AI APPS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.muted,
                          letterSpacing: 0.8)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 42,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _aiApps.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final ai = _aiApps[idx];
                        return ActionChip(
                          backgroundColor: ai.isInstalled
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.04),
                          side: BorderSide(
                              color: ai.isInstalled ? Colors.white30 : Colors.white10),
                          label: Text(ai.name,
                              style: TextStyle(
                                  color: ai.isInstalled
                                      ? Colors.white
                                      : AppTheme.muted,
                                  fontSize: 12)),
                          avatar: Icon(
                            ai.isInstalled
                                ? Icons.check_circle_outline_rounded
                                : Icons.file_download_outlined,
                            size: 16,
                            color: ai.isInstalled ? AppTheme.success : AppTheme.muted,
                          ),
                          onPressed: () {
                            onSelected(ai.packageName, ai.name);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('ALL PHONE APPS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.muted,
                          letterSpacing: 0.8)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: filteredApps.isEmpty
                        ? Center(
                            child: Text(
                              _allPhoneApps.isEmpty
                                  ? 'No third-party apps discovered or run in simulator'
                                  : 'No matching apps found',
                              style: GoogleFonts.inter(color: AppTheme.muted),
                            ),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            itemCount: filteredApps.length,
                            separatorBuilder: (_, __) => const Divider(
                                height: 1, color: Colors.white10),
                            itemBuilder: (_, idx) {
                              final app = filteredApps[idx];
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.android,
                                      size: 20, color: Colors.white70),
                                ),
                                title: Text(app['name'] ?? '',
                                    style: GoogleFonts.inter(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500)),
                                subtitle: Text(app['packageName'] ?? '',
                                    style: GoogleFonts.jetBrainsMono(
                                        fontSize: 10.5, color: AppTheme.muted)),
                                trailing: const Icon(Icons.chevron_right_rounded,
                                    size: 18, color: AppTheme.muted),
                                onTap: () {
                                  onSelected(app['packageName']!, app['name']!);
                                  Navigator.pop(ctx);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAddCustomWakeWordDialog() {
    final phraseController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('New Wake Word',
            style: GoogleFonts.interTight(
                color: Colors.white, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What phrase do you want to say?',
                style: GoogleFonts.inter(fontSize: 13, color: AppTheme.ink2)),
            const SizedBox(height: 8),
            TextField(
              controller: phraseController,
              style: GoogleFonts.inter(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g. Hey Notes, Open Scanner',
                hintStyle: GoogleFonts.inter(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.inter(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () {
              final phrase = phraseController.text.trim();
              if (phrase.isEmpty) return;
              Navigator.pop(ctx);
              _openAppPickerDialog(
                wakeWordTitle: phrase,
                onSelected: (pkg, appName) async {
                  final newBinding = WakeWordAppBinding(
                    id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                    wakeWord: phrase,
                    packageName: pkg,
                    appName: appName,
                    isEnabled: true,
                  );
                  await _launcherService.setBinding(newBinding);
                  _loadBindings();
                },
              );
            },
            child: Text('Next: Choose App',
                style: GoogleFonts.inter(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final jarvisBinding = _bindings.firstWhere(
      (b) => b.id == 'jarvis',
      orElse: () => WakeWordAppBinding(
        id: 'jarvis',
        wakeWord: 'Hey Jarvis',
        packageName: 'com.openai.chatgpt',
        appName: 'ChatGPT',
      ),
    );

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(
                'Wake Word App Launchers',
                style: GoogleFonts.interTight(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.ink,
                ),
              ),
              trailing: HeaderIconButton(
                icon: Icons.add_rounded,
                onPressed: _showAddCustomWakeWordDialog,
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),

                          // --- HERO: DEFAULT JARVIS TRIGGER ---
                          const SectionHeader('DEFAULT WAKE WORD (HEY JARVIS)'),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.white.withValues(alpha: 0.08),
                                  AppTheme.surface
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.bolt_rounded,
                                          color: Colors.white, size: 22),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '"Hey Jarvis"',
                                            style: GoogleFonts.inter(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Launches: ${jarvisBinding.appName}',
                                            style: GoogleFonts.inter(
                                              fontSize: 13,
                                              color: AppTheme.ink2,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(
                                            color: Colors.white38),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 6),
                                      ),
                                      onPressed: () {
                                        _openAppPickerDialog(
                                          wakeWordTitle: 'Hey Jarvis',
                                          onSelected: (pkg, appName) async {
                                            await _launcherService
                                                .setJarvisTargetApp(
                                                    packageName: pkg,
                                                    appName: appName);
                                            _loadBindings();
                                          },
                                        );
                                      },
                                      child: const Text('Change App'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Hold the power button or say "Hey Jarvis" to instantly open ${jarvisBinding.appName} on your phone without touching anything.',
                                  style: GoogleFonts.inter(
                                      fontSize: 12, color: AppTheme.muted),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),

                          // --- WAKE WORD APP BINDINGS LIST ---
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const SectionHeader('WAKE WORD → APP MAPPINGS'),
                              TextButton.icon(
                                icon: const Icon(Icons.add,
                                    size: 16, color: Colors.white70),
                                label: Text('Add Word',
                                    style: GoogleFonts.inter(
                                        fontSize: 12, color: Colors.white70)),
                                onPressed: _showAddCustomWakeWordDialog,
                              ),
                            ],
                          ),
                          SettingsGroup(
                            children: _bindings.map((b) {
                              final isFirst = b == _bindings.first;
                              return SettingsCell(
                                isFirst: isFirst,
                                title: '"${b.wakeWord}"',
                                subtitle: 'Opens: ${b.appName}',
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                        side: const BorderSide(
                                            color: Colors.white12),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                      ),
                                      onPressed: () {
                                        _openAppPickerDialog(
                                          wakeWordTitle: b.wakeWord,
                                          onSelected: (pkg, appName) async {
                                            b.packageName = pkg;
                                            b.appName = appName;
                                            await _launcherService.setBinding(b);
                                            _loadBindings();
                                          },
                                        );
                                      },
                                      child: const Text('Change',
                                          style: TextStyle(fontSize: 11)),
                                    ),
                                    const SizedBox(width: 8),
                                    DesignSwitch(
                                      value: b.isEnabled,
                                      onChanged: (val) async {
                                        b.isEnabled = val;
                                        await _launcherService.setBinding(b);
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),

                          const SizedBox(height: 16),

                          // --- EXPERIMENTAL PERMISSIONS & SETUP ---
                          const SectionHeader('SYSTEM PERMISSIONS (REQUIRED)'),
                          SettingsGroup(children: [
                            SettingsCell(
                              isFirst: true,
                              title: 'Default Digital Assistant',
                              subtitle:
                                  'Hold power button or swipe corner to trigger voice',
                              trailing: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(color: Colors.white24),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                ),
                                onPressed: () async {
                                  final ok = await _assistantRouter
                                      .openAssistantSettings();
                                  if (!ok && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Go to Settings → Apps → Default Apps → Digital Assistant'),
                                      ),
                                    );
                                  }
                                },
                                child: const Text('Configure'),
                              ),
                            ),
                            SettingsCell(
                              title: 'Microphone Permission',
                              subtitle: _micGranted
                                  ? 'Granted · Listens for your wake words'
                                  : 'Required to hear your wake phrases',
                              trailing: _micGranted
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AppTheme.success, size: 22)
                                  : OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(
                                            color: Colors.white24),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                      ),
                                      onPressed: () async {
                                        final res = await Permission.microphone
                                            .request();
                                        if (res.isPermanentlyDenied) {
                                          openAppSettings();
                                        }
                                        _checkPermissions();
                                      },
                                      child: const Text('Grant'),
                                    ),
                            ),
                            SettingsCell(
                              title: 'Display Over Other Apps',
                              subtitle: _overlayGranted
                                  ? 'Granted · Can launch and minimize smoothly'
                                  : 'Required to open target apps over your screen',
                              trailing: _overlayGranted
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AppTheme.success, size: 22)
                                  : OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(
                                            color: Colors.white24),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                      ),
                                      onPressed: () async {
                                        await _assistantRouter
                                            .openOverlaySettings();
                                        _checkPermissions();
                                      },
                                      child: const Text('Enable'),
                                    ),
                            ),
                            SettingsCell(
                              title: 'Background Keep-Alive (Battery)',
                              subtitle: _batteryIgnored
                                  ? 'Unrestricted · Always ready to respond'
                                  : 'Prevent phone OS from killing background listener',
                              trailing: _batteryIgnored
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AppTheme.success, size: 22)
                                  : OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(
                                            color: Colors.white24),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                      ),
                                      onPressed: () async {
                                        await _assistantRouter
                                            .openBatteryOptimizationSettings();
                                        _checkPermissions();
                                      },
                                      child: const Text('Allow'),
                                    ),
                            ),
                          ]),

                          const SizedBox(height: 16),

                          // --- HOW IT WORKS GUIDE ---
                          const SectionHeader('HOW IT WORKS'),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _bullet(
                                    '1. No API keys needed',
                                    'This uses your existing phone apps (ChatGPT, Claude, Gemini, etc.) directly.'),
                                const SizedBox(height: 8),
                                _bullet('2. Power Button Hold',
                                    'Hold your power button to activate Local Agent listener.'),
                                const SizedBox(height: 8),
                                _bullet(
                                    '3. Speak your wake word',
                                    'Say "Hey Jarvis" or "Hey Claude", and the app immediately opens that target app on your screen!'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 30),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bullet(String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.arrow_right_rounded, color: Colors.white70, size: 20),
        const SizedBox(width: 6),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: GoogleFonts.inter(fontSize: 12.5, color: AppTheme.muted),
              children: [
                TextSpan(
                    text: '$title: ',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                TextSpan(text: desc),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
