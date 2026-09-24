import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../app/launch.dart';
import '../models/chat_message.dart';
import '../services/agent/agent_service.dart';
import '../services/database_service.dart';
import '../services/device_service.dart';
import '../services/model_downloader_service.dart';
import '../services/tools/tool_runtime.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import '../widgets/message_bubble.dart';
import '../widgets/suggestions_list.dart';
import 'api_key_setup_screen.dart';
import 'model_picker_screen.dart';
import 'settings_screen.dart';
import 'voice_mode_screen.dart';

/// Chat: empty state, streaming replies, sessions drawer.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final AgentService _agent = AgentService();
  final DatabaseService _db = DatabaseService();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final SpeechToText _speech = SpeechToText();
  final ImagePicker _picker = ImagePicker();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final List<ChatMessage> _messages = [];
  List<Map<String, dynamic>> _sessions = [];
  String _sessionFilter = '';
  String? _selectedImagePath;
  bool _busy = false;
  bool _speechReady = false;
  bool _listening = false;

  final ValueNotifier<String> _streamingText = ValueNotifier('');
  final ValueNotifier<String> _status = ValueNotifier('');
  final ValueNotifier<int> _elapsed = ValueNotifier(0);
  Timer? _elapsedTimer;
  StreamSubscription<AgentEvent>? _eventsSub;
  bool _scrollPending = false;

  late List<Map<String, dynamic>> _suggestions;

  static const List<Map<String, dynamic>> _allSuggestions = [
    {'text': 'What\'s the weather today?', 'icon': Icons.wb_sunny_outlined},
    {'text': 'Turn on the flashlight', 'icon': Icons.flashlight_on_rounded},
    {'text': 'Set a timer for 10 minutes', 'icon': Icons.timer_outlined},
    {'text': 'How much battery do I have?', 'icon': Icons.battery_charging_full_rounded},
    {'text': 'Read my notifications', 'icon': Icons.notifications_none_rounded},
    {'text': 'Show my latest screenshot', 'icon': Icons.image_search_rounded},
    {'text': 'Search the web for today\'s top news', 'icon': Icons.public_rounded},
    {'text': 'Which apps take the most space?', 'icon': Icons.apps_rounded},
    {'text': 'What can you do?', 'icon': Icons.help_outline_rounded},
  ];

  @override
  void initState() {
    super.initState();
    _suggestions = (List.of(_allSuggestions)..shuffle(Random())).take(4).toList();
    _agent.confirmHandler = _confirmAction;
    _eventsSub = _agent.events.listen(_onAgentEvent);
    _startBlank();
  }

  @override
  void dispose() {
    if (_agent.confirmHandler == _confirmAction) _agent.confirmHandler = null;
    _eventsSub?.cancel();
    _elapsedTimer?.cancel();
    _speech.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _streamingText.dispose();
    _status.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  void _onAgentEvent(AgentEvent event) {
    if (!mounted) return;
    switch (event) {
      case AgentStatus(:final text):
        if (text.isNotEmpty) _status.value = text;
      case AgentPartialText(:final text):
        if (_busy) {
          _streamingText.value = text;
          _requestStreamScroll();
        }
      case AgentClearText():
        _streamingText.value = '';
    }
  }

  Future<void> _startBlank() async {
    await _agent.startBlankSession();
    await _refreshSessions();
    if (!mounted) return;
    setState(() {
      _messages.clear();
      _suggestions = (List.of(_allSuggestions)..shuffle(Random())).take(4).toList();
    });
  }

  Future<void> _refreshSessions() async {
    final sessions = await _db.getSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _openSession(int sessionId) async {
    if (_busy) await _agent.stop();
    await _agent.openSession(sessionId);
    await _reloadMessages();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _reloadMessages() async {
    final id = _agent.sessionId;
    final rows = id == null ? const <Map<String, dynamic>>[] : await _db.getChatHistory(id);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(rows.map(ChatMessage.fromRow));
    });
    _scrollToBottom(animated: false);
  }

  Future<void> _deleteSession(int sessionId) async {
    final ok = await _confirmDialog('Delete this chat?', 'This can\'t be undone.', action: 'Delete');
    if (!ok) return;
    await _db.deleteSession(sessionId);
    if (_agent.sessionId == sessionId) await _startBlank();
    await _refreshSessions();
  }

  Future<bool> _confirmAction(ToolConfirmation request) async {
    if (!mounted) return false;
    return _confirmDialog(request.title, request.detail, action: 'Allow');
  }

  Future<bool> _confirmDialog(String title, String detail, {required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(title,
            style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 17, fontWeight: FontWeight.w600)),
        content: detail.isEmpty
            ? null
            : Text(detail, style: GoogleFonts.interTight(color: AppTheme.ink2, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.interTight(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action,
                style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ── sending ──────────────────────────────────────────────────────────────

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _textController.text).trim();
    final imagePath = _selectedImagePath;
    if (text.isEmpty && imagePath == null) return;
    if (_listening) await _stopDictation();
    if (_busy) {
      await _agent.stop();
      return;
    }
    _textController.clear();
    setState(() {
      _selectedImagePath = null;
      _messages.add(ChatMessage(text: text, isUser: true, imagePath: imagePath));
      _busy = true;
    });
    _streamingText.value = '';
    _status.value = 'Thinking…';
    _startElapsed();
    _scrollToBottom();

    final reply = await _agent.send(text, imagePath: imagePath);
    _elapsedTimer?.cancel();
    if (!mounted) return;
    final streamed = _streamingText.value.isNotEmpty;
    setState(() {
      _busy = false;
      _messages.add(ChatMessage.fromReply(reply, skipEntrance: streamed));
    });
    _streamingText.value = '';
    _status.value = '';
    _scrollToBottom();
    _refreshSessions();
  }

  void _startElapsed() {
    _elapsedTimer?.cancel();
    _elapsed.value = 0;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) => _elapsed.value++);
  }

  // ── attachments & dictation ─────────────────────────────────────────────

  Future<void> _pickImage() async {
    if (!_agent.supportsImages) {
      _snack(
        '${_agent.target?.label ?? 'This model'} can\'t see images. Use Gemma 4 or a cloud model.',
        action: SnackBarAction(label: 'Switch', onPressed: _showModelSheet),
      );
      return;
    }
    try {
      final image = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
      if (image != null && mounted) setState(() => _selectedImagePath = image.path);
    } catch (e) {
      _snack('Couldn\'t open the gallery: $e');
    }
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      await _stopDictation();
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
        onError: (e) {
          if (mounted) setState(() => _listening = false);
        },
      );
      if (!_speechReady) {
        _snack('Speech recognition isn\'t available. Check the microphone permission.');
        return;
      }
    }
    final base = _textController.text.trim();
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        final words = r.recognizedWords;
        _textController.text = base.isEmpty ? words : '$base $words';
        _textController.selection = TextSelection.collapsed(offset: _textController.text.length);
      },
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation),
      pauseFor: const Duration(seconds: 3),
    );
  }

  Future<void> _stopDictation() async {
    await _speech.stop();
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _openVoiceMode() async {
    if (_busy) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const VoiceModeScreen(), fullscreenDialog: true),
    );
    _agent.confirmHandler = _confirmAction;
    await _reloadMessages();
    await _refreshSessions();
  }

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      action: action,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── model switching ─────────────────────────────────────────────────────

  Future<void> _showModelSheet() async {
    final downloaded = await ModelDownloaderService().downloadedModels();
    final arm64 = await DeviceService().isArm64();
    final cloud = await savedCloudTarget();
    if (!mounted) return;
    final current = _agent.target;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        Widget tile({
          required IconData icon,
          required String title,
          String? subtitle,
          bool selected = false,
          required VoidCallback onTap,
        }) {
          return ListTile(
            leading: Icon(icon, color: selected ? AppTheme.ink : AppTheme.ink2, size: 20),
            title: Text(title,
                style: GoogleFonts.interTight(
                    color: AppTheme.ink, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle, style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 12)),
            trailing: selected ? const Icon(Icons.check_rounded, color: AppTheme.ink, size: 18) : null,
            onTap: onTap,
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('ON THIS PHONE'),
                for (final spec in downloaded.where((s) => arm64 || !s.arm64Only))
                  tile(
                    icon: Icons.smartphone_outlined,
                    title: spec.displayName,
                    subtitle: '${spec.sizeLabel} · private, works offline',
                    selected: current is LocalTarget && current.spec.fileName == spec.fileName,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!(current is LocalTarget && current.spec.fileName == spec.fileName)) {
                        launchAgent(context, LocalTarget(spec));
                      }
                    },
                  ),
                tile(
                  icon: Icons.download_rounded,
                  title: 'Download models…',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ModelPickerScreen()));
                  },
                ),
                const SectionHeader('CLOUD (YOUR API KEY)'),
                if (cloud != null)
                  tile(
                    icon: Icons.cloud_outlined,
                    title: cloud.config.preset.name,
                    subtitle: cloud.config.model,
                    selected: current is CloudTarget,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (current is! CloudTarget) launchAgent(context, cloud);
                    },
                  ),
                tile(
                  icon: Icons.vpn_key_outlined,
                  title: cloud == null ? 'Add an API key…' : 'Change provider or model…',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ApiKeySetupScreen(initialProvider: cloud?.config.providerId),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── scrolling ───────────────────────────────────────────────────────────

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(max, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
      } else {
        _scrollController.jumpTo(max);
      }
    });
  }

  void _requestStreamScroll() {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppTheme.bg,
      drawer: _buildDrawer(),
      onDrawerChanged: (open) {
        if (open) _refreshSessions();
      },
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _messages.isEmpty && !_busy ? _buildEmptyState() : _buildMessageList(),
            ),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final target = _agent.target;
    final isCloud = target?.isCloud ?? false;
    final title = switch (target) {
      LocalTarget(:final spec) => spec.displayName,
      CloudTarget(:final config) => config.preset.shortName,
      null => 'Local Agent',
    };
    final subtitle = switch (target) {
      LocalTarget() => _agent.usingGpu ? 'ON-DEVICE · GPU' : 'ON-DEVICE',
      CloudTarget(:final config) => config.model.toUpperCase(),
      null => '',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Row(
        children: [
          HeaderIconButton(
            icon: Icons.menu_rounded,
            size: 22,
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _busy ? null : _showModelSheet,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(isCloud ? Icons.cloud_outlined : Icons.smartphone_outlined,
                            size: 15, color: AppTheme.ink2),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.interTight(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.3,
                              color: AppTheme.ink,
                            ),
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.muted, size: 18),
                      ],
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.jetBrainsMono(fontSize: 9, letterSpacing: 1.1, color: AppTheme.muted),
                      ),
                  ],
                ),
              ),
            ),
          ),
          HeaderIconButton(
            icon: Icons.edit_outlined,
            size: 19,
            onPressed: () async {
              if (_busy) await _agent.stop();
              await _startBlank();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final target = _agent.target;
    final greeting = switch (target) {
      LocalTarget(:final spec) =>
        'Hi! I\'m running ${spec.displayName} right here on your phone. Ask me something, or tell me what to do.',
      CloudTarget(:final config) =>
        'Hi! I\'m using ${config.preset.name} with your API key. Ask me something, or tell me what to do on your phone.',
      null => 'Hi! How can I help?',
    };
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.only(top: 2, right: 12), child: SparkleIcon(size: 22)),
                Expanded(
                  child: Text(
                    greeting,
                    style: GoogleFonts.interTight(fontSize: 15, height: 1.55, color: AppTheme.ink),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SuggestionsList(suggestions: _suggestions, onSuggestionTap: _send),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: _messages.length + (_busy ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length) {
          return _TypingIndicator(streamingText: _streamingText, status: _status, elapsed: _elapsed);
        }
        return MessageBubble(message: _messages[index]);
      },
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selectedImagePath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 4),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(File(_selectedImagePath!), width: 56, height: 56, fit: BoxFit.cover),
                      ),
                      Positioned(
                        right: -6,
                        top: -6,
                        child: GestureDetector(
                          onTap: () => setState(() => _selectedImagePath = null),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: const Icon(Icons.close_rounded, color: Colors.black, size: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.composerBg,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _circleIcon(Icons.add_rounded, 21, tooltip: 'Attach image', onTap: _busy ? null : _pickImage),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          onTap: () => Future.delayed(const Duration(milliseconds: 300), _scrollToBottom),
                          style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 15),
                          cursorColor: AppTheme.ink,
                          decoration: InputDecoration(
                            hintText: _listening ? 'Listening…' : 'Ask anything…',
                            hintStyle: GoogleFonts.interTight(
                                color: Colors.white.withValues(alpha: 0.4), fontSize: 15),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                          ),
                        ),
                      ),
                      _circleIcon(
                        _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                        19,
                        tooltip: 'Dictate',
                        highlighted: _listening,
                        onTap: _busy ? null : _toggleDictation,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (context, value, _) {
                  final hasInput = value.text.trim().isNotEmpty || _selectedImagePath != null;
                  final mode = _busy ? 0 : (hasInput ? 1 : 2);
                  return Semantics(
                    button: true,
                    label: _busy ? 'Stop' : (hasInput ? 'Send' : 'Voice mode'),
                    child: GestureDetector(
                      onTap: () {
                        if (_busy) {
                          _agent.stop();
                        } else if (hasInput) {
                          _send();
                        } else {
                          _openVoiceMode();
                        }
                      },
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                        child: Container(
                          key: ValueKey(mode),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _busy ? AppTheme.error.withValues(alpha: 0.85) : AppTheme.ink,
                          ),
                          child: Icon(
                            _busy
                                ? Icons.stop_rounded
                                : (hasInput ? Icons.arrow_upward_rounded : Icons.graphic_eq_rounded),
                            color: _busy ? Colors.white : AppTheme.bg,
                            size: 21,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleIcon(IconData icon, double size,
      {required String tooltip, VoidCallback? onTap, bool highlighted = false}) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 48,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Icon(
            icon,
            size: size,
            color: onTap == null ? AppTheme.muted2 : (highlighted ? AppTheme.error : AppTheme.ink),
          ),
        ),
      ),
    );
  }

  String _relativeWhen(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]}';
  }

  Widget _buildDrawer() {
    final filtered = _sessionFilter.isEmpty
        ? _sessions
        : _sessions
            .where((s) => '${s['title']}'.toLowerCase().contains(_sessionFilter.toLowerCase()))
            .toList();
    final target = _agent.target;
    return Drawer(
      backgroundColor: AppTheme.bg,
      width: MediaQuery.of(context).size.width * 0.86,
      shape: const Border(right: BorderSide(color: AppTheme.border)),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Row(
                children: [
                  const BrandMark(size: 36, iconSize: 18, radius: 10),
                  const SizedBox(width: 12),
                  Text(
                    'Local Agent',
                    style: GoogleFonts.interTight(
                        fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded, color: AppTheme.ink, size: 20),
              title: Text('New chat', style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 14)),
              onTap: () async {
                Navigator.pop(context);
                if (_busy) await _agent.stop();
                await _startBlank();
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _sessionFilter = v.trim()),
                style: GoogleFonts.interTight(color: AppTheme.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTheme.muted),
                  hintText: 'Search chats',
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Align(alignment: Alignment.centerLeft, child: Eyebrow('RECENT')),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _sessions.isEmpty ? 'No chats yet.' : 'No chats match.',
                        style: GoogleFonts.interTight(color: AppTheme.muted, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final session = filtered[index];
                        final id = session['id'] as int;
                        final selected = id == _agent.sessionId;
                        final created = DateTime.tryParse('${session['created_at']}');
                        return InkWell(
                          onTap: () => _openSession(id),
                          onLongPress: () => _deleteSession(id),
                          child: Container(
                            color: selected ? AppTheme.surface : Colors.transparent,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${session['title']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.interTight(
                                        fontSize: 13.5, color: selected ? AppTheme.ink : AppTheme.ink2),
                                  ),
                                ),
                                if (created != null)
                                  Text(
                                    _relativeWhen(created),
                                    style: GoogleFonts.jetBrainsMono(
                                        fontSize: 9.5, color: AppTheme.muted2, letterSpacing: 0.4),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_sessions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Long-press a chat to delete it.',
                    style: GoogleFonts.interTight(color: AppTheme.muted2, fontSize: 11)),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
              child: Row(
                children: [
                  Icon(target?.isCloud ?? false ? Icons.cloud_outlined : Icons.smartphone_outlined,
                      size: 16, color: AppTheme.ink2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      target?.isCloud ?? false ? 'CLOUD · YOUR API KEY' : 'ON-DEVICE · PRIVATE',
                      style: GoogleFonts.jetBrainsMono(color: AppTheme.muted, fontSize: 9.5, letterSpacing: 0.6),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined, color: AppTheme.ink2, size: 19),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  final ValueListenable<String> streamingText;
  final ValueListenable<String> status;
  final ValueListenable<int> elapsed;

  const _TypingIndicator({required this.streamingText, required this.status, required this.elapsed});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: streamingText,
      builder: (context, text, _) {
        if (text.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.only(right: 12, top: 2), child: SparkleIcon(size: 20)),
                Expanded(
                  child: Text(text,
                      style: GoogleFonts.interTight(fontSize: 15, color: AppTheme.ink, height: 1.55)),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppTheme.ink, backgroundColor: AppTheme.muted2),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (context, s, _) => Text(
                    s.isEmpty ? 'Thinking…' : s,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.interTight(
                        fontSize: 13, color: AppTheme.muted, fontStyle: FontStyle.italic),
                  ),
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: elapsed,
                builder: (context, secs, _) => secs < 2
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Pill('${secs}s', style: PillStyle.surface, fontSize: 10),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
