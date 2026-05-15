import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';
import '../services/model_downloader_service.dart';
import '../models/chat_message.dart';
import '../widgets/message_bubble.dart';
import '../widgets/suggestions_list.dart';
import 'settings_screen.dart';
import 'voice_mode_screen.dart';


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
  bool _isTyping = false;
  bool _isInitializing = true;
  int? _currentSessionId;
  List<Map<String, dynamic>> _sessions = [];
  String? _selectedImagePath;
  final ImagePicker _picker = ImagePicker();
  // Streaming text lives in a ValueNotifier so per-token updates rebuild only
  // the streaming bubble, not the entire ListView. Same for the thinking
  // indicator's rotating label — both were causing visible jank.
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  final ValueNotifier<bool> _isStreaming = ValueNotifier<bool>(false);
  final ValueNotifier<int> _thinkingIndex = ValueNotifier<int>(0);
  StreamSubscription? _tokenSub;
  Timer? _thinkingTimer;
  late _KeyboardObserver _keyboardObserver;
  final List<String> _thinkingMessages = [
    'Thinking...',
    'Cooking up a response...',
    'Analyzing context...',
    'Manifesting answers...',
    'Gathering local data...',
    'Optimizing inference...',
    'Consulting the neural engine...',
    'Getting ready...',
  ];

  final List<Map<String, dynamic>> _allSuggestions = [
    {'text': 'Download the latest WhatsApp APK', 'icon': Icons.download_rounded},
    {'text': 'Tell me my device info & battery', 'icon': Icons.battery_charging_full_rounded},
    {'text': 'Search for my PDF documents', 'icon': Icons.description_rounded},
    {'text': 'Toggle my device flashlight', 'icon': Icons.flashlight_on_rounded},
    {'text': 'Show me my recent screenshots', 'icon': Icons.image_search_rounded},
    {'text': 'Vibrate my phone for 1 second', 'icon': Icons.vibration_rounded},
    {'text': 'Copy current time to clipboard', 'icon': Icons.content_copy_rounded},
    {'text': 'Check my network connectivity', 'icon': Icons.network_check_rounded},
    {'text': 'List all installed applications', 'icon': Icons.apps_rounded},
    {'text': 'Read the last text I copied', 'icon': Icons.assignment_rounded},
    {'text': 'Set volume level to 50%', 'icon': Icons.volume_up_rounded},
    {'text': 'Find all APK files on my device', 'icon': Icons.folder_zip_rounded},
    {'text': 'Open Play Store for Instagram', 'icon': Icons.shop_rounded},
    {'text': 'Check my available storage space', 'icon': Icons.storage_rounded},
    {'text': 'What was the last file I modified?', 'icon': Icons.history_edu_rounded},
    {'text': 'Launch the Calculator app', 'icon': Icons.calculate_rounded},
    {'text': 'Show my device public IP address', 'icon': Icons.public_rounded},
  ];
  List<Map<String, dynamic>> _currentSuggestions = [];
  bool _isModelAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkModels();
    _initAgent();
    _initSpeech();
    _agentService.statusStream.listen((_) {});

    _tokenSub = _agentService.tokenStream.listen((token) {
      if (!mounted) return;
      if (token == '\x00') {
        _streamingText.value = '';
        _isStreaming.value = true;
      } else if (token == '\x01') {
        // Clean end-of-response: leave text in place so the final ChatMessage
        // slots in without a one-frame gap.
        _isStreaming.value = false;
      } else if (token == '\x02') {
        // Stream cancelled (tool call interrupted) — clear immediately so the
        // partial JSON-ish output doesn't linger while the tool runs.
        _isStreaming.value = false;
        _streamingText.value = '';
      } else {
        _streamingText.value = _streamingText.value + token;
        _scrollToBottom();
      }
    });

    _keyboardObserver = _KeyboardObserver(onKeyboardVisible: _scrollToBottom);
    WidgetsBinding.instance.addObserver(_keyboardObserver);
  }

  void _initSpeech() async {
    await _speechToText.initialize(
      onError: (_) => setState(() {}),
      onStatus: (_) => setState(() {}),
    );
    setState(() {});
  }

  void _startListening() async {
    await _speechToText.listen(
      onResult: (result) {
        setState(() {
          _textController.text = result.recognizedWords;
          if (result.finalResult && _textController.text.isNotEmpty) {
             // Optionally auto-submit: _handleSubmitted(_textController.text);
          }
        });
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
    final available = await downloader.isModelDownloaded("gemma-4-E2B-it.litertlm");
    if (mounted) {
      setState(() {
        _isModelAvailable = available;
      });
    }
  }

  void _startThinkingAnimation() {
    _thinkingTimer?.cancel();
    _thinkingIndex.value = 0;
    _thinkingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || !_isTyping || _isStreaming.value) {
        _stopThinkingAnimation();
        return;
      }
      _thinkingIndex.value =
          (_thinkingIndex.value + 1) % _thinkingMessages.length;
    });
  }

  void _stopThinkingAnimation() {
    _thinkingTimer?.cancel();
    _thinkingTimer = null;
  }

  @override
  void dispose() {
    _thinkingTimer?.cancel();
    _tokenSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _streamingText.dispose();
    _isStreaming.dispose();
    _thinkingIndex.dispose();
    WidgetsBinding.instance.removeObserver(_keyboardObserver);
    super.dispose();
  }

  Future<void> _refreshSessions() async {
    final sessions = await _dbService.getSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
      });
    }
  }

  Future<void> _initAgent() async {
    try {
      await _agentService.initialize(widget.modelFileName);
      final sessions = await _dbService.getSessions();

      await _createNewChat(isInitial: true);
      if (sessions.isNotEmpty) {
        setState(() {
          _sessions = sessions;
          _isInitializing = false;
        });
      } else {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(text: "Failed to initialize agent: $e", isUser: false));
        _isInitializing = false;
      });
    }
  }

  Future<void> _createNewChat({bool isInitial = false}) async {
    final newId = await _dbService.createSession('New Chat');
    _currentSessionId = newId;
    await _agentService.loadSession(newId);
    await _refreshSessions();

    setState(() {
      _messages.clear();
      const greeting = "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?";
      _messages.add(ChatMessage(text: greeting, isUser: false));

      final shuffled = List<Map<String, dynamic>>.from(_allSuggestions)..shuffle();
      _currentSuggestions = shuffled.take(3).toList();

      if (!isInitial) {
        _isInitializing = false;
      }
    });

    // Save greeting to history if it's a new session
    await _dbService.saveMessage('assistant', "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?", newId);
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
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _selectedImagePath = image.path;
      });
      _scrollToBottom();
    }
  }

  void _handleSubmitted(String text) async {
    final imagePath = _selectedImagePath;
    _textController.clear();
    setState(() {
      _selectedImagePath = null;
    });

    if (text.trim().isEmpty && imagePath == null) return;

    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true, imagePath: imagePath));
      _isTyping = true;
    });
    _startThinkingAnimation();

    // Save user message to database
    await _dbService.saveMessage('user', text, _currentSessionId!);

    _scrollToBottom();

    try {
      final session = _sessions.cast<Map<String, dynamic>?>().firstWhere(
        (s) => s?['id'] == _currentSessionId,
        orElse: () => null,
      );
      if (session != null && session['title'] == 'New Chat') {
        final titleText = text.isEmpty ? "Image Query" : text;
        final newTitle = titleText.length > 25 ? '${titleText.substring(0, 22)}...' : titleText;
        await _dbService.updateSessionTitle(_currentSessionId!, newTitle);
        await _refreshSessions();
      }

      final response = await _agentService.sendMessage(text, _currentSessionId!, imagePath: imagePath);
      if (mounted) {
        // The text bubble that just streamed should slot into the same spot
        // without replaying its entrance animation — that swap is what looked
        // like a "full animation glitch at the end".
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
            skipEntrance: hadStreamed,
          ));
        });
        _streamingText.value = '';
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTyping = false;
          _messages.add(ChatMessage(text: "Error: $e", isUser: false));
        });
        _scrollToBottom();
      }
    }
  }

  Future<void> _openVoiceMode() async {
    if (_currentSessionId == null) return;
    // Voice mode shares the current chat session, so when the user closes it
    // their voice turns appear in the regular chat list when they return.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VoiceModeScreen(sessionId: _currentSessionId!),
        fullscreenDialog: true,
      ),
    );
    // After voice mode, refresh the chat by reloading the session — the
    // agent's chat history already has the new turns; we just need the UI to
    // show them.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu_rounded, color: Colors.white70),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: PopupMenuButton<String>(
          color: const Color(0xFF1E1E1E),
          offset: const Offset(0, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Agent',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.5),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white54, size: 20),
            ],
          ),
          onSelected: (value) {
            if (value != widget.modelFileName) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ChatScreen(modelFileName: value)));
            }
          },
          itemBuilder: (context) => [
            if (_isModelAvailable)
              const PopupMenuItem(
                value: "gemma-4-E2B-it.litertlm",
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, color: Colors.blueAccent, size: 20),
                    SizedBox(width: 12),
                    Text('Gemma 4 E2B', style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
          ],
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.history_rounded, size: 20, color: Colors.white70),
            onPressed: () => _createNewChat(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20, color: Colors.white70),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen()));
            },
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: _isInitializing
                ? const _LoadingScreen()
                : Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          itemCount: _messages.length + (_isTyping ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _messages.length && _isTyping) {
                              return _TypingIndicator(
                                streamingText: _streamingText,
                                isStreaming: _isStreaming,
                                thinkingIndex: _thinkingIndex,
                                thinkingMessages: _thinkingMessages,
                              );
                            }
                            return MessageBubble(message: _messages[index]);
                          },
                        ),
                      ),
                      if (_messages.length <= 1 && !_isTyping)
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _textController,
                          builder: (context, value, child) {
                            final bool showSuggestions = value.text.isEmpty;
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 250),
                              opacity: showSuggestions ? 1.0 : 0.0,
                              child: IgnorePointer(
                                ignoring: !showSuggestions,
                                child: SuggestionsList(
                                  suggestions: _currentSuggestions,
                                  onSuggestionTap: _handleSubmitted,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
          ),
          _buildMessageComposer(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.black,
      child: Column(
        children: [
          const SizedBox(height: 60),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 24),
                const SizedBox(width: 12),
                Text('Local Agent', style: GoogleFonts.outfit(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(height: 30),
          ListTile(
            leading: const Icon(Icons.add_rounded, color: Colors.white70),
            title: const Text('New Chat', style: TextStyle(color: Colors.white70)),
            onTap: () {
              Navigator.pop(context);
              _createNewChat();
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text('Recent', style: TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final session = _sessions[index];
                final isSelected = session['id'] == _currentSessionId;
                return ListTile(
                  title: Text(session['title'], style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _switchSession(session['id'] as int),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                );
              },
            ),
          ),
          const Divider(color: Colors.white10),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: Colors.white38),
            title: const Text('Clear History', style: TextStyle(color: Colors.white38, fontSize: 13)),
            onTap: () async {
              await _dbService.clearChatHistory();
              await _createNewChat();
              if (mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMessageComposer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
      color: Colors.black,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedImagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.file(
                            File(_selectedImagePath!),
                            height: 70,
                            width: 70,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: -8,
                          top: -8,
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedImagePath = null),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close_rounded, color: Colors.black, size: 14),
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
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF242424),
                      borderRadius: BorderRadius.circular(26.0),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
                          onPressed: _pickImage,
                        ),
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            textCapitalization: TextCapitalization.sentences,
                            onSubmitted: _handleSubmitted,
                            onTap: () => Future.delayed(const Duration(milliseconds: 300), _scrollToBottom),
                            style: GoogleFonts.outfit(color: Colors.white, fontSize: 17),
                            decoration: InputDecoration(
                              hintText: 'Ask Agent...',
                              hintStyle: GoogleFonts.outfit(color: Colors.white.withValues(alpha: 0.4)),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (_speechToText.isNotListening) {
                              _startListening();
                            } else {
                              _stopListening();
                            }
                          },
                          child: Icon(
                            _speechToText.isNotListening ? Icons.mic_none_rounded : Icons.mic_rounded,
                            color: _speechToText.isNotListening ? Colors.white70 : Colors.blueAccent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _textController,
                  builder: (context, value, child) {
                    final bool hasText = value.text.trim().isNotEmpty || _selectedImagePath != null;
                    final Widget icon;
                    final Color iconBg;

                    if (_isTyping) {
                      icon = const Icon(Icons.stop_rounded, color: Colors.white, size: 24);
                      iconBg = Colors.red.withValues(alpha: 0.8);
                    } else if (hasText) {
                      icon = const Icon(Icons.arrow_upward_rounded, color: Colors.black, size: 24);
                      iconBg = Colors.white;
                    } else {
                      icon = const Icon(Icons.graphic_eq_rounded, color: Colors.black, size: 20);
                      iconBg = Colors.white;
                    }

                    return GestureDetector(
                      onTap: () {
                        if (_isTyping) {
                          setState(() => _isTyping = false);
                        } else if (hasText) {
                          _handleSubmitted(_textController.text);
                        } else {
                          _openVoiceMode();
                        }
                      },
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return ScaleTransition(scale: animation, child: child);
                        },
                        child: Container(
                          key: ValueKey<int>(_isTyping ? 0 : (hasText ? 1 : 2)),
                          height: 48,
                          width: 48,
                          decoration: BoxDecoration(
                            color: iconBg,
                            shape: BoxShape.circle,
                          ),
                          child: icon,
                        ),
                      ),
                    );
                  },
                ),
              ],
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

/// Last item in the chat list while the agent is working.
///
/// Subscribes only to the three ValueNotifiers it needs — token updates and
/// the rotating "Thinking..." label don't rebuild the parent ListView.
class _TypingIndicator extends StatelessWidget {
  final ValueListenable<String> streamingText;
  final ValueListenable<bool> isStreaming;
  final ValueListenable<int> thinkingIndex;
  final List<String> thinkingMessages;

  const _TypingIndicator({
    required this.streamingText,
    required this.isStreaming,
    required this.thinkingIndex,
    required this.thinkingMessages,
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
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(right: 12.0, top: 4),
                      child: Icon(Icons.auto_awesome_rounded,
                          size: 20, color: Colors.white),
                    ),
                    Flexible(
                      child: Text(
                        text,
                        style: GoogleFonts.outfit(
                            fontSize: 17, color: Colors.white, height: 1.5),
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
                builder: (context, idx, _) => Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      thinkingMessages[idx],
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.4),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Loading state shown while the model is being mapped into memory on the
/// first chat open (or after Android killed the process while backgrounded).
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF3B82F6).withValues(alpha: 0.25),
                  const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                ],
              ),
              border: Border.all(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.4)),
            ),
            child: const Center(
              child: Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 28),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Loading model...',
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'First open can take a few seconds',
            style: GoogleFonts.outfit(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

