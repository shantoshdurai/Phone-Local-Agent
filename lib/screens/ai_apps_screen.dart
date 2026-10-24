import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/ai_apps_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// Hub for the other AI apps on the phone.
///
/// Ported from the `experimental-ai-assistant` branch: people already have
/// ChatGPT/Claude/Gemini installed, and the assistant should hand off to them
/// rather than pretend it is the only app that can help.
class AiAppsScreen extends StatefulWidget {
  const AiAppsScreen({super.key});

  @override
  State<AiAppsScreen> createState() => _AiAppsScreenState();
}

class _AiAppsScreenState extends State<AiAppsScreen> {
  List<DiscoveredAiApp> _apps = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await AiAppsService.instance.discover();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  Future<void> _open(DiscoveredAiApp item) async {
    final ok = item.installed
        ? await AiAppsService.instance.launch(item.app)
        : await AiAppsService.instance.openStore(item.app);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${item.app.name}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
                'AI apps',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
              trailing: HeaderIconButton(
                icon: Icons.refresh_rounded,
                size: 18,
                onPressed: () async {
                  setState(() => _loading = true);
                  await _load();
                },
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: AppTheme.muted,
                        ),
                      ),
                    )
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
                      children: [
                        Text(
                          'Your other assistants',
                          style: GoogleFonts.interTight(
                            fontSize: 25,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.7,
                            color: AppTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Agent can hand a request to an app you already use. '
                          'Install one and it opens with a single tap — no API '
                          'key needed.',
                          style: GoogleFonts.interTight(
                            fontSize: 13,
                            height: 1.5,
                            color: AppTheme.ink2,
                          ),
                        ),
                        const SizedBox(height: 18),
                        ..._apps.map((item) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _appCard(item),
                            )),
                        const SizedBox(height: 8),
                        Text(
                          'Installed apps are detected locally. Nothing about '
                          'them leaves the phone.',
                          style: GoogleFonts.interTight(
                            fontSize: 11,
                            height: 1.5,
                            color: AppTheme.muted2,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appCard(DiscoveredAiApp item) {
    final app = item.app;
    return DesignCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            alignment: Alignment.center,
            child: Text(
              app.name.substring(0, 1),
              style: GoogleFonts.interTight(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppTheme.ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        app.name,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.interTight(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    if (item.installed) ...[
                      const SizedBox(width: 8),
                      const Pill('INSTALLED', style: PillStyle.success),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  app.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.interTight(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppTheme.ink2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => _open(item),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 40),
            ),
            child: Text(
              item.installed ? 'OPEN' : 'GET',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: AppTheme.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
