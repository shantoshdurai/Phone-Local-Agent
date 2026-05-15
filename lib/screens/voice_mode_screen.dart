import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';

/// Hands-free voice loop: listen → think → speak → listen.
///
/// Mirrors ChatGPT's voice mode in spirit: full-screen black, one big orb, no
/// chat scroll. Each phase has its own orb animation and one-line status so
/// the user can also debug if a tool fires — the tool name shows on screen
/// but only the natural-language reply is spoken.
enum _VoicePhase { idle, listening, thinking, speaking, error }

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

  late final AnimationController _orbController;

  StreamSubscription? _statusSub;

  _VoicePhase _phase = _VoicePhase.idle;
  String _statusLabel = 'Tap to start';
  String _userTranscript = '';
  String _agentReply = '';
  String? _activeToolName;
  // Live mic level from speech_to_text, smoothed for the orb pulse.
  double _soundLevel = 0.0;
  // True after user explicitly closed the screen — stop all loops.
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _statusSub = _agent.statusStream.listen(_onAgentStatus);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final sttOk = await _stt.initialize(
      onError: (e) => _failWith('Speech recognition error'),
      onStatus: (_) {},
    );
    if (!sttOk) {
      _failWith('Speech recognition not available');
      return;
    }

    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    _tts.setStartHandler(() {
      if (_disposed) return;
      _setPhase(_VoicePhase.speaking, label: 'Speaking');
    });
    _tts.setCompletionHandler(() {
      if (_disposed) return;
      // Done speaking → loop back to listening unless the user closed us.
      _startListening();
    });
    _tts.setErrorHandler((_) {
      if (_disposed) return;
      _startListening();
    });

    _startListening();
  }

  void _onAgentStatus(String status) {
    if (_disposed || _phase != _VoicePhase.thinking) return;
    if (status.isEmpty) return;
    // Status messages are short like "Running search_web..." or "Thinking..."
    // — surface them as the live status label and remember tool name if any.
    final match = RegExp(r'^Running (\w+)').firstMatch(status);
    if (match != null) {
      _activeToolName = match.group(1);
    }
    setState(() => _statusLabel = status.replaceAll('...', '').trim());
  }

  // ─── State transitions ───

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
    _activeToolName = null;
    _soundLevel = 0.0;
    _setPhase(_VoicePhase.listening, label: 'Listening');

    await _stt.listen(
      onResult: (result) {
        if (_disposed) return;
        setState(() => _userTranscript = result.recognizedWords);
        if (result.finalResult && _userTranscript.trim().isNotEmpty) {
          _handleSubmit(_userTranscript.trim());
        }
      },
      onSoundLevelChange: (level) {
        if (_disposed) return;
        // speech_to_text emits dB-ish values roughly -2..10. Normalize to 0..1.
        final normalized = ((level + 2) / 12.0).clamp(0.0, 1.0);
        setState(() => _soundLevel = normalized);
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
    await _stt.stop();
    _setPhase(_VoicePhase.thinking, label: 'Thinking');

    try {
      // Persist the user's spoken turn so it shows up in the chat list when
      // they exit voice mode. The assistant turn is saved inside sendMessage.
      await _db.saveMessage('user', text, widget.sessionId);
      final response =
          await _agent.sendMessage(text, widget.sessionId);
      if (_disposed) return;
      // Strip markdown so TTS doesn't read "asterisk asterisk".
      final spoken = _stripForTts(response.text);
      setState(() => _agentReply = response.text);
      if (spoken.isEmpty) {
        _startListening();
        return;
      }
      await _tts.speak(spoken);
    } catch (e) {
      _failWith('Agent error: $e');
    }
  }

  String _stripForTts(String text) {
    return text
        .replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'$1') // bold
        .replaceAll(RegExp(r'\*(.*?)\*'), r'$1') // italic
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1') // inline code
        .replaceAll(RegExp(r'```[\s\S]*?```'), '') // code blocks
        .replaceAll(RegExp(r'#+\s*'), '') // headings
        .replaceAll(RegExp(r'\[(.*?)\]\((.*?)\)'), r'$1') // links → text
        .trim();
  }

  void _failWith(String label) {
    if (_disposed) return;
    setState(() {
      _phase = _VoicePhase.error;
      _statusLabel = label;
    });
  }

  // ─── User actions ───

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

  /// Tap the orb to interrupt the current phase and restart listening.
  Future<void> _tapOrb() async {
    if (_phase == _VoicePhase.speaking) {
      await _tts.stop();
      _startListening();
    } else if (_phase == _VoicePhase.listening) {
      // Force-finalize whatever's recognized so far.
      await _stt.stop();
      final text = _userTranscript.trim();
      if (text.isNotEmpty) {
        _handleSubmit(text);
      } else {
        _startListening();
      }
    } else if (_phase == _VoicePhase.error || _phase == _VoicePhase.idle) {
      _startListening();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _orbController.dispose();
    _statusSub?.cancel();
    _stt.stop();
    _tts.stop();
    super.dispose();
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Close button.
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white70, size: 28),
                onPressed: _close,
              ),
            ),
            // Phase + transcript stack.
            Column(
              children: [
                const SizedBox(height: 36),
                Text(
                  'Voice mode',
                  style: GoogleFonts.outfit(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 13,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _tapOrb,
                  child: _Orb(
                    controller: _orbController,
                    phase: _phase,
                    soundLevel: _soundLevel,
                  ),
                ),
                const SizedBox(height: 28),
                _statusLine(),
                const SizedBox(height: 12),
                _transcriptBlock(),
                const Spacer(flex: 2),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine() {
    Color color;
    switch (_phase) {
      case _VoicePhase.listening:
        color = const Color(0xFF3B82F6);
        break;
      case _VoicePhase.thinking:
        color = const Color(0xFFFBBF24);
        break;
      case _VoicePhase.speaking:
        color = const Color(0xFF34D399);
        break;
      case _VoicePhase.error:
        color = const Color(0xFFF87171);
        break;
      case _VoicePhase.idle:
        color = Colors.white54;
        break;
    }
    return Text(
      _statusLabel,
      style: GoogleFonts.outfit(
        color: color,
        fontSize: 16,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _transcriptBlock() {
    final hasUser = _userTranscript.trim().isNotEmpty;
    final hasReply = _agentReply.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          if (_activeToolName != null && _phase == _VoicePhase.thinking)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Text(
                  'Tool: $_activeToolName',
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: const Color(0xFFFBBF24),
                  ),
                ),
              ),
            ),
          if (hasUser)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _userTranscript,
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 15,
                  color: Colors.white54,
                  height: 1.4,
                ),
              ),
            ),
          if (hasReply)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                _agentReply,
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 17,
                  color: Colors.white,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  final AnimationController controller;
  final _VoicePhase phase;
  final double soundLevel;

  const _Orb({
    required this.controller,
    required this.phase,
    required this.soundLevel,
  });

  Color get _primary {
    switch (phase) {
      case _VoicePhase.listening:
        return const Color(0xFF3B82F6);
      case _VoicePhase.thinking:
        return const Color(0xFFFBBF24);
      case _VoicePhase.speaking:
        return const Color(0xFF34D399);
      case _VoicePhase.error:
        return const Color(0xFFF87171);
      case _VoicePhase.idle:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        // Base pulse — slow heartbeat. Mic level adds responsive bloom while
        // listening; a faster shimmer kicks in during thinking/speaking.
        double pulse;
        switch (phase) {
          case _VoicePhase.listening:
            pulse = 0.5 + soundLevel * 0.5;
            break;
          case _VoicePhase.thinking:
            pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 1.4));
            break;
          case _VoicePhase.speaking:
            pulse = 0.6 + 0.4 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 2.2));
            break;
          case _VoicePhase.error:
            pulse = 0.45;
            break;
          case _VoicePhase.idle:
            pulse = 0.5 + 0.1 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
            break;
        }
        final base = 160.0;
        final size = base + pulse * 40;
        return SizedBox(
          width: base + 80,
          height: base + 80,
          child: Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    _primary.withValues(alpha: 0.95),
                    _primary.withValues(alpha: 0.35),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _primary.withValues(alpha: 0.45),
                    blurRadius: 50 + pulse * 30,
                    spreadRadius: 4 + pulse * 8,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
