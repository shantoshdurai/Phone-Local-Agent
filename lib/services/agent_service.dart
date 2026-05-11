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

    final context = await Fllama.instance()?.initContext(_modelPath!, emitLoadProgress: false);
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
    return '''You are a highly capable, offline, local AI agent running directly on the user's Android phone.
You are powered by Qwen 2.5 and have access to various local device tools.
Because you are running completely offline, you ensure total privacy and security.

### 🛠 TOOL MASTERY RULES
If the user asks you to perform an action, you must use a tool. Since you are running locally without native function-calling APIs, you MUST output a strict JSON block to trigger a tool.

To use a tool, output exactly this format and nothing else:
```json
{
  "tool_name": "name_of_tool",
  "arguments": {
    "arg1": "value1"
  }
}
```

Available Tools:
1. get_device_info: Returns battery, storage, RAM. Args: none.
2. list_files: Lists files in a directory. Args: {"path": "optional/path", "extension": "optional .pdf"}.
3. toggle_flashlight: Args: {"on": true/false}.
4. list_apps: Lists installed apps. Args: none.
5. launch_app: Launches an app by package ID. Args: {"packageName": "com.example.app"}.
6. search_play_store: Searches the Play Store. Args: {"query": "app name"}.
7. get_recent_screenshots: Returns recent screenshots. Args: none.

If you don't need a tool, just answer the user normally.
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

  Future<AgentResponse> sendMessage(String text, int sessionId, {String? imagePath}) async {
    if (_contextId == null) throw Exception('Model not initialized');
    
    _statusController.add('Thinking (Local)...');
    _messages.add({"role": "user", "content": text});
    
    final prompt = _buildChatMLPrompt();
    final completer = Completer<String>();
    String fullResponse = '';

    try {
      final startTime = DateTime.now();
      int tokenCount = 0;
      
      _tokenSubscription?.cancel();
      _tokenSubscription = Fllama.instance()?.onTokenStream?.listen((event) {
        if (event["contextId"].toString() == _contextId.toString()) {
          final token = event["token"]?.toString() ?? "";
          if (token != "<|im_end|>" && !token.contains("[DONE]")) {
            tokenCount++;
          }
        }
      });

      final result = await Fllama.instance()?.completion(
        _contextId!,
        prompt: prompt,
        emitRealtimeCompletion: true,
        stop: ["<|im_end|>"],
      );
      
      final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;
      double tps = 0;
      if (evalTimeMs > 0 && tokenCount > 0) {
        tps = (tokenCount / (evalTimeMs / 1000.0));
      }

      String responseText = result?["text"] ?? "";
      if (responseText.isEmpty && result?["content"] != null) {
        responseText = result?["content"];
      }
      
      _statusController.add('');

      // Check if the response contains a tool call block
      final toolBlockMatch = RegExp(r'```json\n(.*?)\n```', dotAll: true).firstMatch(responseText);
      
      if (toolBlockMatch != null) {
        try {
          final jsonStr = toolBlockMatch.group(1)!;
          final toolCall = jsonDecode(jsonStr);
          final toolName = toolCall['tool_name'];
          final toolArgs = toolCall['arguments'];
          
          _statusController.add('Executing $toolName...');
          final toolResult = await _executeTool(toolName, jsonEncode(toolArgs));
          
          _statusController.add('Analyzing results...');
          _messages.add({"role": "assistant", "content": responseText});
          _messages.add({"role": "system", "content": "Tool Output: ${jsonEncode(toolResult)}"});
          
          return await sendMessage("Analyze the tool output and provide the final response to the user.", sessionId);
        } catch (e) {
          return AgentResponse("I tried to use a tool but formatted it incorrectly. Local inference glitch.", "Qwen 2.5 Local", 0, tps: tps, evalTime: evalTimeMs / 1000.0);
        }
      }

      await _dbService.saveMessage('assistant', responseText.trim(), sessionId);
      _messages.add({"role": "assistant", "content": responseText.trim()});
      
      return AgentResponse(responseText.trim(), "Qwen 2.5 Local", 0, tps: tps, evalTime: evalTimeMs / 1000.0);

    } catch (e) {
      _statusController.add('');
      return AgentResponse('Local Model Error: $e', 'error', 0);
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
