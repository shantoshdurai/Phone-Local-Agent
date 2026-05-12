import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:fllama/fllama.dart';
import 'package:fllama/fllama_type.dart';
import 'model_downloader_service.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'database_service.dart';
import 'app_service.dart';
import 'utility_service.dart';
import 'personal_service.dart';
import 'search_service.dart';

class AgentResponse {
  final String text;
  final String modelName;
  final int retryCount;
  final double? tps;
  final double? evalTime;
  AgentResponse(this.text, this.modelName, this.retryCount, {this.tps, this.evalTime});
}

class AgentService {
  static final AgentService _instance = AgentService._internal();
  factory AgentService() => _instance;
  AgentService._internal();

  final DeviceService _deviceService = DeviceService();
  final FileService _fileService = FileService();
  final DatabaseService _dbService = DatabaseService();
  final AppService _appService = AppService();
  final UtilityService _utilityService = UtilityService();
  final PersonalService _personalService = PersonalService();
  final SearchService _searchService = SearchService();

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final _tokenStreamController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenStreamController.stream;

  String? _modelPath;
  double? _contextId;
  final List<Map<String, String>> _messages = [];
  StreamSubscription? _tokenSubscription;

  Future<void> initialize(String modelFileName) async {
    _statusController.add('Initializing Local Engine...');
    
    final downloader = ModelDownloaderService();
    final dir = await downloader.getModelsDirectory();
    _modelPath = '$dir/$modelFileName';
    
    if (!await File(_modelPath!).exists()) {
      throw Exception('Model file not found at $_modelPath');
    }
    
    if (_contextId != null) {
      await Fllama.instance()?.releaseContext(_contextId!);
      _contextId = null;
    }

    final context = await Fllama.instance()?.initContext(
      _modelPath!,
      emitLoadProgress: false,
      nGpuLayers: 99,     // Offload ALL layers to GPU
      nCtx: 1024,         // Context window
      nBatch: 256,        // Larger batch = faster prompt processing
      nThreads: 4,        // Use 4 CPU threads for non-GPU work
    );
    if (context != null && context["contextId"] != null) {
      _contextId = double.tryParse(context["contextId"].toString());
    }
    
    if (_contextId == null) {
      throw Exception('Failed to initialize model context');
    }
    
    // Perform a quick 1-token warmup to evaluate the graph and prevent cold-start delays
    _statusController.add('Warming up Model Engine...');
    try {
      await Fllama.instance()?.completion(
        _contextId!,
        prompt: "<|im_start|>system\nWarmup<|im_end|>\n<|im_start|>assistant\n",
        emitRealtimeCompletion: false,
        nPredict: 1,
      );
    } catch (_) {}
    
    _messages.clear();
    _statusController.add('');
  }

  Future<void> loadSession(int sessionId) async {
    _messages.clear();
    await _loadHistory(sessionId);
    if (_messages.isEmpty) {
      _addSystemInstruction();
    }
  }

  Future<void> _loadHistory(int sessionId) async {
    final history = await _dbService.getChatHistory(sessionId);
    for (var msg in history) {
      final role = msg['role'] as String;
      final content = msg['content'] as String;
      _messages.add({"role": role, "content": content});
    }
  }

  void _addSystemInstruction() {
    _messages.insert(0, {
      "role": "system",
      "content": _getSystemPrompt(),
    });
  }

  String _getSystemPrompt() {
    return '''You are an AI assistant on the user's Android phone. You control the phone using tools.

CRITICAL RULES:
1. To use a tool, reply with ONLY the JSON. No other text.
2. Format: {"tool_name": "NAME", "arguments": {}}
3. For ANY question about facts, people, news, or info you don't know → use search_web.
4. For network/wifi/internet questions → use check_connectivity or get_public_ip.
5. For clipboard questions → use read_clipboard. Never guess clipboard contents.
6. For app actions → first use list_apps to find the package name, then use the app tool.
7. NEVER say "I can't do that". You have tools for everything.

TOOLS:
- get_device_info: battery, storage, RAM, model
- list_files: search device files
- toggle_flashlight: {"on": true/false}
- list_apps: list installed apps
- launch_app: {"packageName": "com.example"}
- uninstall_app: {"packageName": "com.example"}
- search_play_store: {"query": "app name"}
- open_play_store: {"packageName": "com.example"}
- vibrate: {"duration": 500}
- set_volume: {"level": 0.5}
- copy_to_clipboard: {"text": "..."}
- read_clipboard: read what was last copied
- get_public_ip: get IP address
- check_connectivity: check wifi/network status
- search_web: {"query": "search term"} — USE THIS for any knowledge question!
- open_url: {"url": "https://..."}
- get_recent_screenshots: get recent screenshots
''';
  }

