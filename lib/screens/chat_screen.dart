import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/chat_message.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';
import '../services/model_downloader_service.dart';
import '../services/model_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import '../widgets/message_bubble.dart';
import '../widgets/suggestions_list.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'splash_screen.dart';
import 'voice_mode_screen.dart';

/// 05/06/07 · Chat — empty state, streaming, sessions drawer.
class ChatScreen extends StatefulWidget {
  final String modelFileName;
  const ChatScreen({super.key, required this.modelFileName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AgentService _agentService = AgentService();
  final DatabaseService _dbService = DatabaseService();
  final SpeechToText _speechToText = SpeechToText();
  final ImagePicker _picker = ImagePicker();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isTyping = false;
  bool _isInitializing = true;
  int? _currentSessionId;
  List<Map<String, dynamic>> _sessions = [];
  String? _selectedImagePath;
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  final ValueNotifier<bool> _isStreaming = ValueNotifier<bool>(false);
  final ValueNotifier<int> _thinkingIndex = ValueNotifier<int>(0);
  final ValueNotifier<int> _typingSeconds = ValueNotifier<int>(0);
  StreamSubscription? _tokenSub;
  Timer? _thinkingTimer;
  Timer? _typingTimer;
  bool _scrollPending = false;
  late _KeyboardObserver _keyboardObserver;

  final List<String> _thinkingMessages = [
    'Thinking',
    'Cooking up a response',
    'Analyzing context',
    'Manifesting answers',
    'Gathering local data',
    'Optimizing inference',
    'Consulting the neural engine',
    'Getting ready',
  ];

  final List<Map<String, dynamic>> _allSuggestions = [
    {'text': 'Download the latest WhatsApp APK', 'icon': Icons.download_rounded},
    {'text': 'Tell me my device info & battery', 'icon': Icons.battery_charging_full_rounded},
    {'text': 'Search for my PDF documents', 'icon': Icons.description_outlined},
    {'text': 'Toggle my device flashlight', 'icon': Icons.flashlight_on_rounded},
    {'text': 'Show me my recent screenshots', 'icon': Icons.image_search_rounded},
    {'text': 'Vibrate my phone for 1 second', 'icon': Icons.vibration_rounded},
    {'text': 'Check my network connectivity', 'icon': Icons.network_check_rounded},
    {'text': 'List all installed applications', 'icon': Icons.apps_rounded},
    {'text': 'Set volume level to 50%', 'icon': Icons.volume_up_rounded},
    {'text': 'Find all APK files on my device', 'icon': Icons.folder_zip_outlined},
  ];
  List<Map<String, dynamic>> _currentSuggestions = [];
  final Map<String, bool> _installedModels = {};
  ModelSpec get _currentSpec => ModelRegistry.byFileName(widget.modelFileName);
  bool get _isCloud => widget.modelFileName == kCloudModelSentinel;
  String get _headerName =>
      _isCloud ? 'Gemini 2.5 Flash' : _currentSpec.displayName;
  bool get _supportsVision => _isCloud || _currentSpec.supportsVision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initAgent();
      _checkModels();
    });
    _agentService.statusStream.listen((_) {});
    _tokenSub = _agentService.tokenStream.listen((token) {
      if (!mounted) return;
      if (token == '\x00') {
        _streamingText.value = '';
        _isStreaming.value = true;
      } else if (token == '\x01') {
        _isStreaming.value = false;
      } else if (token == '\x02') {
        _isStreaming.value = false;
        _streamingText.value = '';
      } else {
        _streamingText.value = _streamingText.value + token;
        _requestStreamScroll();
      }
    });
    _keyboardObserver = _KeyboardObserver(onKeyboardVisible: _scrollToBottom);
    WidgetsBinding.instance.addObserver(_keyboardObserver);
  }

  bool _speechReady = false;
  Future<bool> _ensureSpeechReady() async {
    if (_speechReady) return true;
    _speechReady = await _speechToText.initialize(
      onError: (_) => setState(() {}),
      onStatus: (_) => setState(() {}),
    );
    if (mounted) setState(() {});
    return _speechReady;
  }

  void _startListening() async {
    if (!await _ensureSpeechReady()) return;
    await _speechToText.listen(
      onResult: (result) {
        setState(() => _textController.text = result.recognizedWords);
      },
    );
    setState(() {});
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() {});
  }

  void _checkModels() async {
    final downloader = ModelDownloaderService();
    final installed = <String, bool>{};
    for (final spec in ModelRegistry.all) {
      installed[spec.fileName] =
          await downloader.isModelDownloaded(spec.fileName);
    }
    if (!mounted) return;
    setState(() {
      _installedModels
        ..clear()
        ..addAll(installed);
    });
  }

  void _startThinkingAnimation() {
    _thinkingTimer?.cancel();
    _typingTimer?.cancel();
    _thinkingIndex.value = 0;
    _typingSeconds.value = 0;
    _thinkingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || !_isTyping || _isStreaming.value) {
        _stopThinkingAnimation();
        return;
      }
      _thinkingIndex.value =
          (_thinkingIndex.value + 1) % _thinkingMessages.length;
    });
    _typingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_isTyping) {
        _stopThinkingAnimation();
        return;
      }
      _typingSeconds.value = _typingSeconds.value + 1;
    });
  }

  void _stopThinkingAnimation() {
    _thinkingTimer?.cancel();
    _thinkingTimer = null;
    _typingTimer?.cancel();
    _typingTimer = null;
  }

  @override
  void dispose() {
    _thinkingTimer?.cancel();
    _typingTimer?.cancel();
    _tokenSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _streamingText.dispose();
    _isStreaming.dispose();
    _thinkingIndex.dispose();
    _typingSeconds.dispose();
    WidgetsBinding.instance.removeObserver(_keyboardObserver);
    super.dispose();
  }

  Future<void> _refreshSessions() async {
    final sessions = await _dbService.getSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _initAgent() async {
    try {
      await _agentService.initialize(widget.modelFileName);
      if (!_isCloud) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_used_model_file', widget.modelFileName);
      }
      await _createNewChat(isInitial: true);
      setState(() => _isInitializing = false);
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(text: "Failed to initialize agent: $e", isUser: false));
        _isInitializing = false;
      });
    }
  }

  Future<void> _createNewChat({bool isInitial = false}) async {
    final sessions = await _dbService.getSessions();
    for (var s in sessions) {
      if (s['title'] == 'New Chat') {
        await _dbService.deleteSession(s['id'] as int);
      }
    }
    final newId = await _dbService.createSession('New Chat');
    _currentSessionId = newId;
    await _agentService.loadSession(newId);
    await _refreshSessions();
    setState(() {
      _messages.clear();
      const greeting =
          "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?";
      _messages.add(ChatMessage(text: greeting, isUser: false));
      final shuffled = List<Map<String, dynamic>>.from(_allSuggestions)..shuffle();
      _currentSuggestions = shuffled.take(4).toList();
      if (!isInitial) _isInitializing = false;
    });
    await _dbService.saveMessage(
        'assistant',
        "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?",
        newId);
  }

  Future<void> _switchSession(int sessionId) async {
    _currentSessionId = sessionId;
    await _agentService.loadSession(sessionId);
    final history = await _dbService.getChatHistory(sessionId);
    setState(() {
      _messages.clear();
      for (var msg in history) {
        _messages.add(ChatMessage(
          text: msg['content'] as String,
          isUser: (msg['role'] as String) == 'user',
        ));
      }
    });
    _scrollToBottom();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickImage() async {
    if (!_supportsVision) {
      _promptVisionSwitch();
      return;
    }
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() => _selectedImagePath = image.path);
      _scrollToBottom();
    }
  }

  void _promptVisionSwitch() {
    final visionSpec = ModelRegistry.all.firstWhere(
      (s) => s.supportsVision,
      orElse: () => _currentSpec,
    );
    if (visionSpec.id == _currentSpec.id) return;
    final isInstalled = _installedModels[visionSpec.fileName] ?? false;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Images need ${visionSpec.displayName}',
          style: GoogleFonts.interTight(
              color: AppTheme.ink, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          isInstalled
              ? '${_currentSpec.displayName} is text-only. Switch to ${visionSpec.displayName} to attach images?'
              : '${_currentSpec.displayName} is text-only. ${visionSpec.displayName} (${visionSpec.sizeLabel}) supports vision — download it now?',
          style: GoogleFonts.interTight(color: AppTheme.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Not now',
                style: GoogleFonts.interTight(color: AppTheme.muted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (isInstalled) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        SplashScreen(modelFileName: visionSpec.fileName),
                  ),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HomeScreen()),
                );
              }
            },
            child: Text(
              isInstalled ? 'Switch' : 'Download',
              style: GoogleFonts.interTight(color: AppTheme.ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _handleSubmitted(String text) async {
    final imagePath = _selectedImagePath;
    _textController.clear();
    setState(() => _selectedImagePath = null);
    if (text.trim().isEmpty && imagePath == null) return;

    if (_isTyping) {
      await _agentService.stopGeneration();
      while (_isTyping && mounted) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (!mounted) return;
    }
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true, imagePath: imagePath));
      _isTyping = true;
    });
    _startThinkingAnimation();
    await _dbService.saveMessage('user', text, _currentSessionId!);
    _scrollToBottom();

    try {
      final session = _sessions.cast<Map<String, dynamic>?>().firstWhere(
            (s) => s?['id'] == _currentSessionId,
            orElse: () => null,
          );
      if (session != null && session['title'] == 'New Chat') {
        String titleText = text.isEmpty ? "Image Query" : text.trim();
        final prefixes = ['can you ', 'how do i ', 'what is ', 'write a ', 'create a ', 'help me ', 'please ', 'tell me '];
        for (final p in prefixes) {
          if (titleText.toLowerCase().startsWith(p)) {
            titleText = titleText.substring(p.length);
          }
        }
        if (titleText.isNotEmpty) {
          titleText = titleText[0].toUpperCase() + titleText.substring(1);
        }
        final words = titleText.split(RegExp(r'\s+'));
        final newTitle = words.take(4).join(' ') + (words.length > 4 ? '...' : '');
        await _dbService.updateSessionTitle(_currentSessionId!, newTitle);
        await _refreshSessions();
      }
      final response = await _agentService.sendMessage(text, _currentSessionId!, imagePath: imagePath);
      if (mounted) {
        final hadStreamed = _streamingText.value.isNotEmpty;
        setState(() {
          _isTyping = false;
          _messages.add(ChatMessage(
            text: response.text,
            isUser: false,
            modelName: response.modelName,
            retryCount: response.retryCount,
            tps: response.tps,
            evalTime: response.evalTime,
            toolName: response.toolName,
            imagePath: response.imagePath,
            skipEntrance: hadStreamed,
          ));
        });
        _streamingText.value = '';
        _scrollToBottom();
      }
    } catch (e, st) {
      debugPrint('ChatScreen.sendMessage failed: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        setState(() {
          _isTyping = false;
          _messages.add(ChatMessage(text: _humanizeError(e), isUser: false));
        });
        _scrollToBottom();
      }
    }
  }

  String _humanizeError(Object err) {
    final s = err.toString();
    if (s.contains('Previous invocation')) return "I was still finishing the last reply. Try sending that again.";
    if (s.contains('Model not initialized')) return "The model isn't loaded yet. Give it a moment and try again.";
    if (s.contains('Model file not found')) return "I couldn't find the model on disk — please re-download it from the home screen.";
    if (s.contains('SocketException') || s.contains('Failed host lookup')) return "Looks like the network is down — that tool needs an internet connection.";
    if (s.contains('PlatformException') || s.contains('IllegalStateException')) return "Something went wrong with the on-device inference. Try sending that again.";
    return "Something went wrong. Try again.";
  }

  Future<void> _openVoiceMode() async {
    if (_currentSessionId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VoiceModeScreen(sessionId: _currentSessionId!),
        fullscreenDialog: true,
      ),
    );
    if (!mounted || _currentSessionId == null) return;
    final history = await _dbService.getChatHistory(_currentSessionId!);
    setState(() {
      _messages.clear();
      for (var msg in history) {
        _messages.add(ChatMessage(
          text: msg['content'] as String,
          isUser: (msg['role'] as String) == 'user',
        ));
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
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

  bool get _showEmptyState =>
      _messages.length == 1 && !_messages.first.isUser && !_isTyping;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppTheme.bg,
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isInitializing
                  ? const _ChatBootstrapping()
                  : _showEmptyState
                      ? _buildEmptyState()
                      : _buildMessageList(),
            ),
            if (!_isInitializing) _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          HeaderIconButton(
            icon: Icons.menu_rounded,
            size: 22,
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Expanded(
            child: Center(child: _headerTitle()),
          ),
          HeaderIconButton(
            icon: Icons.edit_outlined,
            size: 18,
            onPressed: () async {
              try {
                await _agentService.stopGeneration();
              } catch (_) {}
              _createNewChat();
            },
          ),
          HeaderIconButton(
            icon: Icons.settings_outlined,
            size: 18,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerTitle() {
    if (_isCloud) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _headerName,
            style: GoogleFonts.interTight(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(width: 8),
          const Pill('CLOUD', style: PillStyle.outline),
        ],
      );
    }
    return PopupMenuButton<String>(
      color: AppTheme.surface,
      offset: const Offset(0, 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.border),
      ),
      onSelected: (value) {
        if (value == '__manage__') {
          Navigator.push(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
          return;
        }
        if (value != widget.modelFileName) {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SplashScreen(modelFileName: value)));
        }
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];
        for (final spec in ModelRegistry.all) {
          if (_installedModels[spec.fileName] != true) continue;
          final isCurrent = spec.fileName == widget.modelFileName;
          items.add(PopupMenuItem(
            value: spec.fileName,
            child: Row(
              children: [
                Icon(spec.supportsVision ? Icons.auto_awesome_rounded : Icons.bolt_rounded,
                    color: isCurrent ? AppTheme.ink : AppTheme.ink2, size: 18),
                const SizedBox(width: 12),
                Text(spec.displayName,
                    style: GoogleFonts.interTight(
                        color: AppTheme.ink,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500)),
              ],
            ),
          ));
        }
        if (items.isNotEmpty) items.add(const PopupMenuDivider());
        items.add(PopupMenuItem(
          value: '__manage__',
          child: Row(
            children: [
              const Icon(Icons.download_rounded, color: AppTheme.ink2, size: 18),
              const SizedBox(width: 12),
              Text('Manage models', style: GoogleFonts.interTight(color: AppTheme.ink)),
            ],
          ),
        ));
        return items;
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _headerName,
            style: GoogleFonts.interTight(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.keyboard_arrow_down_rounded,
              color: AppTheme.muted, size: 18),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Greeting
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 12),
                  child: SparkleIcon(size: 22),
                ),
                Expanded(
                  child: Text(
                    "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?",
                    style: GoogleFonts.interTight(
                      fontSize: 15,
                      height: 1.55,
                      color: AppTheme.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SuggestionsList(
            suggestions: _currentSuggestions,
            onSuggestionTap: _handleSubmitted,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      itemCount: _messages.length + (_isTyping ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length && _isTyping) {
          return _TypingIndicator(
            streamingText: _streamingText,
            isStreaming: _isStreaming,
            thinkingIndex: _thinkingIndex,
            thinkingMessages: _thinkingMessages,
            typingSeconds: _typingSeconds,
          );
        }
        return MessageBubble(message: _messages[index]);
      },
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
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
                        child: Image.file(
                          File(_selectedImagePath!),
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: -6,
                        top: -6,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _selectedImagePath = null),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                                color: Colors.white, shape: BoxShape.circle),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.black, size: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.composerBg,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      _circleIcon(Icons.add_rounded, 20, onTap: _pickImage),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          textCapitalization: TextCapitalization.sentences,
                          onSubmitted: _handleSubmitted,
                          onTap: () => Future.delayed(
                              const Duration(milliseconds: 300), _scrollToBottom),
                          style: GoogleFonts.interTight(
                            color: AppTheme.ink,
                            fontSize: 15,
                          ),
                          cursorColor: AppTheme.ink,
                          decoration: InputDecoration(
                            hintText: 'Ask Agent...',
                            hintStyle: GoogleFonts.interTight(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 15,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      _circleIcon(
                        _speechToText.isNotListening
                            ? Icons.mic_none_rounded
                            : Icons.mic_rounded,
                        18,
                        onTap: () => _speechToText.isNotListening
                            ? _startListening()
                            : _stopListening(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (context, value, child) {
                  final hasText = value.text.trim().isNotEmpty ||
                      _selectedImagePath != null;
                  return GestureDetector(
                    onTap: () {
                      if (_isTyping) {
                        _agentService.stopGeneration();
                      } else if (hasText) {
                        _handleSubmitted(_textController.text);
                      } else {
                        _openVoiceMode();
                      }
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) =>
                          ScaleTransition(scale: anim, child: child),
                      child: Container(
                        key: ValueKey<int>(
                            _isTyping ? 0 : (hasText ? 1 : 2)),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isTyping
                              ? AppTheme.error.withValues(alpha: 0.85)
                              : AppTheme.ink,
                        ),
                        child: Icon(
                          _isTyping
                              ? Icons.stop_rounded
                              : hasText
                                  ? Icons.arrow_upward_rounded
                                  : Icons.mic_rounded,
                          color: _isTyping ? Colors.white : AppTheme.bg,
                          size: _isTyping ? 18 : 20,
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

  Widget _circleIcon(IconData icon, double size, {required VoidCallback onTap}) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Icon(icon, size: size, color: AppTheme.ink),
        ),
      ),
    );
  }

  String _relativeWhen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 2) return 'yesterday';
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[t.weekday - 1];
    }
    return '${t.day} ${_monthShort(t.month)}';
  }

  String _monthShort(int m) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[m - 1];
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: AppTheme.bg,
      width: MediaQuery.of(context).size.width * 0.86,
      shape: const Border(
          right: BorderSide(color: AppTheme.border)),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
              child: Row(
                children: [
                  const BrandMark(size: 36, iconSize: 18, radius: 10),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Local Agent',
                        style: GoogleFonts.interTight(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          color: AppTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Eyebrow(_headerName.toUpperCase()),
                    ],
                  ),
                ],
              ),
            ),
            _drawerItem(
              icon: Icons.add_rounded,
              label: 'New Chat',
              selected: true,
              onTap: () {
                Navigator.pop(context);
                _createNewChat();
              },
            ),
            _drawerItem(
              icon: Icons.search_rounded,
              label: 'Search chats',
              selected: false,
              onTap: () => Navigator.pop(context),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Eyebrow('RECENT'),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final isSelected = session['id'] == _currentSessionId;
                  DateTime? createdAt;
                  try {
                    final ts = session['created_at'];
                    if (ts is int) {
                      createdAt = DateTime.fromMillisecondsSinceEpoch(ts);
                    } else if (ts is String) {
                      createdAt = DateTime.tryParse(ts);
                    }
                  } catch (_) {}
                  return InkWell(
                    onTap: () => _switchSession(session['id'] as int),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 11),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              session['title'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.interTight(
                                fontSize: 13.5,
                                color: isSelected
                                    ? AppTheme.ink
                                    : AppTheme.ink2,
                              ),
                            ),
                          ),
                          if (createdAt != null)
                            Text(
                              _relativeWhen(createdAt),
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: 9.5,
                                color: AppTheme.muted2,
                                letterSpacing: 0.4,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.border)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppTheme.surface2,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'SD',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10,
                        color: AppTheme.ink2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'shantosh',
                          style: GoogleFonts.interTight(
                            color: AppTheme.ink2,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _isCloud ? 'CLOUD · ONLINE' : 'LOCAL · OFFLINE',
                          style: GoogleFonts.jetBrainsMono(
                            color: AppTheme.muted,
                            fontSize: 9.5,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined,
                        color: AppTheme.ink2, size: 18),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()),
                      );
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

  Widget _drawerItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppTheme.surface : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: selected ? AppTheme.ink : AppTheme.ink2),
            const SizedBox(width: 14),
            Text(
              label,
              style: GoogleFonts.interTight(
                fontSize: 14,
                color: selected ? AppTheme.ink : AppTheme.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyboardObserver extends WidgetsBindingObserver {
  final VoidCallback onKeyboardVisible;
  _KeyboardObserver({required this.onKeyboardVisible});
  @override
  void didChangeMetrics() => onKeyboardVisible();
}

class _TypingIndicator extends StatelessWidget {
  final ValueListenable<String> streamingText;
  final ValueListenable<bool> isStreaming;
  final ValueListenable<int> thinkingIndex;
  final List<String> thinkingMessages;
  final ValueListenable<int> typingSeconds;

  const _TypingIndicator({
    required this.streamingText,
    required this.isStreaming,
    required this.thinkingIndex,
    required this.thinkingMessages,
    required this.typingSeconds,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isStreaming,
      builder: (context, streaming, _) {
        return ValueListenableBuilder<String>(
          valueListenable: streamingText,
          builder: (context, text, __) {
            if (text.isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(right: 12, top: 2),
                      child: SparkleIcon(size: 20),
                    ),
                    Expanded(
                      child: Text(
                        text,
                        style: GoogleFonts.interTight(
                          fontSize: 15,
                          color: AppTheme.ink,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
              child: ValueListenableBuilder<int>(
                valueListenable: thinkingIndex,
                builder: (context, idx, _) => ValueListenableBuilder<int>(
                  valueListenable: typingSeconds,
                  builder: (context, secs, __) => Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppTheme.ink,
                          backgroundColor: AppTheme.muted2,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${thinkingMessages[idx]}…',
                        style: GoogleFonts.interTight(
                          fontSize: 13,
                          color: AppTheme.muted,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      if (secs > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${secs}s',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10,
                              color: AppTheme.ink2,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ChatBootstrapping extends StatelessWidget {
  const _ChatBootstrapping();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: AppTheme.muted,
        ),
      ),
    );
  }
}
