import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/agent_service.dart';
import 'screens/onboarding_screen.dart';
import 'screens/api_setup_screen.dart';
import 'package:flutter/services.dart';
import 'services/database_service.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  
  final prefs = await SharedPreferences.getInstance();
  
  // Try to get the key from .env first, then fallback to SharedPreferences
  String? apiKey = dotenv.env['GROQ_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    apiKey = prefs.getString('api_key');
  }
  
  final hasApiKey = apiKey != null && apiKey.isNotEmpty;

  runApp(LocalAgentApp(hasApiKey: hasApiKey));
}

class LocalAgentApp extends StatelessWidget {
  final bool hasApiKey;
  const LocalAgentApp({super.key, required this.hasApiKey});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Agent',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white70,
          surface: Color(0xFF171717),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: hasApiKey ? const ChatScreen() : const OnboardingScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final String? imagePath;

  ChatMessage({required this.text, required this.isUser, this.imagePath});
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _initAgent();
    _agentService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _currentStatus = status;
        });
      }
    });

    // Handle keyboard visibility for auto-scroll
    WidgetsBinding.instance.addObserver(_KeyboardObserver(onKeyboardVisible: () {
      _scrollToBottom();
    }));
  }

  @override
  void dispose() {
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
      await _agentService.initialize();
      await _refreshSessions();
      
      if (_sessions.isNotEmpty) {
        _currentSessionId = _sessions.first['id'] as int;
        await _agentService.loadSession(_currentSessionId!);
        final history = await _dbService.getChatHistory(_currentSessionId!);
        setState(() {
          _messages.clear();
          for (var msg in history) {
            _messages.add(ChatMessage(
              text: msg['content'] as String,
              isUser: (msg['role'] as String) == 'user',
            ));
          }
          _isInitializing = false;
        });
      } else {
        await _createNewChat(isInitial: true);
      }
      _scrollToBottom();
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
      _messages.add(ChatMessage(text: "Hello! I'm your local AI agent. I have loaded my tools. How can I help you today?", isUser: false));
      if (!isInitial) {
        _isInitializing = false;
      }
    });
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
    Navigator.pop(context); // Close drawer
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

    _scrollToBottom();

    // Send to agent
    try {
      // If session title is 'New Chat', update it with the first 20 chars of prompt
      final session = _sessions.firstWhere((s) => s['id'] == _currentSessionId);
      if (session['title'] == 'New Chat') {
        final titleText = text.isEmpty ? "Image Query" : text;
        final newTitle = titleText.length > 25 ? '${titleText.substring(0, 22)}...' : titleText;
        await _dbService.updateSessionTitle(_currentSessionId!, newTitle);
        await _refreshSessions();
      }

      final response = await _agentService.sendMessage(text, _currentSessionId!, imagePath: imagePath);
      if (mounted) {
        setState(() {
          _isTyping = false;
          _messages.add(ChatMessage(text: response, isUser: false));
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
      appBar: AppBar(
        title: Text(
          'Local Agent',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ApiSetupScreen()),
              );
            },
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message);
              },
            ),
          ),
          if (_isInitializing)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8A2BE2)))),
            ),
          if (_isTyping && !_isInitializing)
            Padding(
              padding: const EdgeInsets.only(left: 24.0, bottom: 8.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00FFCC)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _currentStatus.isNotEmpty ? _currentStatus : 'Thinking...',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                    ),
                  ],
                ),
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
                Text(
                  'Local Agent',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
                  title: Text(
                    session['title'],
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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

  Widget _buildMessageBubble(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser)
            const Padding(
              padding: EdgeInsets.only(right: 12.0, top: 4),
              child: Icon(Icons.auto_awesome_rounded, size: 20, color: Colors.white),
            ),
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: message.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: message.isUser ? const Color(0xFF2F2F2F) : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.imagePath != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(message.imagePath!),
                            width: 200,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    message.isUser
                        ? Text(
                            message.text,
                            style: const TextStyle(fontSize: 16, color: Colors.white),
                          )
                        : MarkdownBody(
                        data: message.text,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(fontSize: 16, color: Colors.white, height: 1.6),
                          strong: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                          code: TextStyle(
                            backgroundColor: Colors.white.withValues(alpha: 0.1),
                            fontFamily: 'monospace',
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (message.isUser)
            const SizedBox(width: 40), // Spacing for user alignment
        ],
      ),
    );
  }

  Widget _buildMessageComposer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      color: Colors.black,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedImagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(_selectedImagePath!),
                            height: 80,
                            width: 80,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: -5,
                          top: -5,
                          child: IconButton(
                            icon: const Icon(Icons.cancel, color: Colors.white70, size: 20),
                            onPressed: () => setState(() => _selectedImagePath = null),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined, color: Colors.white60),
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF171717),
                      borderRadius: BorderRadius.circular(30.0),
                    ),
                    child: TextField(
                      controller: _textController,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: _handleSubmitted,
                      onTap: () {
                        Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
                      },
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'Message Agent...',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8.0),
                IconButton(
                  icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 28),
                  onPressed: () => _handleSubmitted(_textController.text),
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
  void didChangeMetrics() {
    onKeyboardVisible();
  }
}
