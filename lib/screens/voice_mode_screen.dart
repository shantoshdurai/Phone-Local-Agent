import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// 08 · Voice mode — hands-free loop. Listen → think → speak → listen.
enum _VoicePhase { idle, listening, thinking, speaking, error, muted }

class VoiceModeScreen extends StatefulWidget {
  final int sessionId;
  const VoiceModeScreen({super.key, required this.sessionId});

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen>
    with TickerProviderStateMixin {
  final AgentService _agent = AgentService();
  final DatabaseService _db = DatabaseService();
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  late final AnimationController _ringController;
  StreamSubscription? _statusSub;

  _VoicePhase _phase = _VoicePhase.idle;
  String _statusLabel = 'TAP TO START';
  String _userTranscript = '';
  String _agentReply = '';
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
    _statusSub = _agent.statusStream.listen(_onAgentStatus);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final sttOk = await _stt.initialize(
      onError: (e) {
        if (_disposed) return;
        final msg = e.errorMsg.toLowerCase();
        if (msg.contains('timeout') ||
            msg.contains('no_match') ||
            msg.contains('no match')) {
          if (_phase == _VoicePhase.listening) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_phase == _VoicePhase.listening && !_disposed) {
                _startListening();
              }
            });
          }
        } else {
          _failWith('Error: ${e.errorMsg}');
        }
      },
      onStatus: (status) {
        if (_disposed) return;
        if (status == 'notListening' || status == 'done') {
          if (_phase == _VoicePhase.listening) {
            Future.delayed(const Duration(milliseconds: 100), () {
              if (_phase == _VoicePhase.listening && !_disposed) {
                _startListening();
              }
            });
          }
        }
      },
    );
    if (!sttOk) {
      _failWith('Speech recognition not available');
      return;
    }
    try {
      await _tts.setLanguage('en-US');
    } catch (_) {}
    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
    _startListening();
  }

  void _onAgentStatus(String status) {
    if (_disposed || _phase != _VoicePhase.thinking) return;
    if (status.isEmpty) return;
    setState(() => _statusLabel = status.replaceAll('...', '').toUpperCase().trim());
  }

  void _setPhase(_VoicePhase next, {required String label}) {
    if (_disposed) return;
    setState(() {
      _phase = next;
      _statusLabel = label;
    });
  }

  Future<void> _startListening() async {
    if (_disposed) return;
    _userTranscript = '';
    _agentReply = '';
    _setPhase(_VoicePhase.listening, label: 'LISTENING');
    await _stt.listen(
      onResult: (result) {
        if (_disposed) return;
        setState(() => _userTranscript = result.recognizedWords);
        if (result.finalResult && _userTranscript.trim().isNotEmpty) {
          _handleSubmit(_userTranscript.trim());
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      pauseFor: const Duration(seconds: 2),
      listenFor: const Duration(seconds: 30),
    );
  }

  Future<void> _handleSubmit(String text) async {
    if (_disposed) return;
    try {
      await _stt.cancel();
    } catch (_) {}
    _setPhase(_VoicePhase.thinking, label: 'THINKING');
    try {
      await _db.saveMessage('user', text, widget.sessionId);
      final response = await _agent.sendMessage(text, widget.sessionId);
      if (_disposed) return;
      final spoken = _stripForTts(response.text);
      setState(() => _agentReply = response.text);
      if (spoken.isEmpty) {
        _startListening();
        return;
      }
      _setPhase(_VoicePhase.speaking, label: 'SPEAKING');
      await _tts.speak(spoken);
      if (_disposed) return;
      _startListening();
    } catch (e) {
      _failWith('Agent error: $e');
    }
  }

  String _stripForTts(String text) {
    return text
        .replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'$1')
        .replaceAll(RegExp(r'\*(.*?)\*'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .replaceAll(RegExp(r'```[\s\S]*?```'), '')
        .replaceAll(RegExp(r'#+\s*'), '')
        .replaceAll(RegExp(r'\[(.*?)\]\((.*?)\)'), r'$1')
        .trim();
  }

  void _failWith(String label) {
    if (_disposed) return;
    setState(() {
      _phase = _VoicePhase.error;
      _statusLabel = label.toUpperCase();
    });
  }

  Future<void> _toggleMute() async {
    if (_phase == _VoicePhase.muted) {
      _startListening();
    } else {
      try {
        await _stt.stop();
      } catch (_) {}
      try {
        await _tts.stop();
      } catch (_) {}
      _setPhase(_VoicePhase.muted, label: 'MUTED');
    }
  }

  Future<void> _tapMic() async {
    if (_phase == _VoicePhase.speaking) {
      await _tts.stop();
      _startListening();
    } else if (_phase == _VoicePhase.listening) {
      await _stt.stop();
      final text = _userTranscript.trim();
      if (text.isNotEmpty) {
        _handleSubmit(text);
      } else {
        _startListening();
      }
    } else {
      _startListening();
    }
  }

  Future<void> _close() async {
    _disposed = true;
    try {
      await _stt.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _disposed = true;
    _ringController.dispose();
    _statusSub?.cancel();
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar — close left, eyebrow center, settings right.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  HeaderIconButton(icon: Icons.close_rounded, onPressed: _close),
                  Expanded(
                    child: Center(child: Eyebrow('VOICE MODE · LOCAL')),
                  ),
                  HeaderIconButton(
                    icon: Icons.settings_outlined,
                    size: 18,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.9,
                    center: Alignment(0, -0.6),
                    colors: [Color(0xFF1A1A1A), AppTheme.bg],
                    stops: [0.0, 0.65],
                  ),
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(onTap: _tapMic, child: _blob()),
                        const SizedBox(height: 36),
                        Eyebrow(_statusLabel,
                            color: _phase == _VoicePhase.error
                                ? AppTheme.error
                                : AppTheme.muted),
                        const SizedBox(height: 12),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 20),
                          child: _transcript(),
                        ),
                      ],
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 28,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _fab(
                              icon: _phase == _VoicePhase.muted
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_off_outlined,
                              onTap: _toggleMute),
                          const SizedBox(width: 40),
                          _fab(icon: Icons.mic_rounded, primary: true, onTap: _tapMic),
                          const SizedBox(width: 40),
                          _fab(icon: Icons.close_rounded, onTap: _close),
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
    );
  }

  Widget _blob() {
    return AnimatedBuilder(
      animation: _ringController,
      builder: (context, _) {
        final t = _ringController.value;
        return SizedBox(
          width: 280,
          height: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Animated outer ring
              Transform.scale(
                scale: 0.9 + 0.4 * t,
                child: Opacity(
                  opacity: (1 - t) * 0.6,
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ),
              ),
              // Core blob
              Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    radius: 0.9,
                    center: Alignment(0, -0.2),
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFD8D8D8),
                      Color(0xFF404040),
                      Color(0xFF0A0A0A),
                    ],
                    stops: [0.0, 0.3, 0.75, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.06),
                      blurRadius: 60,
                    ),
                  ],
                ),
                child: AnimatedBuilder(
                  animation: _ringController,
                  builder: (context, _) {
                    final pulse = (math.sin(t * math.pi * 2) + 1) / 2;
                    return Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: _phase == _VoicePhase.idle ||
                                _phase == _VoicePhase.muted
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.white
                                      .withValues(alpha: 0.04 + pulse * 0.04),
                                  blurRadius: 80,
                                ),
                              ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _transcript() {
    final showUser = _userTranscript.isNotEmpty;
    final showReply = _agentReply.isNotEmpty;
    final muted = const Color(0xFF707070);
    if (!showUser && !showReply) {
      return Text(
        _phase == _VoicePhase.muted ? 'Mic is off' : 'Say something to begin',
        textAlign: TextAlign.center,
        style: GoogleFonts.interTight(
          fontSize: 22,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.4,
          height: 1.3,
          color: muted,
        ),
      );
    }
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: GoogleFonts.interTight(
          fontSize: 22,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.4,
          height: 1.3,
          color: AppTheme.ink,
        ),
        children: [
          if (showReply)
            TextSpan(text: _agentReply)
          else ...[
            TextSpan(text: _quoteWrap(_userTranscript)),
            const WidgetSpan(child: _BlinkingCaret()),
          ],
        ],
      ),
    );
  }

  String _quoteWrap(String s) => '"$s"';

  Widget _fab(
      {required IconData icon, bool primary = false, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary ? AppTheme.ink : AppTheme.surface,
          border: Border.all(
            color: primary ? AppTheme.ink : AppTheme.border2,
          ),
        ),
        child: Icon(icon,
            size: primary ? 22 : 20,
            color: primary ? AppTheme.bg : AppTheme.ink),
      ),
    );
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final on = _c.value < 0.5;
        return Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Opacity(
            opacity: on ? 1 : 0,
            child: Container(width: 7, height: 22, color: AppTheme.ink),
          ),
        );
      },
    );
  }
}
