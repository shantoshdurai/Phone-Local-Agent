import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/launch.dart';
import '../services/agent/agent_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'api_key_setup_screen.dart';
import 'chat_screen.dart';
import 'model_hub_screen.dart';

/// Loads the chosen backend with visible progress, then opens the chat.
class SplashScreen extends StatefulWidget {
  final AgentTarget target;
  const SplashScreen({super.key, required this.target});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final AgentService _agent = AgentService();
  String? _error;
  String _stage = 'Starting';
  int _elapsed = 0;
  Timer? _ticker;
  StreamSubscription<AgentEvent>? _eventsSub;

  @override
  void initState() {
    super.initState();
    _eventsSub = _agent.events.listen((e) {
      if (e is AgentStatus && e.text.isNotEmpty && mounted) {
        setState(() => _stage = e.text.replaceAll('…', '').trim());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _eventsSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _elapsed = 0;
      _stage = widget.target.isCloud ? 'Connecting' : 'Loading ${widget.target.label}';
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    try {
      await _agent.activate(widget.target);
      if (!mounted) return;
      _ticker?.cancel();
      Navigator.of(context).pushReplacement(fadeRoute(const ChatScreen()));
    } catch (e) {
      _ticker?.cancel();
      if (mounted) setState(() => _error = AgentService.friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _error == null ? _progress() : _failure(),
          ),
        ),
      ),
    );
  }

  Widget _progress() {
    final isLocal = !widget.target.isCloud;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BrandMark.large(),
        const SizedBox(height: 28),
        SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '$_stage…',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            color: AppTheme.ink,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 10),
        if (isLocal) ...[
          Pill('${_elapsed}s', style: PillStyle.surface, fontSize: 11),
          const SizedBox(height: 14),
          Text(
            _elapsed < 20
                ? 'Loading the model into memory. The first load takes longest.'
                : 'Still loading — big models can take a minute on mid-range phones.',
            textAlign: TextAlign.center,
            style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 12, height: 1.4),
          ),
        ],
      ],
    );
  }

  Widget _failure() {
    final target = widget.target;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, color: AppTheme.ink2, size: 34),
        const SizedBox(height: 14),
        Text(
          target.isCloud ? 'Couldn\'t connect' : 'Couldn\'t load the model',
          style: GoogleFonts.interTight(
            color: AppTheme.ink,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(color: AppTheme.ink2, fontSize: 13, height: 1.45),
        ),
        if (!target.isCloud) ...[
          const SizedBox(height: 10),
          Text(
            'If this keeps happening, the phone may not have enough free memory '
            'for this model. Close other apps or pick a smaller model.',
            textAlign: TextAlign.center,
            style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 12, height: 1.4),
          ),
        ],
        const SizedBox(height: 24),
        PrimaryButton(onPressed: _load, label: 'Try again'),
        const SizedBox(height: 10),
        SecondaryButton(
          onPressed: () => resetTo(
            context,
            target is CloudTarget
                ? ApiKeySetupScreen(initialProvider: target.config.providerId)
                : const ModelHubScreen(),
          ),
          label: target.isCloud ? 'Check API key & model' : 'Choose another model',
        ),
      ],
    );
  }
}
