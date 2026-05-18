import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import '../services/agent_mode.dart';
import 'home_screen.dart';

/// Reached either at the end of onboarding (fromOnboarding=true → continues to
/// HomeScreen on save) or from Settings (pops back on save). Validates the
/// key with a one-token generateContent ping before persisting.
class ApiKeySetupScreen extends StatefulWidget {
  final bool fromOnboarding;
  const ApiKeySetupScreen({super.key, this.fromOnboarding = false});

  @override
  State<ApiKeySetupScreen> createState() => _ApiKeySetupScreenState();
}

class _ApiKeySetupScreenState extends State<ApiKeySetupScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _existingMasked;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final existing = await AgentModeStore.readApiKey();
    if (existing != null && existing.length > 8 && mounted) {
      setState(() {
        _existingMasked =
            '${'•' * (existing.length - 4)}${existing.substring(existing.length - 4)}';
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _ctrl.text = text;
    setState(() => _error = null);
  }

  Future<void> _openConsole() async {
    final uri = Uri.parse('https://aistudio.google.com/apikey');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _save() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Paste a key first.');
      return;
    }
    if (!key.startsWith('AIza')) {
      setState(() =>
          _error = 'Google API keys usually start with “AIza”. Double-check?');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: key,
        generationConfig: GenerationConfig(maxOutputTokens: 4),
      );
      final res = await model.generateContent([Content.text('hi')]);
      // Any non-throwing response means the key authenticated. We don't care
      // about the actual generated text.
      res.text;

      await AgentModeStore.writeApiKey(key);
      // Make sure mode is cloud even if a stale local-mode value was set.
      await AgentModeStore.write(AgentMode.cloud);

      if (!mounted) return;
      final nav = Navigator.of(context);
      if (widget.fromOnboarding) {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      } else if (nav.canPop()) {
        nav.pop(true);
      } else {
        // Reached when main.dart routed straight here at boot (cloud mode
        // but no key on disk). There's nothing under us, so swap to home.
        nav.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('API key not valid') || msg.contains('400')) {
      return 'That key was rejected. Check you copied the full string from AI Studio.';
    }
    if (msg.contains('PERMISSION_DENIED') || msg.contains('403')) {
      return 'Key is valid but doesn’t have Generative Language API access. Enable it in AI Studio.';
    }
    if (msg.contains('SocketException') ||
        msg.contains('Failed host lookup') ||
        msg.contains('TimeoutException')) {
      return 'Couldn’t reach Google. Check your connection and try again.';
    }
    return 'Validation failed: $msg';
  }

  void _back() {
    final nav = Navigator.of(context);
    if (widget.fromOnboarding || !nav.canPop()) {
      // No route below us (boot route, or onboarding flow) — drop them at
      // Home rather than freezing on an unpoppable stack.
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    } else {
      nav.pop();
    }
  }

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
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: AppTheme.glassInk2),
                        onPressed: _busy ? null : _back,
                      ),
                      const Spacer(),
                      Text(
                        widget.fromOnboarding ? 'OPTIONAL · SKIPPABLE' : 'API KEY',
                        style: AppTextStyles.mono.copyWith(
                          color: AppTheme.glassMuted,
                          letterSpacing: 2.0,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ).animate().fadeIn(duration: 400.ms),
                  const SizedBox(height: 20),
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.glassMagenta.withValues(alpha: 0.15),
                      border: Border.all(
                        color: AppTheme.glassMagenta.withValues(alpha: 0.5),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.glassMagenta.withValues(alpha: 0.35),
                          blurRadius: 40,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.vpn_key_rounded,
                        color: AppTheme.glassMagenta, size: 32),
                  ).animate().scale(
                        duration: 600.ms,
                        curve: Curves.easeOutBack,
                      ),
                  const SizedBox(height: 24),
                  Text(
                    'Add your\nGemini API key',
                    style: AppTextStyles.heading.copyWith(
                      fontSize: 30,
                      color: AppTheme.glassInk,
                      height: 1.1,
                      letterSpacing: -1.0,
                    ),
                  ).animate().fadeIn(delay: 150.ms).moveY(begin: 12, end: 0),
                  const SizedBox(height: 12),
                  Text(
                    'Your key stays on your device. We send your messages straight to Google with this key — never through any server we run.',
                    style: AppTextStyles.body.copyWith(
                      color: AppTheme.glassInk2.withValues(alpha: 0.8),
                      fontSize: 14,
                    ),
                  ).animate().fadeIn(delay: 250.ms),
                  const SizedBox(height: 22),
                  GlassCard(
                    padding: const EdgeInsets.all(18),
                    borderRadius: BorderRadius.circular(20),
                    blur: 25,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'API KEY',
                          style: AppTextStyles.mono.copyWith(
                            color: AppTheme.glassMuted,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.glassBorder),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 14),
                              Icon(Icons.key_rounded,
                                  color: AppTheme.glassMuted, size: 18),
                              Expanded(
                                child: TextField(
                                  controller: _ctrl,
                                  focusNode: _focus,
                                  enabled: !_busy,
                                  obscureText: _obscure,
                                  style: AppTextStyles.body.copyWith(
                                    color: AppTheme.glassInk,
                                    fontSize: 14,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: _existingMasked ?? 'AIza...',
                                    hintStyle: AppTextStyles.body.copyWith(
                                      color: AppTheme.glassMuted,
                                      fontSize: 14,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 14),
                                  ),
                                  onChanged: (_) => setState(() => _error = null),
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: AppTheme.glassMuted,
                                  size: 18,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _miniAction(
                              icon: Icons.content_paste_rounded,
                              label: 'Paste',
                              onTap: _busy ? null : _paste,
                            ),
                            const SizedBox(width: 10),
                            _miniAction(
                              icon: Icons.open_in_new_rounded,
                              label: 'Get a key',
                              onTap: _busy ? null : _openConsole,
                            ),
                            const Spacer(),
                            if (_existingMasked != null && !_busy)
                              TextButton.icon(
                                icon: const Icon(Icons.delete_outline_rounded,
                                    size: 16, color: AppTheme.accentError),
                                label: Text(
                                  'Remove',
                                  style: AppTextStyles.small.copyWith(
                                    color: AppTheme.accentError,
                                    fontSize: 12,
                                  ),
                                ),
                                onPressed: () async {
                                  await AgentModeStore.clearApiKey();
                                  if (!mounted) return;
                                  setState(() {
                                    _existingMasked = null;
                                    _ctrl.clear();
                                  });
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ).animate().fadeIn(delay: 350.ms).moveY(begin: 12, end: 0),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.accentError.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppTheme.accentError.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              color: AppTheme.accentError, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: AppTextStyles.small.copyWith(
                                color: AppTheme.glassInk,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  GradientButton(
                    onPressed: _save,
                    isLoading: _busy,
                    label: 'VERIFY & SAVE',
                  ).animate().fadeIn(delay: 500.ms),
                  if (widget.fromOnboarding) ...[
                    const SizedBox(height: 12),
                    GhostButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              await AgentModeStore.write(AgentMode.local);
                              if (!context.mounted) return;
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(
                                    builder: (_) => const HomeScreen()),
                                (_) => false,
                              );
                            },
                      label: 'Use local model instead',
                    ).animate().fadeIn(delay: 600.ms),
                  ],
                  const SizedBox(height: 12),
                  Center(
                    child: GestureDetector(
                      onTap: _openConsole,
                      child: Text(
                        'Free tier: 1,500 requests/day · ai.google.dev',
                        style: AppTextStyles.small.copyWith(
                          color: AppTheme.glassMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ).animate().fadeIn(delay: 700.ms),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: AppTheme.glassAccent.withValues(alpha: 0.1),
            border: Border.all(
              color: AppTheme.glassAccent.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: AppTheme.glassAccent),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTextStyles.bodyStrong.copyWith(
                  color: AppTheme.glassAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
