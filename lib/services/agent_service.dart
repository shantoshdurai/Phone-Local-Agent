import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:fllama/fllama.dart';
import 'package:flutter_background/flutter_background.dart';
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
  final String? toolName;
  AgentResponse(this.text, this.modelName, this.retryCount, {this.tps, this.evalTime, this.toolName});
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
      nCtx: 2048,         // Context window
      nBatch: 512,        // Larger batch = faster prompt processing
      nThreads: 8,        // Use more threads
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
8. If the user asks for something you just did (like "turn it on" after you already tried), check the tool results in history before replying.

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

  Future<AgentResponse> sendMessage(String text, int sessionId, {String? imagePath, double? previousTps, double? previousEvalTime, String? forcedToolName}) async {
    if (_contextId == null) throw Exception('Model not initialized');
    
    final bool isTopLevel = forcedToolName == null;
    
    if (isTopLevel) {
      try {
        await FlutterBackground.enableBackgroundExecution();
      } catch (_) {}
      
      _statusController.add('Thinking...');
      _messages.add({"role": "user", "content": text});
    }
    
    final prompt = _buildChatMLPrompt();
    String fullResponse = '';
    final startTime = DateTime.now();
    int tokenCount = 0;

    try {
      bool streamStarted = false;
      _tokenSubscription?.cancel();
      _tokenSubscription = Fllama.instance()?.onTokenStream?.listen((event) {
        if (event["contextId"].toString() == _contextId.toString()) {
          final token = event["token"]?.toString() ?? "";
          if (token == "<|im_end|>" || token.contains("[DONE]")) return;
          if (!streamStarted) {
            streamStarted = true;
            _tokenStreamController.add('\x00'); 
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
        temperature: 0.1, // Lower temperature for more consistent tool usage
        nPredict: 256,
      );

      await Future.delayed(const Duration(milliseconds: 100));

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

      // ─── Tool Detection ───
      String? jsonStr;
      
      final toolBlockMatch = RegExp(r'\{.*"tool_name".*\}', dotAll: true).firstMatch(responseText);
      if (toolBlockMatch != null) {
        jsonStr = toolBlockMatch.group(0)!.trim();
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

          final res = await sendMessage(
            "The user asked: '$text'. The tool '$toolName' returned: ${jsonEncode(toolResult)}. Provide a concise final response.",
            sessionId,
            previousTps: previousTps ?? tps,
            previousEvalTime: previousEvalTime ?? (evalTimeMs / 1000.0),
            forcedToolName: toolName,
          );
          if (isTopLevel) { try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {} }
          return res;
        } catch (e) {
          // JSON decode failed or tool execution failed
        }
      }

      // ─── Keyword Fallback ───
      if (previousTps == null && previousEvalTime == null && forcedToolName == null) {
        final autoTool = _detectToolFromUserMessage(text);
        if (autoTool != null) {
          final toolName = autoTool['tool_name'] as String;
          _statusController.add('Running $toolName...');
          
          final toolResult = await _executeTool(
            toolName,
            jsonEncode(autoTool['arguments'] ?? {}),
          );
          
          _messages.add({"role": "assistant", "content": "I'll help you with that."});
          _messages.add({"role": "system", "content": "Tool result: ${jsonEncode(toolResult)}"});

          final res = await sendMessage(
            "The user asked: '$text'. I automatically ran '$toolName' which returned: ${jsonEncode(toolResult)}. Tell the user what happened in ONE short sentence.",
            sessionId,
            previousTps: tps,
            previousEvalTime: evalTimeMs / 1000.0,
            forcedToolName: toolName,
          );
          if (isTopLevel) { try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {} }
          return res;
        }
      }

      if (responseText.isEmpty) {
        responseText = "I'm not sure how to help with that. Could you rephrase?";
      }

      await _dbService.saveMessage('assistant', responseText, sessionId);
      _messages.add({"role": "assistant", "content": responseText});

      if (isTopLevel) { try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {} }

      return AgentResponse(responseText, "Qwen 2.5", 0,
        tps: previousTps ?? tps, evalTime: previousEvalTime ?? (evalTimeMs / 1000.0), toolName: forcedToolName);

    } catch (e) {
      _statusController.add('');
      _tokenStreamController.add('\x01');
      if (isTopLevel) { try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {} }
      return AgentResponse('Error: $e', 'error', 0);
    }
  }

  /// Keyword-based auto-detection
  Map<String, dynamic>? _detectToolFromUserMessage(String userText) {
    final msg = userText.toLowerCase().trim();
    final wordCount = msg.split(RegExp(r'\s+')).length;

    if (wordCount <= 3 && !_hasSpecificToolKeyword(msg)) return null;

    if (msg.contains('clipboard') || msg.contains('copied') || msg.contains('paste')) {
      return {'tool_name': 'read_clipboard', 'arguments': {}};
    }
    if (msg.contains('network') || msg.contains('wifi') || msg.contains('internet')) {
      return {'tool_name': 'check_connectivity', 'arguments': {}};
    }
    if (msg.contains('battery') || msg.contains('device info') || msg.contains('storage')) {
      return {'tool_name': 'get_device_info', 'arguments': {}};
    }
    if (msg.contains('flashlight') || msg.contains('torch')) {
      final on = !msg.contains('off');
      return {'tool_name': 'toggle_flashlight', 'arguments': {'on': on}};
    }
    if (msg.contains('vibrat')) {
      return {'tool_name': 'vibrate', 'arguments': {}};
    }
    if (msg.contains('screenshot')) {
      return {'tool_name': 'get_recent_screenshots', 'arguments': {}};
    }
    if (msg.contains('files') || msg.contains('pdf')) {
      return {'tool_name': 'list_files', 'arguments': {}};
    }
    if (msg.contains('app') || msg.contains('application')) {
      if (msg.contains('list') || msg.contains('show')) {
        return {'tool_name': 'list_apps', 'arguments': {}};
      }
    }
    
    // ─── Apps: launch/open by name ───
    final launchPatterns = ['launch ', 'open ', 'start ', 'run ', 'call '];
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

    // Protect conversational meta-queries from triggering web search
    final metaQueries = [
      'what can you do', 'who are you', 'what is your name', 'how are you',
      'what are the things you can do', 'what are things you can do',
      'can you tell me what you do', 'what do you do'
    ];
    for (final mq in metaQueries) {
      if (msg.contains(mq)) return null; 
    }

    // Catch-all web search
    if (wordCount >= 4) {
       final searchKeywords = ['who', 'what', 'when', 'where', 'how', 'why', 'meaning', 'capital', 'weather'];
       for (final k in searchKeywords) {
         // Exclude conversational "what" and "why" follow-ups that don't need a search
         if (msg.startsWith('what i have') || msg.startsWith('why are you')) return null;
         
         if (msg.startsWith(k) || msg.contains('search')) return {'tool_name': 'search_web', 'arguments': {'query': userText}};
       }
    }

    return null;
  }

  bool _hasSpecificToolKeyword(String msg) {
    const specificKeywords = ['clipboard', 'battery', 'flashlight', 'vibrate', 'screenshot', 'wifi', 'open', 'launch', 'run', 'start', 'search', 'call'];
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
      } catch (_) {}
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
