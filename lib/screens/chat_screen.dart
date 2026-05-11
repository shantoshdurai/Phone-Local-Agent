import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../services/agent_service.dart';
import '../services/database_service.dart';
import '../services/model_downloader_service.dart';
import '../models/chat_message.dart';
import '../widgets/message_bubble.dart';
import '../widgets/suggestions_list.dart';
import 'home_screen.dart';


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
  bool _isTyping = false;
  bool _isInitializing = true;
  String _currentStatus = '';
  int? _currentSessionId;
  List<Map<String, dynamic>> _sessions = [];
  String? _selectedImagePath;
  final ImagePicker _picker = ImagePicker();
  String _streamingText = '';        // live accumulating text
  bool _isStreaming = false;         // showing the streaming bubble
  StreamSubscription? _tokenSub;

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
  bool _is15BAvailable = false;
  bool _is05BAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkModels();
    _initAgent();
    _agentService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _currentStatus = status;
        });
      }
    });

    _tokenSub = _agentService.tokenStream.listen((token) {
      if (!mounted) return;
      if (token == '\x00') {
        // Start: show empty streaming bubble
        setState(() {
          _isStreaming = true;
          _streamingText = '';
        });
      } else if (token == '\x01') {
        // Done streaming, bubble will be replaced by the final ChatMessage
        setState(() {
          _isStreaming = false;
          _streamingText = '';
        });
      } else {
        setState(() {
          _streamingText += token;
        });
        _scrollToBottom();
      }
    });

    WidgetsBinding.instance.addObserver(_KeyboardObserver(onKeyboardVisible: () {
      _scrollToBottom();
    }));
  }

  void _checkModels() async {
    final downloader = ModelDownloaderService();
    final b15 = await downloader.isModelDownloaded("qwen2.5-1.5b-instruct-q4_k_m.gguf");
    final b05 = await downloader.isModelDownloaded("qwen2.5-0.5b-instruct-q4_k_m.gguf");
    if (mounted) {
      setState(() {
        _is15BAvailable = b15;
        _is05BAvailable = b05;
      });
    }
  }

  @override
  void dispose() {
    _tokenSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
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
    Navigator.pop(context);
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
        setState(() {
          _isTyping = false;
          _messages.add(ChatMessage(
            text: response.text, 
            isUser: false,
            modelName: response.modelName,
            retryCount: response.retryCount,
            tps: response.tps,
            evalTime: response.evalTime,
          ));
        });
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
                widget.modelFileName.contains('1.5b') ? 'Qwen 1.5B' : 'Qwen 0.5B Lite',
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
            if (_is15BAvailable)
              PopupMenuItem(
                value: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                child: Row(
                  children: [
                    Icon(Icons.memory_rounded, color: widget.modelFileName.contains('1.5b') ? Colors.blueAccent : Colors.white70, size: 20),
                    const SizedBox(width: 12),
                    Text('Qwen 1.5B', style: TextStyle(color: widget.modelFileName.contains('1.5b') ? Colors.blueAccent : Colors.white, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            if (_is05BAvailable)
              PopupMenuItem(
                value: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
                child: Row(
                  children: [
                    Icon(Icons.bolt_rounded, color: widget.modelFileName.contains('0.5b') ? Colors.blueAccent : Colors.white70, size: 20),
                    const SizedBox(width: 12),
                    Text('Qwen 0.5B Lite', style: TextStyle(color: widget.modelFileName.contains('0.5b') ? Colors.blueAccent : Colors.white, fontWeight: FontWeight.w500)),
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
              Navigator.push(context, MaterialPageRoute(builder: (context) => const HomeScreen()));
            },
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: _isInitializing
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          itemCount: _messages.length + (_isTyping ? 1 : 0),
                          itemBuilder: (context, index) {
                            // Show thinking indicator as the last item in the list
                            if (index == _messages.length && _isTyping) {
                              if (_isStreaming && _streamingText.isNotEmpty) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.only(right: 12.0, top: 4),
                                        child: Icon(Icons.auto_awesome_rounded, size: 20, color: Colors.white),
                                      ),
                                      Flexible(
                                        child: Text(
                                          _streamingText,
                                          style: GoogleFonts.outfit(fontSize: 17, color: Colors.white, height: 1.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 12, height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: Colors.white.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Thinking...',
                                      style: GoogleFonts.outfit(
                                        fontSize: 13,
                                        color: Colors.white.withValues(alpha: 0.4),
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                ),
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
              Navigator.pop(context);
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
                        const Icon(Icons.mic_none_rounded, color: Colors.white70, size: 22),
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
                        } else {
                          _handleSubmitted(_textController.text);
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

class _BouncingDots extends StatefulWidget {
  const _BouncingDots();

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots> with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) {
      return AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
    });

    _animations = _controllers.map((c) {
      return Tween<double>(begin: 0, end: -6).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      );
    }).toList();

    // Stagger the animations
    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 180), () {
        if (mounted) _controllers[i].repeat(reverse: true);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _animations[i],
          builder: (context, child) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              child: Transform.translate(
                offset: Offset(0, _animations[i].value),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.white54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
