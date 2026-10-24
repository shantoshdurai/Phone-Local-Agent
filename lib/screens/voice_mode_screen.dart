import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/agent_service.dart';
import '../services/assistant_service.dart';
import '../services/database_service.dart';
import '../services/permission_flow.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';

/// Voice mode: listen → think → speak → listen.
///
/// The previous implementation restarted recognition from three places at once
/// (`onStatus`, `onError`, and the submit path), each scheduling a delayed
/// `listen()` call. Those callbacks fire on every stop, so the recogniser was
/// cancelled and re-armed while an utterance was still being finalised — the
/// classic symptom being a conversation that cuts off after one word or repeats
/// itself.
///
/// This version keeps exactly one owner of the microphone state:
/// [_beginListening] is the only place that starts recognition, every async
/// callback is guarded by a generation token, and submitting is idempotent.
enum _Phase { booting, idle, listening, thinking, speaking, muted, error }

class VoiceModeScreen extends StatefulWidget {
  final int sessionId;

  /// Assistant-gesture presentation: transparent route, blurred backdrop,
  /// captions docked at the bottom. The full-screen chat-style presentation is
  /// still used from the composer's mic button.
  final bool overlay;

  const VoiceModeScreen({
    super.key,
    required this.sessionId,
    this.overlay = false,
  });

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final AgentService _agent = AgentService();
  final DatabaseService _db = DatabaseService();
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  late final AnimationController _pulse;
  StreamSubscription<String>? _statusSub;

  _Phase _phase = _Phase.booting;
  String _statusLabel = 'STARTING';
  String _userTranscript = '';
  String _agentReply = '';
  String? _errorDetail;
  bool _errorNeedsSettings = false;

  bool _disposed = false;
  bool _sttReady = false;
  bool _ttsReady = false;

  /// Bumped on every phase transition. Any async callback that finds a
  /// different value than it started with simply returns: it is stale.
  int _generation = 0;

  /// True from the moment an utterance is submitted until speaking finishes.
  /// Makes double-submits (final result + timer + mic tap) impossible.
  bool _submitting = false;

  /// Set while TTS is audible so the recogniser never transcribes our own
  /// voice through the speaker (AEC is not reliable on all devices).
  bool _speaking = false;

