import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_mode.dart';
import '../services/agent_service.dart' show kCloudModelSentinel;
import '../services/llm/provider_config.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'home_screen.dart';
import 'splash_screen.dart';

/// API-first onboarding/settings screen.
///
/// The pitch here is "no download, works in ten seconds". Local inference is
/// still one tap away at the bottom, but it is no longer the default path.
class ProviderSetupScreen extends StatefulWidget {
  final bool fromOnboarding;
  const ProviderSetupScreen({super.key, this.fromOnboarding = false});

  @override
  State<ProviderSetupScreen> createState() => _ProviderSetupScreenState();
}

class _ProviderSetupScreenState extends State<ProviderSetupScreen> {
  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _baseCtrl = TextEditingController();

  LlmProvider? _selected;
  bool _busy = false;
  bool _loading = true;
  bool _obscure = true;
  bool _testing = false;
  bool _showProviders = false;
  int _demoRemaining = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _baseCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final current = await ProviderStore.readProvider();
    final remaining = await ProviderStore.demoRemainingToday();
    if (!mounted) return;
    setState(() {
      _demoRemaining = remaining;
      _loading = false;
    });
    if (current != LlmProvider.local) {
      await _select(current);
    }
  }

  Future<void> _select(LlmProvider provider) async {
    // Every provider, Gemini included, uses the same inline editor so no
    // provider gets a special animated flow.
    final key = await ProviderStore.readKey(provider);
    final model = await ProviderStore.readModel(provider);
    final base = await ProviderStore.readBaseUrl(provider);
    if (!mounted) return;
    setState(() {
      _selected = provider;
      _error = null;
      _keyCtrl.text = key ?? '';
      _modelCtrl.text = model;
      _baseCtrl.text = base ?? '';
    });
  }

  Future<void> _startDemo() async {
    if (_demoRemaining == 0) {
      setState(() => _error = 'The shared key is used up for today. '
          'Add your own key — it takes a minute.');
      return;
    }
    setState(() => _busy = true);
    final provider = ProviderStore.freeProvider;
    await ProviderStore.writeProvider(provider);
    // Clear any user key so resolve() falls back to the shared key.
    await ProviderStore.writeKey(provider, null);
    if (!mounted) return;
    await _finish();
  }

  /// Verifies the key against `GET /models` and lets the user pick from the
  /// models this key can actually use.
  ///
  /// This exists because provider catalogues drift: the Groq free tier, for
  /// example, answers 403 for several model ids that appear in every tutorial.
  /// Listing the account's real models turns that failure into a picker.
  Future<void> _testConnection() async {
    final provider = _selected;
    if (provider == null) return;
    final spec = kProviderSpecs[provider]!;
    final key = _keyCtrl.text.trim();
    final base = _baseCtrl.text.trim().isEmpty
        ? spec.baseUrl
        : _baseCtrl.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Paste a key first.');
      return;
    }
    if (base.isEmpty) {
      setState(() => _error = 'Enter the endpoint base URL.');
      return;
    }

    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/models');
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $key'},
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;

      if (response.statusCode != 200) {
        final body = response.body.trim();
        setState(() {
          _testing = false;
          _error = 'Key check failed (${response.statusCode}). '
              '${body.length > 160 ? '${body.substring(0, 160)}…' : body}';
        });
        return;
      }

      final decoded = jsonDecode(response.body);
      final ids = <String>[];
      if (decoded is Map && decoded['data'] is List) {
        for (final entry in decoded['data'] as List) {
          if (entry is Map && entry['id'] != null) {
            final id = entry['id'].toString();
            final lower = id.toLowerCase();
            // Audio/guard/embedding models cannot do chat + tools.
            if (lower.contains('whisper') ||
                lower.contains('guard') ||
                lower.contains('orpheus') ||
                lower.contains('tts') ||
                lower.contains('embed')) {
              continue;
            }
            ids.add(id);
          }
        }
      }

      setState(() => _testing = false);
      if (ids.isEmpty) {
        setState(() =>
            _error = 'Connected, but this key lists no chat models.');
        return;
      }
      await _showModelPicker(spec.label, ids);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = 'Could not reach ${spec.label}: $e';
      });
    }
  }

  Future<void> _showModelPicker(String label, List<String> ids) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$label models',
                      style: GoogleFonts.interTight(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                  Text(
                    '${ids.length}',
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 12, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
            Text(
              'Tap one to use it for chat and tools.',
              style: GoogleFonts.interTight(
                  fontSize: 11.5, color: AppTheme.muted),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: ids.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  title: Text(
                    ids[i],
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12.5,
                      color: AppTheme.ink,
                    ),
                  ),
                  trailing: ids[i] == _modelCtrl.text
                      ? Icon(Icons.check_rounded,
                          size: 18, color: AppTheme.ink)
                      : null,
                  onTap: () => Navigator.pop(ctx, ids[i]),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _modelCtrl.text = picked);
    }
  }

  Future<void> _save() async {
    final provider = _selected;
    if (provider == null) return;
    final key = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final base = _baseCtrl.text.trim();

    if (key.isEmpty && !(provider == LlmProvider.groq && ProviderStore.hasDemoKey)) {
      setState(() => _error = 'Paste your ${kProviderSpecs[provider]!.label} '
          'API key first.');
      return;
    }
    if (provider == LlmProvider.custom && base.isEmpty) {
      setState(() => _error = 'Enter the base URL of your endpoint, '
          'e.g. https://openrouter.ai/api/v1');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    await ProviderStore.writeKey(provider, key.isEmpty ? null : key);
    await ProviderStore.writeModel(provider, model);
    if (provider == LlmProvider.custom) {
      await ProviderStore.writeBaseUrl(provider, base);
    }
    await ProviderStore.writeProvider(provider);
    if (!mounted) return;
    await _finish();
  }

  Future<void> _finish() async {
    if (widget.fromOnboarding) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kOnboardingSeenPref, true);
    }
    if (!mounted) return;
    if (widget.fromOnboarding) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) =>
                const SplashScreen(modelFileName: kCloudModelSentinel)),
        (_) => false,
      );
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _useLocal() async {
    await ProviderStore.writeProvider(LlmProvider.local);
    if (!mounted) return;
    if (widget.fromOnboarding) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kOnboardingSeenPref, true);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    } else {
      Navigator.pop(context, true);
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
                onPressed: () => Navigator.canPop(context)
                    ? Navigator.pop(context)
                    : _useLocal(),
              ),
              title: Text(
                'AI provider',
                style: GoogleFonts.interTight(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  color: AppTheme.ink,
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? Center(
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
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                      children: [
                        Text(
                          'Answers in seconds.\nNo model download.',
                          style: GoogleFonts.interTight(
                            fontSize: 26,
                            height: 1.14,
                            letterSpacing: -0.9,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Cloud models are far better at actually using tools — '
                          'calling, messaging, opening apps, searching. Your key '
                          'stays on this device and is sent only to the '
                          'provider you pick.',
                          style: GoogleFonts.interTight(
                            fontSize: 13,
                            height: 1.5,
                            color: AppTheme.ink2,
                          ),
                        ),
                        if (ProviderStore.hasDemoKey) ...[
                          const SizedBox(height: 20),
                          _demoCard(),
                        ],
                        const SizedBox(height: 20),
                        if (!widget.fromOnboarding || _showProviders) ...[
                          const Eyebrow('PROVIDERS'),
                          const SizedBox(height: 10),
                          ...LlmProvider.values
                              .where((p) =>
                                  p != LlmProvider.local &&
                                  p != LlmProvider.gemini &&
                                  kProviderSpecs.containsKey(p))
                              .map((p) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _providerTile(p),
                                  )),
                          if (_selected != null) _editor(),
                        ] else ...[
                          TextButton(
                            onPressed: () =>
                                setState(() => _showProviders = true),
                            child: Text(
                              'Use my own API key',
                              style: GoogleFonts.interTight(
                                fontSize: 12.5,
                                color: AppTheme.muted,
                                decoration: TextDecoration.underline,
                                decorationColor: AppTheme.muted2,
                              ),
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: GoogleFonts.interTight(
                              fontSize: 12.5,
                              height: 1.45,
                              color: AppTheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 26),
                        TextButton(
                          onPressed: _useLocal,
                          child: Text(
                            'Prefer everything on-device? Use a local model',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.interTight(
                              fontSize: 12.5,
                              color: AppTheme.muted,
                              decoration: TextDecoration.underline,
                              decorationColor: AppTheme.muted2,
                            ),
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

  Widget _demoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Try it free',
                  style: GoogleFonts.interTight(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              Pill(_demoRemaining < 0 ? 'FREE' : 'DEMO KEY',
                  style: PillStyle.solid),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _demoRemaining < 0
                ? 'Free while testing — unlimited messages. No signup. Add your '
                    'own key anytime.'
                : '$_demoRemaining of ${ProviderStore.demoDailyLimit} messages '
                    'left today on the shared key. No signup. Add your own key '
                    'later for unlimited use.',
            style: GoogleFonts.interTight(
              fontSize: 12,
              height: 1.5,
              color: AppTheme.ink2,
            ),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            onPressed: _busy ? null : _startDemo,
            label: 'Start free',
            icon: Icons.bolt_rounded,
            isLoading: _busy,
          ),
        ],
      ),
    );
  }

  Widget _providerTile(LlmProvider provider) {
    final spec = kProviderSpecs[provider]!;
    final selected = _selected == provider;
    return DesignCard(
      selected: selected,
      padding: const EdgeInsets.all(14),
      onTap: _busy ? null : () => _select(provider),
      child: Row(
        children: [
          Icon(
            provider == LlmProvider.gemini
                ? Icons.auto_awesome_rounded
                : Icons.bolt_rounded,
            size: 18,
            color: selected ? AppTheme.ink : AppTheme.ink2,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.label,
                  style: GoogleFonts.interTight(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  spec.tagline,
                  style: GoogleFonts.interTight(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppTheme.ink2,
                  ),
                ),
              ],
            ),
          ),
          if (provider == LlmProvider.groq && ProviderStore.hasDemoKey)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Pill('FREE', style: PillStyle.success),
            ),
          Icon(
            selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
            size: 18,
            color: selected ? AppTheme.ink : AppTheme.muted,
          ),
        ],
      ),
    );
  }

  Widget _editor() {
    final spec = kProviderSpecs[_selected]!;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${spec.label} setup',
              style: GoogleFonts.interTight(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Get a key at ${spec.consoleUrl}',
              style: GoogleFonts.interTight(
                  fontSize: 11, color: AppTheme.muted),
            ),
            const SizedBox(height: 14),
            _field(
              controller: _keyCtrl,
              hint: spec.keyHint,
              label: 'API KEY',
              obscure: _obscure,
              trailing: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 18,
                  color: AppTheme.muted,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            const SizedBox(height: 10),
            _field(
              controller: _modelCtrl,
              hint: spec.defaultModel,
              label: 'MODEL',
              trailing: IconButton(
                icon: Icon(Icons.content_paste_rounded,
                    size: 16, color: AppTheme.muted),
                tooltip: 'Paste model id',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = data?.text?.trim() ?? '';
                  if (text.isNotEmpty) _modelCtrl.text = text;
                },
              ),
            ),
            if (_selected == LlmProvider.custom) ...[
              const SizedBox(height: 10),
              _field(
                controller: _baseCtrl,
                hint: 'https://openrouter.ai/api/v1',
                label: 'BASE URL',
              ),
            ],
            const SizedBox(height: 14),
            if (_selected != LlmProvider.gemini) ...[
              SecondaryButton(
                onPressed: _busy || _testing ? null : _testConnection,
                label: _testing ? 'Testing…' : 'Test key & list models',
              ),
              const SizedBox(height: 8),
            ],
            PrimaryButton(
              onPressed: _busy ? null : _save,
              label: 'Save and continue',
              isLoading: _busy,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required String label,
    bool obscure = false,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 9.5,
            letterSpacing: 1.2,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.border),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  style: GoogleFonts.interTight(
                      fontSize: 13, color: AppTheme.ink),
                  cursorColor: AppTheme.ink,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: GoogleFonts.interTight(
                        fontSize: 13, color: AppTheme.muted2),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ],
    );
  }
}
