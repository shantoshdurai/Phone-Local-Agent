import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/launch.dart';
import '../services/agent/agent_types.dart';
import '../services/app_settings.dart';
import '../services/llm/llm_types.dart';
import '../services/llm/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'model_hub_screen.dart';

/// Bring-your-own-key setup for any supported cloud provider.
///
/// The key is verified by listing the provider's models — that works for
/// every key and costs no generation quota. (The old check sent a 4-token
/// Gemini 2.5 request, which always failed: thinking models return an empty
/// candidate at that limit and the old SDK crashed parsing it.)
class ApiKeySetupScreen extends StatefulWidget {
  final String? initialProvider;
  const ApiKeySetupScreen({super.key, this.initialProvider});

  @override
  State<ApiKeySetupScreen> createState() => _ApiKeySetupScreenState();
}

class _ApiKeySetupScreenState extends State<ApiKeySetupScreen> {
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

  late ProviderPreset _preset;
  String? _savedKeyMasked;
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _notice;

  /// Null until the key is verified.
  List<LlmModelInfo>? _models;
  String? _selectedModel;
  bool _manualModel = false;

  @override
  void initState() {
    super.initState();
    _preset = providerById(widget.initialProvider ?? (hostedCloudAvailable ? 'hosted' : 'gemini'));
    _loadSaved();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final key = await KeyStore.read(_preset.id);
    final config = await AppSettings.cloudConfig();
    if (!mounted) return;
    setState(() {
      _savedKeyMasked = key == null || key.length < 8 ? null : '••••••••${key.substring(key.length - 4)}';
      if (config != null && config.providerId == _preset.id) {
        _urlCtrl.text = config.baseUrl ?? _urlCtrl.text;
        _selectedModel = config.model;
        _modelCtrl.text = config.model;
      }
    });
  }

  void _selectProvider(ProviderPreset preset) {
    if (preset.id == _preset.id) return;
    setState(() {
      _preset = preset;
      _keyCtrl.clear();
      _models = null;
      _selectedModel = null;
      _modelCtrl.clear();
      _manualModel = false;
      _error = null;
      _notice = null;
      _savedKeyMasked = null;
    });
    _loadSaved();
  }

  Future<String?> _effectiveKey() async {
    final typed = _keyCtrl.text.trim();
    if (typed.isNotEmpty) return typed;
    return KeyStore.read(_preset.id);
  }