  double _level = 0;
  Timer? _restartTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _statusSub = _agent.statusStream.listen(_onAgentStatus);
    _bootstrap();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _restartTimer?.cancel();
    _statusSub?.cancel();
    _pulse.dispose();
    // Fire-and-forget: the platform channels outlive this State object, and
    // awaiting here would delay the route pop for no benefit.
    _stt.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _tts.stop();
      _stt.stop();
      if (_phase == _Phase.listening || _phase == _Phase.speaking) {
        _setPhase(_Phase.idle, 'PAUSED');
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_phase == _Phase.idle) _beginListening();
    }
  }

  // ── Boot ────────────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    // Ask for the microphone here rather than at app start: the user has
    // explicitly opened voice mode, so the prompt has context.
    final granted = await PermissionFlow.request(PermTopic.microphone);
    if (_disposed) return;
    if (!granted) {
      _fail(
        'Microphone access is off',
        detail: 'Enable it in Settings to talk to the agent.',
        needsSettings: true,
      );
      return;
    }

    await _initTts();

    final ok = await _stt.initialize(
      onError: _onSttError,
      onStatus: _onSttStatus,
      debugLogging: false,
    );
    if (_disposed) return;
    if (!ok) {
      _fail(
        'Speech recognition unavailable',
        detail: 'This device has no speech service installed. '
            'You can still type in chat.',
      );
      return;
    }
    _sttReady = true;
    _beginListening();
  }

  Future<void> _initTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Prefer the device language when the TTS engine supports it; fall back
      // to en-US. Silently ignore engines that reject setLanguage.
      try {
        final langs = await _tts.getLanguages;
        final locale = WidgetsBinding.instance.platformDispatcher.locale;
        final tag = '${locale.languageCode}-${locale.countryCode}';
        if (langs is List &&
            langs.any((l) => l.toString().toLowerCase() == tag.toLowerCase())) {
          await _tts.setLanguage(tag);
        } else {
          await _tts.setLanguage('en-US');
        }
      } catch (_) {
        await _tts.setLanguage('en-US');
      }
      _ttsReady = true;
    } catch (_) {
      _ttsReady = false;
    }
  }

  // ── State helpers ───────────────────────────────────────────────────────

  void _setPhase(_Phase next, String label) {
    if (_disposed) return;
    setState(() {
      _phase = next;
      _statusLabel = label;
    });
  }

  void _fail(String title, {String? detail, bool needsSettings = false}) {
    if (_disposed) return;
    setState(() {
      _phase = _Phase.error;
      _statusLabel = title.toUpperCase();
      _errorDetail = detail;
      _errorNeedsSettings = needsSettings;
    });
  }

  void _onAgentStatus(String status) {
    if (_disposed || _phase != _Phase.thinking || status.isEmpty) return;
    setState(() {
      _statusLabel = status.replaceAll('...', '').toUpperCase().trim();
    });
  }

  // ── Listening ───────────────────────────────────────────────────────────

  void _beginListening({bool keepTranscript = false}) {
    if (_disposed || !_sttReady || _phase == _Phase.muted) return;
    if (_submitting || _speaking) return;

    final gen = ++_generation;
    final wasListening = _phase == _Phase.listening;
    _restartTimer?.cancel();
    if (!keepTranscript) _userTranscript = '';
    setState(() {
      _phase = _Phase.listening;
      _statusLabel = 'LISTENING';
      _errorDetail = null;
    });

    // Soft cue only on a real transition, not on every internal re-arm (which
    // happens after silence timeouts and would turn into a metronome).
    if (!wasListening) {
      // ignore: discarded_futures
      AssistantService.instance.playCue('listen');
      // ignore: discarded_futures
      HapticFeedback.selectionClick();
    }

    // Re-arm off the UI thread's critical path. Cancelling first guarantees
    // the recogniser is idle before listen() is called again; without this a
    // rapid phase change leaves the platform session in a "busy" state.
    _restartTimer = Timer(const Duration(milliseconds: 140), () async {
      if (_disposed || gen != _generation) return;
      try {
        if (_stt.isListening) await _stt.cancel();
      } catch (_) {}
      if (_disposed || gen != _generation) return;
      try {
        await _stt.listen(
          onResult: (result) => _onSttResult(result, gen),
          onSoundLevelChange: (level) {
            if (_disposed || gen != _generation) return;
            // dBFS from the platform, roughly -2 (silence) .. 10 (loud).
            final norm = ((level + 2) / 12).clamp(0.0, 1.0);
            if ((norm - _level).abs() > 0.04) {
              setState(() => _level = norm);
            }
          },
          listenOptions: SpeechListenOptions(
            partialResults: true,
            cancelOnError: true,
            listenMode: ListenMode.dictation,
            autoPunctuation: true,
            enableHapticFeedback: false,
          ),
          pauseFor: const Duration(milliseconds: 2400),
          listenFor: const Duration(seconds: 45),
        );
      } catch (e) {
        if (_disposed || gen != _generation) return;
        _fail('Could not start listening', detail: e.toString());
      }
    });
  }

  void _onSttResult(SpeechRecognitionResult result, int gen) {
    if (_disposed || gen != _generation || _submitting) return;
    if (_phase != _Phase.listening) return;

    setState(() => _userTranscript = result.recognizedWords);

    if (result.finalResult) {
      final text = result.recognizedWords.trim();
      if (text.isEmpty) {
        // Silence: keep the loop alive instead of dropping to idle.
        _beginListening();
      } else {
        _submit(text, gen);
      }
    }
  }

  void _onSttStatus(String status) {
    if (_disposed) return;
    if (status != 'notListening' && status != 'done') return;
    if (_phase != _Phase.listening || _submitting || _speaking) return;

    // The recogniser stopped on its own: either it hit `pauseFor` after the
    // final result (handled above) or `listenFor` expired. Only restart if we
    // still have the floor; otherwise do nothing.
    final gen = _generation;
    final text = _userTranscript.trim();
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 320), () {
      if (_disposed || gen != _generation) return;
      if (_submitting || _phase != _Phase.listening) return;
      if (text.isNotEmpty) {
        _submit(text, gen);
      } else {
        _beginListening();
      }
    });
  }

  void _onSttError(SpeechRecognitionError error) {
    if (_disposed) return;
    final msg = error.errorMsg.toLowerCase();

    // Expected, non-fatal outcomes. Restart quietly.
    if (msg.contains('no_match') ||
        msg.contains('no match') ||
        msg.contains('speech_timeout') ||
        msg.contains('timeout')) {
      if (_phase == _Phase.listening && !_submitting) _beginListening();
      return;
    }
    if (msg.contains('busy')) {
      if (_phase == _Phase.listening && !_submitting) _beginListening();
      return;
    }
    if (msg.contains('permission')) {
      _fail('Microphone blocked',
          detail: 'Enable microphone access in Settings.', needsSettings: true);
      return;
    }
    if (error.permanent) {
      _fail('Speech recognition stopped', detail: error.errorMsg);
      return;
    }
    _fail('Speech recognition error', detail: error.errorMsg);
  }

  // ── Turn: submit → think → speak ────────────────────────────────────────

  Future<void> _submit(String text, int gen) async {
    if (_disposed || _submitting) return;
    _submitting = true;
    _generation++; // invalidate in-flight recognition callbacks
    _restartTimer?.cancel();

    try {
      await _stt.cancel();
    } catch (_) {}

    setState(() {
      _phase = _Phase.thinking;
      _statusLabel = 'THINKING';
      _userTranscript = text;
      _agentReply = '';
    });

    try {
      await _db.saveMessage('user', text, widget.sessionId);
      final response = await _agent.sendMessage(text, widget.sessionId);
      if (_disposed) return;

      final spoken = _stripForTts(response.text);
      setState(() => _agentReply = response.text);

      if (spoken.isEmpty) {
        _submitting = false;
        _speaking = false;
        await _resumeListening();
        return;
      }

      setState(() {
        _phase = _Phase.speaking;
        _statusLabel = 'SPEAKING';
        _speaking = true;
        _level = 0;
      });
      // ignore: discarded_futures
      AssistantService.instance.playCue('done');
      // ignore: discarded_futures
      HapticFeedback.lightImpact();

      if (_ttsReady) {
        try {
          await _tts.speak(spoken);
        } catch (_) {
          // TTS failure must not end the conversation.
        }
      }
      if (_disposed) return;

      // Speaker tail: give the audio path a beat to drain before the mic
      // reopens, otherwise the recogniser transcribes the last syllable of
      // our own reply and the agent answers itself.
      await Future.delayed(const Duration(milliseconds: 380));
      if (_disposed) return;
      // Clear the guards *before* reopening the mic: _beginListening refuses
      // to run while a submit or a speak is marked in flight.
      _submitting = false;
      _speaking = false;
      await _resumeListening();
    } catch (e) {
      if (_disposed) return;
      _fail('Could not answer', detail: _humanize(e));
    } finally {
      _submitting = false;
      _speaking = false;
    }
  }

  Future<void> _resumeListening() async {
    if (_disposed) return;
    if (_phase == _Phase.muted) return;
    _beginListening();
  }

  // ── Controls ────────────────────────────────────────────────────────────

  Future<void> _onMicTap() async {
    if (_disposed) return;
    switch (_phase) {
      case _Phase.speaking:
        // Barge-in: stop the reply and listen immediately.
        await _tts.stop();
        _speaking = false;
        _submitting = false;
        await _resumeListening();
        break;
      case _Phase.listening:
        // Manual stop: submit whatever we have; if empty, just restart.
        final text = _userTranscript.trim();
        try {
          await _stt.stop();
        } catch (_) {}
        if (text.isNotEmpty) {
          await _submit(text, _generation);
        } else {
          _beginListening();
        }
        break;
      case _Phase.thinking:
        await _agent.stopGeneration();
        break;
      case _Phase.error:
      case _Phase.idle:
      case _Phase.muted:
        _beginListening();
        break;
      case _Phase.booting:
        break;
    }
  }

  Future<void> _toggleMute() async {
    if (_phase == _Phase.muted) {
      _beginListening();
      return;
    }
    _generation++;
    _restartTimer?.cancel();
    try {
      await _stt.cancel();
    } catch (_) {}
    await _tts.stop();
    _speaking = false;
    _submitting = false;
    _setPhase(_Phase.muted, 'MUTED');
  }

  Future<void> _retry() async {
    if (!_sttReady) {
      await _bootstrap();
    } else {
      _beginListening();
    }
  }

  Future<void> _close() async {
    _disposed = true;
    _restartTimer?.cancel();
    try {
      await _stt.cancel();
    } catch (_) {}
    await _tts.stop();
    if (mounted) Navigator.of(context).pop();
  }

  String _stripForTts(String text) {
    var s = text;
    // Drop fenced code blocks entirely — reading code aloud is noise.
    s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' code block ');
    s = s.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    s = s.replaceAll(RegExp(r'!\[(.*?)\]\((.*?)\)'), r'$1');
    s = s.replaceAll(RegExp(r'\[(.*?)\]\((.*?)\)'), r'$1');
    s = s.replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'$1');
    s = s.replaceAll(RegExp(r'\*(.*?)\*'), r'$1');
    s = s.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'https?://\S+'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('Model not initialized')) {
      return 'The model is still loading. Give it a moment and try again.';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return 'That needs an internet connection.';
    }
    return 'Something went wrong. Try again.';
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  bool get _isActive =>
      _phase == _Phase.listening ||
      _phase == _Phase.thinking ||
      _phase == _Phase.speaking;

  @override
  Widget build(BuildContext context) =>
      widget.overlay ? _buildOverlay() : _buildFull();

  Widget _buildFull() {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  HeaderIconButton(icon: Icons.close_rounded, onPressed: _close),
                  const Expanded(
                    child: Center(child: Eyebrow('VOICE MODE · ON-DEVICE')),
                  ),
                  // Reserved slot keeps the eyebrow optically centered.
                  const SizedBox(width: 36, height: 36),
                ],
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.95,
                    center: Alignment(0, -0.55),
                    colors: [Color(0xFF161616), AppTheme.bg],
                    stops: [0.0, 0.62],
                  ),
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: _onMicTap,
                          behavior: HitTestBehavior.opaque,
                          child: _blob(),
                        ),
                        const SizedBox(height: 34),
                        Eyebrow(
                          _statusLabel,
                          color: _phase == _Phase.error
                              ? AppTheme.error
                              : AppTheme.muted,
                        ),
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 26),
                          child: _phase == _Phase.error
                              ? _errorView()
                              : _transcript(),
                        ),
                      ],
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 26,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _fab(
                            icon: _phase == _Phase.muted
                                ? Icons.mic_off_rounded
                                : Icons.mic_off_outlined,
                            onTap: _toggleMute,
                            semanticLabel: _phase == _Phase.muted
                                ? 'Turn microphone on'
                                : 'Mute microphone',
                          ),
                          const SizedBox(width: 38),
                          _fab(
                            icon: _phase == _Phase.thinking
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                            primary: true,
                            onTap: _onMicTap,
                            semanticLabel: _phase == _Phase.thinking
                                ? 'Stop generating'
                                : 'Talk',
                          ),
                          const SizedBox(width: 38),
                          _fab(
                            icon: Icons.close_rounded,
                            onTap: _close,
                            semanticLabel: 'Close voice mode',
                          ),
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

  /// Assistant-gesture presentation: blurred backdrop, orb in the middle, and
  /// everything the user says or hears in a caption panel at the bottom — the
  /// same reading position as live captions, so it works one-handed.
  Widget _buildOverlay() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.74)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8, top: 4),
                    child: HeaderIconButton(
                      icon: Icons.close_rounded,
                      onPressed: _close,
                    ),
                  ),
                ),
                const Spacer(flex: 2),
                GestureDetector(
                  onTap: _onMicTap,
                  behavior: HitTestBehavior.opaque,
                  child: _blob(),
                ),
                const SizedBox(height: 18),
                Eyebrow(
                  _statusLabel,
                  color: _phase == _Phase.error
                      ? AppTheme.error
                      : AppTheme.muted,
                ),
                const Spacer(flex: 3),
                if (_phase == _Phase.error)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _errorView(),
                  )
                else
                  _captionPanel(),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _fab(
                      icon: _phase == _Phase.muted
                          ? Icons.mic_off_rounded
                          : Icons.mic_off_outlined,
                      onTap: _toggleMute,
                      semanticLabel: _phase == _Phase.muted
                          ? 'Turn microphone on'
                          : 'Mute microphone',
                    ),
                    const SizedBox(width: 26),
                    _fab(
                      icon: _phase == _Phase.thinking
                          ? Icons.stop_rounded
                          : Icons.mic_rounded,
                      primary: true,
                      onTap: _onMicTap,
                      semanticLabel: _phase == _Phase.thinking
                          ? 'Stop generating'
                          : 'Talk',
                    ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Live captions: the transcript while listening, the streaming answer while
  /// speaking. Fixed at the bottom like subtitles.
  Widget _captionPanel() {
    final showReply = _agentReply.isNotEmpty;
    final body = showReply
        ? _agentReply
        : (_userTranscript.isNotEmpty ? '“$_userTranscript”' : '');

    final hint = switch (_phase) {
      _Phase.booting => 'Waking up…',
      _Phase.muted => 'Microphone is off',
      _Phase.thinking => 'Thinking…',
      _Phase.listening => 'Listening — just say it',
      _ => 'Ask me anything',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 82, maxHeight: 200),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: SingleChildScrollView(
          reverse: true,
          child: Text(
            body.isEmpty ? hint : body,
            textAlign: TextAlign.center,
            style: GoogleFonts.interTight(
              fontSize: body.isEmpty ? 16 : 18,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: body.isEmpty ? AppTheme.muted : AppTheme.ink,
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Column(
      children: [
        Text(
          _errorDetail ?? 'Voice mode stopped.',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 14,
            height: 1.5,
            color: AppTheme.ink2,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _retry,
              child: Text(
                'Try again',
                style: GoogleFonts.interTight(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.ink,
                ),
              ),
            ),
            if (_errorNeedsSettings) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => PermissionFlow.openSettings(),
                child: Text(
                  'Open settings',
                  style: GoogleFonts.interTight(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _blob() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = _pulse.value;
        // When listening, the ring reacts to mic level so it feels alive;
        // otherwise it drifts gently.
        final energy = _phase == _Phase.listening
            ? (0.12 + _level * 0.55)
            : (_phase == _Phase.speaking ? 0.35 + 0.12 * math.sin(t * 2 * math.pi) : 0.16);
        return SizedBox(
          width: 288,
          height: 288,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 2; i++)
                Transform.scale(
                  scale: 0.92 + (t + i * 0.5) % 1 * (0.22 + energy * 0.5),
                  child: Opacity(
                    opacity: (1 - ((t + i * 0.5) % 1)) * 0.35,
                    child: Container(
                      width: 258,
                      height: 258,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                    ),
                  ),
                ),
              Container(
                width: 216,
                height: 216,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    radius: 0.92,
                    center: const Alignment(0, -0.22),
                    colors: _phase == _Phase.muted
                        ? const [
                            Color(0xFF6A6A6A),
                            Color(0xFF4A4A4A),
                            Color(0xFF202020),
                            Color(0xFF0A0A0A),
                          ]
                        : const [
                            Color(0xFFFFFFFF),
                            Color(0xFFD8D8D8),
                            Color(0xFF3A3A3A),
                            Color(0xFF0A0A0A),
                          ],
                    stops: const [0.0, 0.3, 0.76, 1.0],
                  ),
                  boxShadow: _isActive
                      ? [
                          BoxShadow(
                            color: Colors.white
                                .withValues(alpha: 0.05 + energy * 0.10),
                            blurRadius: 70,
                            spreadRadius: energy * 14,
                          ),
                        ]
                      : null,
                ),
                child: _phase == _Phase.thinking
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: Color(0xFF1A1A1A),
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _transcript() {
    final muted = const Color(0xFF707070);
    final showReply = _agentReply.isNotEmpty;
    final showUser = _userTranscript.isNotEmpty;

    if (!showReply && !showUser) {
      final label = switch (_phase) {
        _Phase.muted => 'Microphone is off',
        _Phase.booting => 'Starting…',
        _Phase.thinking => 'Thinking…',
        _ => 'Say something to begin',
      };
      return Text(
        label,
        textAlign: TextAlign.center,
        style: GoogleFonts.interTight(
          fontSize: 21,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.4,
          height: 1.3,
          color: muted,
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          showReply ? _agentReply : '“$_userTranscript”',
          textAlign: TextAlign.center,
          style: GoogleFonts.interTight(
            fontSize: 21,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.4,
            height: 1.35,
            color: showReply ? AppTheme.ink : AppTheme.ink2,
          ),
        ),
      ),
    );
  }

  Widget _fab({
    required IconData icon,
    required VoidCallback onTap,
    required String semanticLabel,
    bool primary = false,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
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
          child: Icon(
            icon,
            size: primary ? 22 : 20,
            color: primary ? AppTheme.bg : AppTheme.ink,
          ),
        ),
      ),
    );
  }
}
