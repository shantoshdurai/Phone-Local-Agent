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
    return '''You are a friendly, intelligent, and very concise AI assistant running locally on the user's Android phone.

PERSONALITY:
- You have a helpful and witty personality. 
- You engage in natural conversation. If the user is joking or just chatting, play along!
- Your answers are ALWAYS extremely short (1-2 sentences max).

TOOLS:
- You have access to phone tools (battery, flashlight, apps, etc.).
- ONLY use a tool if the user explicitly asks for an action that requires it.
- To use a tool, output ONLY the raw JSON block. No explanation.
- After getting tool data, give a 1-sentence summary of the result.

Tools available:
1. get_device_info (battery, storage, RAM)
2. list_files (search files)
3. toggle_flashlight (turn on/off)
4. list_apps (show installed apps)
5. launch_app (open an app by package name)
6. search_play_store (find apps)
7. get_recent_screenshots (show latest images)
8. get_public_ip (check network)
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

      // Tool Detection: Markdown block or Raw JSON
      String? jsonStr;
      final toolBlockMatch = RegExp(r'```json\n?(.*?)\n?```', dotAll: true).firstMatch(responseText);
      if (toolBlockMatch != null) {
        jsonStr = toolBlockMatch.group(1)!.trim();
      } else if (responseText.startsWith('{') && responseText.endsWith('}')) {
        jsonStr = responseText;
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
        case 'search_play_store':
          await _appService.searchPlayStore(args['query'] as String);
          return {'success': true};
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