  String? _baseUrl() {
    if (_preset.kind != ProviderKind.custom) return null;
    var url = _urlCtrl.text.trim();
    if (url.isEmpty) return null;
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'http://$url';
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    final key = await _effectiveKey();
    if (_preset.keyRequired && (key == null || key.isEmpty)) {
      setState(() => _error = 'Paste your ${_preset.shortName} API key first.');
      return;
    }
    if (_preset.kind == ProviderKind.custom && _baseUrl() == null) {
      setState(() => _error = 'Enter your server\'s URL, e.g. http://192.168.1.10:11434/v1');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final client = createLlmClient(preset: _preset, apiKey: key ?? '', baseUrl: _baseUrl());
      final models = orderModelsForPicker(_preset, await client.listModels());
      if (!mounted) return;
      final current = _selectedModel;
      setState(() {
        _models = models;
        _selectedModel = (current != null && models.any((m) => m.id == current))
            ? current
            : pickDefaultModel(_preset, models);
        _manualModel = models.isEmpty;
        if (_manualModel) _modelCtrl.text = _selectedModel ?? '';
        _notice = models.isEmpty
            ? 'Key works, but the server didn\'t list its models. Type the model name below.'
            : 'Key verified. ${models.length} model${models.length == 1 ? '' : 's'} available.';
      });
    } on LlmException catch (e) {
      if (!mounted) return;
      setState(() {
        if (_preset.kind == ProviderKind.custom && e.kind == LlmErrorKind.notFound) {
          // Server has no /models endpoint; let the user name the model.
          _models = const [];
          _manualModel = true;
          _notice = 'This server doesn\'t list models. Type the model name below.';
        } else {
          _error = e.kind == LlmErrorKind.auth
              ? 'That key was rejected. Make sure you copied the whole key.'
              : e.userMessage;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Verification failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final model = (_manualModel ? _modelCtrl.text : _selectedModel ?? '').trim();
    if (model.isEmpty) {
      setState(() => _error = 'Choose a model.');
      return;
    }
    final key = await _effectiveKey();
    if (_preset.keyRequired && (key == null || key.isEmpty)) {
      setState(() => _error = 'Paste your API key first.');
      return;
    }
    final info = _models?.where((m) => m.id == model).firstOrNull;
    final config = CloudConfig(
      providerId: _preset.id,
      model: model,
      baseUrl: _baseUrl(),
      supportsImages: info?.supportsImages,
      supportsEffort: info?.supportsEffort,
      maxOutputTokens: info?.maxOutputTokens,
    );
    try {
      if (key != null && key.isNotEmpty) await KeyStore.write(_preset.id, key);
      await AppSettings.setCloudConfig(config);
      await AppSettings.setOnboardingSeen();
    } catch (e) {
      setState(() => _error = 'Couldn\'t save the key securely: $e');
      return;
    }
    if (mounted) launchAgent(context, CloudTarget(config));
  }

  Future<void> _removeKey() async {
    await KeyStore.delete(_preset.id);
    if (!mounted) return;
    setState(() {
      _savedKeyMasked = null;
      _models = null;
      _notice = 'Key removed from this phone.';
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    setState(() {
      _keyCtrl.text = text;
      _error = null;
      _models = null;
    });
  }

  void _back() {
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      resetTo(context, const ModelHubScreen());
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
              leading: HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: _busy ? null : _back),
              title: Text('Cloud model',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                physics: const BouncingScrollPhysics(),
                children: [
                  Text('Use your own API key',
                      style: GoogleFonts.interTight(
                          fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.8, color: AppTheme.ink)),
                  const SizedBox(height: 8),
                  Text(
                    'Faster and smarter than on-device models. Your key is encrypted on this phone and '
                    'messages go straight to the provider — never through a server we run.',
                    style: GoogleFonts.interTight(fontSize: 13.5, height: 1.5, color: AppTheme.ink2),
                  ),
                  const SizedBox(height: 22),
                  const Eyebrow('PROVIDER'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in availableProviders)
                        ChoiceChip(
                          label: Text(p.shortName),
                          selected: p.id == _preset.id,
                          onSelected: _busy ? null : (_) => _selectProvider(p),
                          labelStyle: GoogleFonts.interTight(
                            color: p.id == _preset.id ? AppTheme.onPrimary : AppTheme.ink,
                            fontWeight: FontWeight.w600,
                          ),
                          selectedColor: AppTheme.primary,
                          backgroundColor: AppTheme.surface,
                          side: BorderSide(color: AppTheme.border),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(_preset.tagline,
                      style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.muted, height: 1.4)),
                  const SizedBox(height: 22),
                  if (_preset.kind == ProviderKind.custom) ...[
                    const Eyebrow('SERVER URL'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _urlCtrl,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: GoogleFonts.jetBrainsMono(color: AppTheme.ink, fontSize: 13),
                      decoration: const InputDecoration(hintText: 'http://192.168.1.10:11434/v1'),
                      onChanged: (_) => setState(() => _models = null),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Ollama: http://<pc-ip>:11434/v1 · LM Studio: http://<pc-ip>:1234/v1. '
                      'Plain http is only safe on your own Wi-Fi.',
                      style: GoogleFonts.interTight(fontSize: 11.5, color: AppTheme.muted, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (_preset.kind == ProviderKind.hosted)
                    Text(
                      'Nothing to set up: messages go through the app\'s own server to Google Gemini. '
                      'Fair-use limits apply. For unlimited use or other models, add your own key.',
                      style: GoogleFonts.interTight(fontSize: 12.5, height: 1.45, color: AppTheme.ink2),
                    )
                  else ...[
                    Row(
                      children: [
                        Eyebrow(_preset.keyRequired ? 'API KEY' : 'API KEY (OPTIONAL)'),
                        const Spacer(),
                        if (_preset.keyUrl.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => launchUrl(Uri.parse(_preset.keyUrl), mode: LaunchMode.externalApplication),
                            icon: Icon(Icons.open_in_new_rounded, size: 14, color: AppTheme.ink2),
                            label: Text('Get a key',
                                style: GoogleFonts.interTight(color: AppTheme.ink2, fontSize: 12.5)),
                          ),
                      ],
                    ),
                    TextField(
                      controller: _keyCtrl,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: GoogleFonts.jetBrainsMono(color: AppTheme.ink, fontSize: 13),
                      onChanged: (_) => setState(() {
                        _error = null;
                        _models = null;
                      }),
                      decoration: InputDecoration(
                        hintText: _savedKeyMasked ?? _preset.keyHint,
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Paste',
                              icon: Icon(Icons.content_paste_rounded, size: 18, color: AppTheme.muted),
                              onPressed: _busy ? null : _paste,
                            ),
                            IconButton(
                              tooltip: _obscure ? 'Show' : 'Hide',
                              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  size: 18, color: AppTheme.muted),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_savedKeyMasked != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text('A key is saved on this phone. Leave the field empty to keep it.',
                                style: GoogleFonts.interTight(fontSize: 11.5, color: AppTheme.muted)),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _removeKey,
                            child: Text('Remove',
                                style: GoogleFonts.interTight(color: AppTheme.error, fontSize: 12)),
                          ),
                        ],
                      ),
                    ],
                  ],
                  if (_error != null) ...[const SizedBox(height: 14), _banner(_error!, isError: true)],
                  if (_notice != null && _error == null) ...[const SizedBox(height: 14), _banner(_notice!)],
                  const SizedBox(height: 18),
                  if (_models == null)
                    PrimaryButton(
                      onPressed: _busy ? null : _verify,
                      label: _preset.kind == ProviderKind.hosted ? 'Connect' : 'Verify key',
                      isLoading: _busy,
                    )
                  else ...[
                    const Eyebrow('MODEL'),
                    const SizedBox(height: 8),
                    if (_manualModel)
                      TextField(
                        controller: _modelCtrl,
                        autocorrect: false,
                        style: GoogleFonts.jetBrainsMono(color: AppTheme.ink, fontSize: 13),
                        decoration: const InputDecoration(hintText: 'e.g. llama3.2 or qwen3:8b'),
                      )
                    else
                      _modelDropdown(),
                    if (_models!.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => setState(() {
                            _manualModel = !_manualModel;
                            if (_manualModel) _modelCtrl.text = _selectedModel ?? '';
                          }),
                          child: Text(_manualModel ? 'Choose from the list' : 'Type a model name instead',
                              style: GoogleFonts.interTight(color: AppTheme.ink2, fontSize: 12.5)),
                        ),
                      ),
                    const SizedBox(height: 12),
                    PrimaryButton(onPressed: _busy ? null : _save, label: 'Save & start chatting'),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelDropdown() {
    final models = _models!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: models.any((m) => m.id == _selectedModel) ? _selectedModel : null,
          dropdownColor: AppTheme.surface2,
          hint: Text('Choose a model', style: GoogleFonts.interTight(color: AppTheme.muted)),
          items: [
            for (final m in models)
              DropdownMenuItem(
                value: m.id,
                child: Text(
                  m.displayName == m.id ? m.id : '${m.displayName}  (${m.id})',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 14),
                ),
              ),
          ],
          onChanged: (v) => setState(() => _selectedModel = v),
        ),
      ),
    );
  }

  Widget _banner(String text, {bool isError = false}) {
    final color = isError ? AppTheme.error : AppTheme.success;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
