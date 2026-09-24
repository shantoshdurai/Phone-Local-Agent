import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/agent/agent_service.dart';
import '../services/local/device_profile.dart';
import '../services/local/inference_settings.dart';
import '../services/local/local_model.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// Generation settings for the loaded on-device model.
class ModelSettingsScreen extends StatefulWidget {
  const ModelSettingsScreen({super.key});

  @override
  State<ModelSettingsScreen> createState() => _ModelSettingsScreenState();
}

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  final _agent = AgentService();
  LocalModel? _model;
  InferenceSettings? _saved;
  InferenceSettings? _edit;
  DeviceProfile? _device;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final device = await DeviceProfile.load();
    if (!mounted) return;
    setState(() {
      _device = device;
      _model = _agent.localModel;
      _saved = _agent.localSettings;
      _edit = _agent.localSettings;
    });
  }

  bool get _dirty => _edit != null && _saved != null && _edit!.toJson().toString() != _saved!.toJson().toString();

  Future<void> _apply() async {
    final edit = _edit;
    if (edit == null) return;
    final reload = _saved != null && edit.needsReloadComparedTo(_saved!);
    setState(() => _applying = true);
    try {
      await _agent.applyLocalSettings(edit);
      if (!mounted) return;
      setState(() => _saved = edit);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reload ? 'Model reloaded with the new settings.' : 'Saved. Applies to your next message.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AgentService.friendlyError(e)), behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _reset() {
    final model = _model;
    if (model == null) return;
    setState(() => _edit = InferenceSettings.defaultsFor(model, _device));
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final s = _edit;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              leading: HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: () => Navigator.maybePop(context)),
              title: Text('Model settings',
                  style: GoogleFonts.interTight(
                      fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink)),
            ),
            Expanded(
              child: model == null || s == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Load an on-device model to change its settings.',
                            textAlign: TextAlign.center, style: GoogleFonts.interTight(color: AppTheme.ink2)),
                      ),
                    )
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                      children: [
                        Text(model.name,
                            style: GoogleFonts.interTight(
                                fontSize: 20, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                        const SizedBox(height: 4),
                        Text('Settings are saved for this model only.',
                            style: GoogleFonts.interTight(fontSize: 12.5, color: AppTheme.muted)),
                        const SizedBox(height: 12),
                        const SectionHeader('GENERATION'),
                        _slider(
                          icon: Icons.tune_rounded,
                          title: 'Temperature',
                          hint: 'Lower is more focused and predictable, higher is more creative.',
                          value: s.temperature,
                          min: 0,
                          max: 2,
                          divisions: 40,
                          label: s.temperature.toStringAsFixed(2),
                          left: 'Precise',
                          right: 'Creative',
                          onChanged: (v) => setState(() => _edit = s.copyWith(temperature: v)),
                        ),
                        _slider(
                          icon: Icons.filter_alt_outlined,
                          title: 'Top K',
                          hint: 'Only the K most likely next words are considered. 0 turns it off.',
                          value: s.topK.toDouble(),
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '${s.topK}',
                          onChanged: (v) => setState(() => _edit = s.copyWith(topK: v.round())),
                        ),
                        _slider(
                          icon: Icons.track_changes_rounded,
                          title: 'Top P',
                          hint: 'Considers the likeliest words that add up to this probability.',
                          value: s.topP,
                          min: 0.05,
                          max: 1,
                          divisions: 19,
                          label: s.topP.toStringAsFixed(2),
                          onChanged: (v) => setState(() => _edit = s.copyWith(topP: v)),
                        ),
                        _slider(
                          icon: Icons.low_priority_rounded,
                          title: 'Min P',
                          hint: 'Drops words much less likely than the best one. 0 turns it off.',
                          value: s.minP,
                          min: 0,
                          max: 0.3,
                          divisions: 30,
                          label: s.minP.toStringAsFixed(2),
                          onChanged: (v) => setState(() => _edit = s.copyWith(minP: v)),
                        ),
                        _slider(
                          icon: Icons.repeat_rounded,
                          title: 'Repetition penalty',
                          hint: 'Raise it if the model repeats itself.',
                          value: s.repeatPenalty,
                          min: 1,
                          max: 1.5,
                          divisions: 50,
                          label: s.repeatPenalty.toStringAsFixed(2),
                          onChanged: (v) => setState(() => _edit = s.copyWith(repeatPenalty: v)),
                        ),
                        _slider(
                          icon: Icons.format_list_numbered_rounded,
                          title: 'Max reply length',
                          hint: 'Longest reply in tokens (about ¾ of a word each).',
                          value: s.maxTokens.toDouble(),
                          min: 128,
                          max: 4096,
                          divisions: 31,
                          label: '${s.maxTokens}',
                          onChanged: (v) => setState(() => _edit = s.copyWith(maxTokens: (v / 128).round() * 128)),
                        ),
                        if (model.supportsThinking)
                          _switch(
                            title: 'Think before answering',
                            subtitle: 'Better answers to hard questions, but much slower on a phone.',
                            value: s.thinking,
                            onChanged: (v) => setState(() => _edit = s.copyWith(thinking: v)),
                          ),
                        const SectionHeader('PERFORMANCE (RELOADS THE MODEL)'),
                        _slider(
                          icon: Icons.memory_rounded,
                          title: 'Context size',
                          hint: 'How much of the conversation the model remembers. Bigger uses more RAM '
                              '(~${model.ramNeededGB(contextTokens: s.contextSize).toStringAsFixed(1)} GB now) '
                              'and slows the first reply.',
                          value: s.contextSize.toDouble(),
                          min: 1024,
                          max: 16384,
                          divisions: 15,
                          label: '${s.contextSize}',
                          onChanged: (v) => setState(() => _edit = s.copyWith(contextSize: (v / 1024).round() * 1024)),
                        ),
                        _slider(
                          icon: Icons.developer_board_rounded,
                          title: 'CPU threads',
                          hint: 'Auto uses the phone\'s fast cores. Try 2 or 4 if replies feel slow.',
                          value: s.threads.toDouble(),
                          min: 0,
                          max: 8,
                          divisions: 8,
                          label: s.threads == 0 ? 'Auto (${_device?.recommendedThreads ?? 4})' : '${s.threads}',
                          onChanged: (v) => setState(() => _edit = s.copyWith(threads: v.round())),
                        ),
                        _switch(
                          title: 'Use GPU (experimental)',
                          subtitle: 'Can be faster on Snapdragon (Adreno) phones. Most other phones are faster on the '
                              'CPU. Falls back to the CPU automatically if it fails.',
                          value: s.useGpu,
                          onChanged: (v) => setState(() => _edit = s.copyWith(useGpu: v)),
                        ),
                        const SizedBox(height: 20),
                        PrimaryButton(
                          onPressed: _dirty && !_applying ? _apply : null,
                          isLoading: _applying,
                          label: _dirty && _saved != null && s.needsReloadComparedTo(_saved!)
                              ? 'Save and reload model'
                              : 'Save',
                        ),
                        const SizedBox(height: 10),
                        SecondaryButton(onPressed: _applying ? null : _reset, label: 'Reset to defaults'),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider({
    required IconData icon,
    required String title,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    String? left,
    String? right,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: GoogleFonts.interTight(fontSize: 14.5, fontWeight: FontWeight.w600, color: AppTheme.ink)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.surface3,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(label,
                    style: GoogleFonts.jetBrainsMono(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.ink)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(hint, style: GoogleFonts.interTight(fontSize: 11.5, height: 1.4, color: AppTheme.muted)),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: _applying ? null : onChanged,
          ),
          if (left != null && right != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(left, style: GoogleFonts.jetBrainsMono(fontSize: 10, color: AppTheme.muted)),
                  Text(right, style: GoogleFonts.jetBrainsMono(fontSize: 10, color: AppTheme.muted)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _switch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.interTight(fontSize: 14.5, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                const SizedBox(height: 4),
                Text(subtitle, style: GoogleFonts.interTight(fontSize: 11.5, height: 1.4, color: AppTheme.muted)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DesignSwitch(value: value, onChanged: _applying ? null : onChanged),
        ],
      ),
    );
  }
}