  String _buildChatMLPrompt() {
    StringBuffer sb = StringBuffer();
    for (var msg in _messages) {
      sb.writeln('<|im_start|>${msg['role']}\n${msg['content']}<|im_end|>');
    }
    sb.write('<|im_start|>assistant\n');
    return sb.toString();
  }

  Future<AgentResponse> sendMessage(String text, int sessionId, {String? imagePath, double? previousTps, double? previousEvalTime}) async {
    if (_contextId == null) throw Exception('Model not initialized');
    
    _statusController.add('Thinking...');
    _messages.add({"role": "user", "content": text});
    
    final prompt = _buildChatMLPrompt();
    String fullResponse = '';
    final startTime = DateTime.now();
    int tokenCount = 0;

    try {
      // DON'T send \x00 here - let the bouncing dots show first!

      bool streamStarted = false;
      _tokenSubscription?.cancel();
      _tokenSubscription = Fllama.instance()?.onTokenStream?.listen((event) {
        if (event["contextId"].toString() == _contextId.toString()) {
          final token = event["token"]?.toString() ?? "";
          if (token == "<|im_end|>" || token.contains("[DONE]")) return;
          if (!streamStarted) {
            streamStarted = true;
            _tokenStreamController.add('\x00'); // NOW switch from dots to streaming
          }
          fullResponse += token;
          tokenCount++;
          _tokenStreamController.add(token);
        }
      });

      final result = await Fllama.instance()?.completion(
        _contextId!,
        prompt: prompt,
        emitRealtimeCompletion: true,
        stop: ["<|im_end|>"],
        temperature: 0.5,
        nPredict: 256,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // PRIMARY: use stream-collected text; FALLBACK: use completion result
      String responseText = fullResponse.trim();
      if (responseText.isEmpty) {
        responseText = (result?["text"] ?? result?["content"] ?? "").toString().trim();
      }

      final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;

      if (tokenCount == 0 && responseText.isNotEmpty) {
        tokenCount = responseText.split(RegExp(r'\s+')).length;
      }

      double tps = evalTimeMs > 0 && tokenCount > 0 ? tokenCount / (evalTimeMs / 1000.0) : 0;

      _statusController.add('');
      _tokenStreamController.add('\x01'); // done

      // ─── Tool Detection: try multiple extraction strategies ───
      String? jsonStr;
      
      // Strategy 1: Markdown code block
      final toolBlockMatch = RegExp(r'```json\n?(.*?)\n?```', dotAll: true).firstMatch(responseText);
      if (toolBlockMatch != null) {
        jsonStr = toolBlockMatch.group(1)!.trim();
      }
      
      // Strategy 2: Raw JSON (starts and ends with braces)
      if (jsonStr == null && responseText.startsWith('{') && responseText.endsWith('}')) {
        jsonStr = responseText;
      }
      
      // Strategy 3: JSON embedded in text — find first {...} block
      if (jsonStr == null) {
        final embeddedMatch = RegExp(r'\{[^{}]*"tool_name"[^{}]*\}').firstMatch(responseText);
        if (embeddedMatch != null) {
          jsonStr = embeddedMatch.group(0)!.trim();
        }
      }

      if (jsonStr != null) {
        try {
          final toolCall = jsonDecode(jsonStr);
          final toolName = toolCall['tool_name'] as String;
          final toolArgs = toolCall['arguments'] ?? {};

          _statusController.add('Running $toolName...');
          final toolResult = await _executeTool(toolName, jsonEncode(toolArgs));

          _messages.add({"role": "assistant", "content": responseText});
          _messages.add({"role": "system", "content": "Tool result: ${jsonEncode(toolResult)}"});

          return await sendMessage(
            "Answer the user's original request in ONE short sentence using only the relevant data from the tool result. No preamble.",
            sessionId,
            previousTps: previousTps ?? tps,
            previousEvalTime: previousEvalTime ?? (evalTimeMs / 1000.0),
          );
        } catch (e) {
          return AgentResponse("Tool error: $e", "Qwen 2.5", 0, tps: previousTps ?? tps, evalTime: previousEvalTime ?? (evalTimeMs / 1000.0));
        }
      }

      // ─── Keyword Fallback: auto-call tool if model didn't produce JSON ───
      // Only trigger on the ORIGINAL user message (not on the recursive summary prompt)
      if (previousTps == null && previousEvalTime == null) {
        final autoTool = _detectToolFromUserMessage(text);
        if (autoTool != null) {
          _statusController.add('Running ${autoTool['tool_name']}...');
          _tokenStreamController.add('\x00');
          _tokenStreamController.add('Using ${autoTool['tool_name']}...');
          
          final toolResult = await _executeTool(
            autoTool['tool_name'] as String,
            jsonEncode(autoTool['arguments'] ?? {}),
          );
          
          _messages.add({"role": "assistant", "content": responseText});
          _messages.add({"role": "system", "content": "Tool result: ${jsonEncode(toolResult)}"});
          _tokenStreamController.add('\x01');

          return await sendMessage(
            "Answer the user's original request in ONE short sentence using only the relevant data from the tool result. No preamble.",
            sessionId,
            previousTps: tps,
            previousEvalTime: evalTimeMs / 1000.0,
          );
        }
      }

      // If response is still empty, provide fallback
      if (responseText.isEmpty) {
        responseText = "I processed your request but couldn't generate a response. Try rephrasing.";
      }

      await _dbService.saveMessage('assistant', responseText, sessionId);
      _messages.add({"role": "assistant", "content": responseText});

      return AgentResponse(responseText, "Qwen 2.5", 0,
        tps: previousTps ?? tps, evalTime: previousEvalTime ?? (evalTimeMs / 1000.0));


    } catch (e) {
      _statusController.add('');
      _tokenStreamController.add('\x01');
      return AgentResponse('Error: $e', 'error', 0);
    }
  }

  /// Keyword-based auto-detection: when the model fails to produce JSON,
  /// we match the user's original message to automatically call the right tool.
  /// PRIORITY ORDER: specific tools first → generic web search last.
  Map<String, dynamic>? _detectToolFromUserMessage(String userText) {
    final msg = userText.toLowerCase().trim();
    final wordCount = msg.split(RegExp(r'\s+')).length;

    // Skip very short messages — these are likely conversational follow-ups
    // ("nah rn who is?", "yeah", "ok", "no") that the model should handle
    if (wordCount <= 3 && !_hasSpecificToolKeyword(msg)) {
      return null;
    }

    // ════════════════════════════════════════════════════════════════
    // SPECIFIC TOOL PATTERNS (checked FIRST — highest priority)
    // ════════════════════════════════════════════════════════════════

    // ─── Clipboard (must be before "what is" search pattern!) ───
    if (msg.contains('clipboard') || msg.contains('copied') || msg.contains('pasted') ||
        msg.contains('last copy') || msg.contains('last thing i cop') || msg.contains('paste')) {
      return {'tool_name': 'read_clipboard', 'arguments': {}};
    }

    // ─── Network / Connectivity ───
    if (msg.contains('network') || msg.contains('wifi') || msg.contains('internet') ||
        msg.contains('connection') || msg.contains('connectivity') || msg.contains('signal') ||
        msg.contains('ping') || msg.contains('speed test') || msg.contains('network speed')) {
      return {'tool_name': 'check_connectivity', 'arguments': {}};
    }
    if (msg.contains('ip address') || msg.contains('my ip') || msg.contains('public ip') || msg.contains('ping')) {
      return {'tool_name': 'get_public_ip', 'arguments': {}};
    }

    // ─── Device Info ───
    if (msg.contains('battery') || msg.contains('device info') || msg.contains('ram') ||
        msg.contains('storage') || msg.contains('phone info') || msg.contains('my device') ||
        msg.contains('my phone')) {
      return {'tool_name': 'get_device_info', 'arguments': {}};
    }

    // ─── Flashlight ───
    if (msg.contains('flashlight') || msg.contains('torch') || msg.contains('flash light')) {
      final on = !msg.contains('off');
      return {'tool_name': 'toggle_flashlight', 'arguments': {'on': on}};
    }

    // ─── Volume ───
    if (msg.contains('volume')) {
      final match = RegExp(r'(\d+)').firstMatch(msg);
      double level = 0.5;
      if (match != null) {
        final num = int.tryParse(match.group(1)!) ?? 50;
        level = (num > 1 ? num / 100.0 : num.toDouble()).clamp(0.0, 1.0);
      }
      if (msg.contains('max') || msg.contains('full')) level = 1.0;
      if (msg.contains('mute') || msg.contains('silent') || msg.contains('zero')) level = 0.0;
      return {'tool_name': 'set_volume', 'arguments': {'level': level}};
    }

    // ─── Vibrate ───
    if (msg.contains('vibrat')) {
      final match = RegExp(r'(\d+)').firstMatch(msg);
      int duration = 500;
      if (match != null) {
        final val = int.tryParse(match.group(1)!) ?? 500;
        duration = val < 10 ? val * 1000 : val;
      }
      return {'tool_name': 'vibrate', 'arguments': {'duration': duration}};
    }

    // ─── Screenshots ───
    if (msg.contains('screenshot')) {
      return {'tool_name': 'get_recent_screenshots', 'arguments': {}};
    }

    // ─── Files ───
    if (msg.contains('files') || msg.contains('documents') || msg.contains('pdf')) {
      return {'tool_name': 'list_files', 'arguments': {}};
    }

    // ─── Apps: list ───
    if ((msg.contains('list') || msg.contains('show') || msg.contains('what')) && 
        (msg.contains('app') || msg.contains('application') || msg.contains('package'))) {
      return {'tool_name': 'list_apps', 'arguments': {}};
    }

    // ─── Apps: launch/open by name ───
    final launchPatterns = ['launch ', 'open ', 'start ', 'run '];
    for (final p in launchPatterns) {
      if (msg.contains(p)) {
        final idx = msg.indexOf(p);
        var appName = msg.substring(idx + p.length).trim();
        appName = appName.replaceAll(RegExp(r'\s*(app|application|the)\s*$'), '').trim();
        if (appName.isNotEmpty) {
          return {'tool_name': 'launch_app_by_name', 'arguments': {'appName': appName}};
        }
      }
    }

    // ─── Apps: delete/remove/uninstall by name ───
    final deletePatterns = ['delete ', 'remove ', 'uninstall '];
    for (final p in deletePatterns) {
      if (msg.contains(p)) {
        final idx = msg.indexOf(p);
        var appName = msg.substring(idx + p.length).trim();
        appName = appName.replaceAll(RegExp(r'\s*(app|application|the)\s*$'), '').trim();
        if (appName.isNotEmpty) {
          return {'tool_name': 'uninstall_app_by_name', 'arguments': {'appName': appName}};
        }
      }
    }

    // ─── Apps: download/install ───
    if (msg.contains('download') || msg.contains('install') || msg.contains('apk') ||
        msg.contains('play store') || msg.contains('playstore') || msg.contains('get the app')) {
      // Extract app name by removing noise words
      var appName = msg;
      final noiseWords = [
        'download', 'install', 'the', 'latest', 'apk', 'app', 'application',
        'from', 'play', 'store', 'playstore', 'please', 'can', 'you', 'i',
        'want', 'to', 'need', 'get', 'me', 'for', 'a', 'an', 'browser',
      ];
      for (final w in noiseWords) {
        appName = appName.replaceAll(RegExp('\\b$w\\b', caseSensitive: false), '');
      }
      appName = appName.replaceAll(RegExp(r'\s+'), ' ').trim();

      if (appName.isNotEmpty) {
        // "apk" mentioned → open browser to download APK file
        // (for third-party apps like ReVanced, modded apps, etc.)
        if (msg.contains('apk')) {
          final searchQuery = Uri.encodeComponent('$appName APK download');
          return {
            'tool_name': 'open_url',
            'arguments': {'url': 'https://www.google.com/search?q=$searchQuery'}
          };
        }
        // No "apk" → Play Store (regular installs)
        return {'tool_name': 'search_play_store', 'arguments': {'query': appName}};
      }
    }

    // ════════════════════════════════════════════════════════════════
    // WEB SEARCH (checked LAST — lowest priority, catch-all)
    // Only for messages that clearly look like a question, not follow-ups
    // ════════════════════════════════════════════════════════════════
    if (wordCount >= 3) {
      final searchStarters = [
        'who is', 'who are', 'who was', 'what is', 'what are', 'what was',
        'when is', 'when did', 'when was', 'where is', 'where are',
        'how to', 'how do', 'how does', 'how much', 'how many',
        'tell me about', 'explain', 'define', 'meaning of',
      ];
      for (final p in searchStarters) {
        if (msg.contains(p)) {
          return {'tool_name': 'search_web', 'arguments': {'query': userText}};
        }
      }

      // Topic-specific search keywords (can be anywhere)
      final topicPatterns = [
        'capital of', 'president of', 'prime minister', 'chief minister',
        'cm of', 'weather in', 'population of', 'price of', 'cost of',
        'search for', 'search about', 'look up', 'google',
        'find out', 'latest news', 'news about', 'current status of',
      ];
      for (final p in topicPatterns) {
        if (msg.contains(p)) {
          return {'tool_name': 'search_web', 'arguments': {'query': userText}};
        }
      }
    }

    return null; // No match — let the model's response pass through
  }

  /// Check if the message contains a specific tool keyword even if short
  bool _hasSpecificToolKeyword(String msg) {
    const specificKeywords = [
      'clipboard', 'copied', 'paste', 'battery', 'flashlight', 'torch',
      'volume', 'vibrat', 'screenshot', 'wifi', 'network', 'ping',
    ];
    for (final k in specificKeywords) {
      if (msg.contains(k)) return true;
    }
    return false;
  }



  Future<Map<String, dynamic>> _executeTool(String name, String? argumentsJson) async {
    Map<String, dynamic> args = {};
    if (argumentsJson != null && argumentsJson.isNotEmpty) {
      try {
        args = jsonDecode(argumentsJson) as Map<String, dynamic>;
      } catch (e) {
        // Handle error
      }
    }

    try {
      switch (name) {
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'get_public_ip':
          return await _searchService.getPublicIP();
        case 'list_files':
          final files = await _fileService.indexDocuments();
          return {'files': files.map((f) => {'name': f.name, 'path': f.path}).toList()};
        case 'toggle_flashlight':
          final on = args['on'] as bool;
          return {'success': await _utilityService.toggleFlashlight(on)};
        case 'list_apps':
          return {'apps': await _appService.getInstalledApps()};
        case 'launch_app':
          final success = await _appService.launchApp(args['packageName'] as String);
          return {'success': success};
        case 'uninstall_app':
          final success = await _appService.uninstallApp(args['packageName'] as String);
          return {'success': success};
        case 'search_play_store':
          await _appService.searchPlayStore(args['query'] as String);
          return {'success': true};
        case 'open_play_store':
          final success = await _appService.openPlayStore(args['packageName'] as String);
          return {'success': success};
        case 'vibrate':
          final duration = args['duration'] as int? ?? 500;
          await _utilityService.vibrate(duration: duration);
          return {'success': true, 'duration': duration};
        case 'set_volume':
          final level = (args['level'] as num).toDouble();
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'copy_to_clipboard':
          await _utilityService.copyToClipboard(args['text'] as String);
          return {'success': true};
        case 'read_clipboard':
          final text = await _utilityService.readFromClipboard();
          return {'text': text ?? 'Clipboard is empty'};
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          return await _searchService.searchWeb(args['query'] as String);
        case 'open_url':
          final success = await _utilityService.openUrl(args['url'] as String);
          return {'success': success};
        case 'launch_app_by_name':
          return await _appService.launchAppByName(args['appName'] as String);
        case 'uninstall_app_by_name':
          final result = await _appService.launchAppByName(args['appName'] as String);
          if (result['packageName'] != null) {
            final success = await _appService.uninstallApp(result['packageName'] as String);
            return {'success': success, 'appName': result['appName'], 'packageName': result['packageName']};
          }
          return result;
        case 'get_recent_screenshots':
          final screenshots = await _dbService.searchFiles('screenshot');
          return {'screenshots': screenshots.take(5).toList()};
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
