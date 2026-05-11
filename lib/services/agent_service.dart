import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:fllama/fllama.dart';
import 'model_downloader_service.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'database_service.dart';
import 'app_service.dart';
import 'utility_service.dart';
import 'personal_service.dart';
import 'search_service.dart';
import 'package:intl/intl.dart';

class AgentResponse {
  final String text;
  final String modelName;
  final int retryCount;
  AgentResponse(this.text, this.modelName, this.retryCount);
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
  List<Map<String, String>> _messages = [];

  Future<void> initialize(String modelFileName) async {
    _statusController.add('Initializing Local Engine...');
    fllamaInit();
    
    final downloader = ModelDownloaderService();
    final dir = await downloader.getModelsDirectory();
    _modelPath = '$dir/$modelFileName';
    
    if (!await File(_modelPath!).exists()) {
      throw Exception('Model file not found at $_modelPath');
    }
    
    _messages.clear();
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

  Future<AgentResponse> sendMessage(String text, int sessionId, {String? imagePath}) async {
    _statusController.add('Thinking (Local)...');
    
    _messages.add({"role": "user", "content": text});
    
    final completer = Completer<String>();
    String fullResponse = '';

    try {
      fllamaChat(
        modelPath: _modelPath!,
        messages: _messages,
        onToken: (token) {
          fullResponse += token;
        },
        onCompletion: (response, time) {
          completer.complete(fullResponse);
        },
      );

      final responseText = await completer.future;
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
          return AgentResponse("I tried to use a tool but formatted it incorrectly. Local inference glitch.", "Qwen 2.5 Local", 0);
        }
      }

      await _dbService.saveMessage('assistant', responseText.trim(), sessionId);
      _messages.add({"role": "assistant", "content": responseText.trim()});
      
      return AgentResponse(responseText.trim(), "Qwen 2.5 Local", 0);

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
          return await _deviceService.getDeviceSpecs();
        case 'list_files':
          return {'files': await _fileService.listFiles(args['path'], args['extension'])};
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
