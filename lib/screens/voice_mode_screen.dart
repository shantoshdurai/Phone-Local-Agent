import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/agent/agent_service.dart';
import '../services/agent/text_utils.dart';
import '../services/tools/tool_runtime.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// Hands-free loop: listen → think → speak → listen.
enum _Phase { starting, idle, listening, thinking, speaking, paused, error }

class VoiceModeScreen extends StatefulWidget {
  const VoiceModeScreen({super.key});

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen> with TickerProviderStateMixin {
  final AgentService _agent = AgentService();
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  late final AnimationController _ring;
  StreamSubscription<AgentEvent>? _eventsSub;

  _Phase _phase = _Phase.starting;
  String _label = 'STARTING';
  String _heard = '';
  String _reply = '';
  String? _errorText;

  /// Incremented for every listen session so late callbacks from an old
  /// session are ignored.
  int _listenId = 0;
  bool _submitted = false;
  int _silentRounds = 0;
  bool _busyRetried = false;
  bool _closed = false;

  static const _maxSilentRounds = 2;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat();
    _agent.confirmHandler = _confirmAction;
    _eventsSub = _agent.events.listen((e) {
      if (_closed || _phase != _Phase.thinking) return;
      if (e is AgentStatus && e.text.isNotEmpty) {
        setState(() => _label = e.text.replaceAll('…', '').toUpperCase());
      } else if (e is AgentPartialText) {
        setState(() => _reply = e.text);
      } else if (e is AgentClearText) {
        setState(() => _reply = '');
      }
    });
    _init();
  }

  @override
  void dispose() {
    _closed = true;
    _ring.dispose();
    _eventsSub?.cancel();
    if (_agent.confirmHandler == _confirmAction) _agent.confirmHandler = null;
    _stt.cancel();
    _tts.stop();
    super.dispose();
  }

  Future<void> _init() async {
    final available = await _stt.initialize(onStatus: _onSttStatus, onError: _onSttError);
    if (!available) {
      _fail('Speech recognition isn\'t available. Allow microphone access, and make sure '
          'Google speech services are installed.');
      return;
    }
    await _configureTts();
    _listen();
  }

  Future<void> _configureTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Speak in the phone's language when the engine supports it.
      final locale = WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag();
      final available = await _tts.isLanguageAvailable(locale);
      await _tts.setLanguage(available == true ? locale : 'en-US');
    } catch (_) {}
  }

  // ── listening ────────────────────────────────────────────────────────────

  Future<void> _listen() async {
    if (_closed) return;
    final id = ++_listenId;
    _submitted = false;
    _setPhase(_Phase.listening, 'LISTENING');
    setState(() {
      _heard = '';
      _reply = '';
    });
    try {
      if (_stt.isListening) await _stt.cancel();
      await _stt.listen(
        onResult: (result) {
          if (_closed || id != _listenId || _submitted) return;
          setState(() => _heard = result.recognizedWords);
          if (result.finalResult && _heard.trim().isNotEmpty) _submit(_heard.trim());
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 45),
      );
    } catch (e) {
      _fail('Couldn\'t start listening: $e');
    }
  }

  void _onSttStatus(String status) {
    if (_closed || _phase != _Phase.listening) return;
    // 'notListening' arrives before the final result — acting on it (as the
    // old code did) dropped the user's words and caused ERROR_BUSY. Only
    // 'done' marks the end of the session.
    if (status != 'done') return;
    final id = _listenId;
    Future.delayed(const Duration(milliseconds: 250), () {
      if (_closed || id != _listenId || _submitted || _phase != _Phase.listening) return;
      if (_heard.trim().isNotEmpty) {
        _submit(_heard.trim());
      } else {
        _onSilence();
      }
    });
  }

  void _onSttError(SpeechRecognitionError error) {
    if (_closed) return;
    final msg = error.errorMsg.toLowerCase();
    if (msg.contains('no_match') || msg.contains('speech_timeout')) {
      if (_phase == _Phase.listening && !_submitted) {
        if (_heard.trim().isNotEmpty) {
          _submit(_heard.trim());
        } else {
          _onSilence();
        }
      }
    } else if (msg.contains('busy')) {
      if (!_busyRetried) {
        _busyRetried = true;
        Future.delayed(const Duration(milliseconds: 700), () async {
          await _stt.cancel();
          _listen();
        });
      } else {
        _goIdle();
      }
    } else if (msg.contains('permission') || msg.contains('audio')) {
      _fail('Microphone access is needed for voice mode. Allow it in Settings → Apps → Local Agent.');
    } else if (msg.contains('network')) {
      _fail('Speech recognition needs a connection on this phone (no offline voice pack installed).');
    } else if (!msg.contains('client')) {
      // error_client is what cancel() produces; everything else is real.
      _fail('Speech recognition error: ${error.errorMsg}');
    }
  }

  void _onSilence() {
    _silentRounds++;
    if (_silentRounds >= _maxSilentRounds) {
      // Stop auto-restarting: Android beeps every time the recognizer starts.
      _goIdle();
    } else {
      Future.delayed(const Duration(milliseconds: 300), _listen);
    }
  }

  void _goIdle() {
    _stt.cancel();
    _setPhase(_Phase.idle, 'TAP TO TALK');
  }

  // ── thinking & speaking ────────────────────────────────────────────────

  Future<void> _submit(String text) async {
    if (_submitted || _closed) return;
    _submitted = true;
    _silentRounds = 0;
    _busyRetried = false;
    await _stt.cancel();
    _setPhase(_Phase.thinking, 'THINKING');
    final reply = await _agent.send(text);
    if (_closed || _phase != _Phase.thinking) return;
    if (reply.stopped) {
      _listen();
      return;
    }
    setState(() => _reply = reply.text);
    await _speak(reply.text);
    if (!_closed && _phase == _Phase.speaking) _listen();
  }

  Future<void> _speak(String text) async {
    final chunks = splitForSpeech(stripForSpeech(text));
    if (chunks.isEmpty) return;
    _setPhase(_Phase.speaking, 'SPEAKING');
    for (final chunk in chunks) {
      if (_closed || _phase != _Phase.speaking) return;
      try {
        await _tts.speak(chunk);
      } catch (_) {
        return;
      }
    }
  }

  Future<bool> _confirmAction(ToolConfirmation request) async {
    if (_closed || !mounted) return false;
    await _tts.stop();
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(request.title,
            style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text(request.detail, style: GoogleFonts.interTight(color: AppTheme.ink2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 16))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Allow',
                  style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 16, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    return ok ?? false;
  }

  // ── controls ─────────────────────────────────────────────────────────────

  Future<void> _tapOrb() async {
    switch (_phase) {
      case _Phase.speaking:
        await _tts.stop(); // barge in
        _silentRounds = 0;
        _listen();
      case _Phase.listening:
        final text = _heard.trim();
        if (text.isNotEmpty) {
          await _stt.stop();
          _submit(text);
        }
      case _Phase.thinking:
        await _agent.stop();
      case _Phase.idle:
      case _Phase.paused:
      case _Phase.error:
        _silentRounds = 0;
        _busyRetried = false;
        _errorText = null;
        _listen();
      case _Phase.starting:
        break;
    }
  }

  Future<void> _togglePause() async {
    if (_phase == _Phase.paused) {
      _silentRounds = 0;
      _listen();
      return;
    }
    _listenId++;
    await _stt.cancel();
    await _tts.stop();
    if (_phase == _Phase.thinking) await _agent.stop();
    _setPhase(_Phase.paused, 'PAUSED');
  }

  Future<void> _close() async {
    _closed = true;
    await _stt.cancel();
    await _tts.stop();
    if (_phase == _Phase.thinking) await _agent.stop();
    if (mounted) Navigator.of(context).pop();
  }

  void _setPhase(_Phase phase, String label) {
    if (_closed || !mounted) return;
    setState(() {
      _phase = phase;
      _label = label;
    });
  }

  void _fail(String message) {
    if (_closed || !mounted) return;
    _stt.cancel();
    setState(() {
      _phase = _Phase.error;
      _label = 'TAP TO RETRY';
      _errorText = message;
    });
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isCloud = _agent.target?.isCloud ?? false;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: AppTheme.bg,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    HeaderIconButton(icon: Icons.close_rounded, onPressed: _close),
                    Expanded(
                      child: Center(child: Eyebrow(isCloud ? 'VOICE · CLOUD' : 'VOICE · ON-DEVICE')),
                    ),
                    const SizedBox(width: 36),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.9,
                      center: Alignment(0, -0.6),
                      colors: [Color(0xFF1A1A1A), AppTheme.bg],
                      stops: [0.0, 0.65],
                    ),
                  ),
                  child: Column(
                    children: [
                      const Spacer(flex: 2),
                      Semantics(
                        button: true,
                        label: 'Voice orb, $_label',
                        child: GestureDetector(onTap: _tapOrb, child: _orb()),
                      ),
                      const SizedBox(height: 32),
                      Eyebrow(_label, color: _phase == _Phase.error ? AppTheme.error : AppTheme.muted),
                      const SizedBox(height: 14),
                      Expanded(
                        flex: 3,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: _transcript(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 28, top: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fab(
                              icon: _phase == _Phase.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                              label: _phase == _Phase.paused ? 'Resume' : 'Pause',
                              onTap: _togglePause,
                            ),
                            const SizedBox(width: 40),
                            _fab(
                              icon: _phase == _Phase.thinking ? Icons.stop_rounded : Icons.mic_rounded,
                              label: _phase == _Phase.thinking ? 'Stop' : 'Talk',
                              primary: true,
                              onTap: _tapOrb,
                            ),
                            const SizedBox(width: 40),
                            _fab(icon: Icons.close_rounded, label: 'Close', onTap: _close),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _orb() {
    final active = _phase == _Phase.listening || _phase == _Phase.speaking || _phase == _Phase.thinking;
    return AnimatedBuilder(
      animation: _ring,
      builder: (context, _) {
        final t = _ring.value;
        final pulse = (math.sin(t * math.pi * 2) + 1) / 2;
        return SizedBox(
          width: 250,
          height: 250,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (active)
                Transform.scale(
                  scale: 0.9 + 0.4 * t,
                  child: Opacity(
                    opacity: (1 - t) * 0.6,
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.ink.withValues(alpha: 0.1)),
                      ),
                    ),
                  ),
                ),
              AnimatedScale(
                duration: const Duration(milliseconds: 300),
                scale: _phase == _Phase.listening ? 1.0 + pulse * 0.04 : (active ? 1.0 : 0.92),
                child: Container(
                  width: 196,
                  height: 196,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      radius: 0.9,
                      center: Alignment(0, -0.2),
                      colors: [Color(0xFFFFFFFF), Color(0xFFD8D8D8), Color(0xFF404040), Color(0xFF0A0A0A)],
                      stops: [0.0, 0.3, 0.75, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.ink.withValues(alpha: active ? 0.05 + pulse * 0.05 : 0.03),
                        blurRadius: 70,
                      ),
                    ],
                  ),
                  child: _phase == _Phase.thinking
                      ? const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black54),
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _transcript() {
    final style = GoogleFonts.interTight(
      fontSize: 21,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.4,
      height: 1.3,
      color: AppTheme.ink,
    );
    if (_errorText != null) {
      return Text(_errorText!,
          textAlign: TextAlign.center, style: style.copyWith(fontSize: 16, color: AppTheme.ink2));
    }
    if (_reply.isNotEmpty && _phase != _Phase.listening) {
      return Column(
        children: [
          if (_heard.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text('"$_heard"',
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: 15, color: AppTheme.muted)),
            ),
          Text(_reply, textAlign: TextAlign.center, style: style),
        ],
      );
    }
    if (_heard.isNotEmpty) {
      return Text('"$_heard"', textAlign: TextAlign.center, style: style);
    }
    final hint = switch (_phase) {
      _Phase.paused => 'Paused',
      _Phase.idle => 'Tap the orb and speak',
      _Phase.starting => '',
      _ => 'Say something…',
    };
    return Text(hint, textAlign: TextAlign.center, style: style.copyWith(color: AppTheme.muted));
  }

  Widget _fab({
    required IconData icon,
    required String label,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary ? AppTheme.ink : AppTheme.surface,
            border: Border.all(color: primary ? AppTheme.ink : AppTheme.border2),
          ),
          child: Icon(icon, size: primary ? 24 : 21, color: primary ? AppTheme.bg : AppTheme.ink),
        ),
      ),
    );
  }
}
