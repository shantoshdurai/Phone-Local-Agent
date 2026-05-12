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
    return '''You are a helpful AI assistant running 100% locally on the user's Android phone. You CAN control this phone using tools.

RULES:
- Keep answers SHORT (1-2 sentences).
- When the user asks you to DO something on the phone, you MUST use a tool. Never say "I can't do that".
- To call a tool, respond with ONLY this exact JSON format and nothing else:
{"tool_name": "TOOL_NAME", "arguments": {ARGS}}

EXAMPLE:
User: "Turn on my flashlight"
You respond: {"tool_name": "toggle_flashlight", "arguments": {"on": true}}

User: "Delete the ClassNow app"
You respond: {"tool_name": "uninstall_app", "arguments": {"packageName": "com.example.classnow"}}

AVAILABLE TOOLS:

get_device_info — Get battery level, storage, RAM, device model.
  Arguments: none
  Example: {"tool_name": "get_device_info", "arguments": {}}

list_files — Search and list files on the device.
  Arguments: none
  Example: {"tool_name": "list_files", "arguments": {}}

toggle_flashlight — Turn flashlight on or off.
  Arguments: {"on": true/false}
  Example: {"tool_name": "toggle_flashlight", "arguments": {"on": true}}

list_apps — List all installed apps with package names.
  Arguments: none
  Example: {"tool_name": "list_apps", "arguments": {}}

launch_app — Open an app by its package name.
  Arguments: {"packageName": "com.example.app"}
  Example: {"tool_name": "launch_app", "arguments": {"packageName": "com.whatsapp"}}

uninstall_app — Uninstall/delete an app by package name.
  Arguments: {"packageName": "com.example.app"}
  Example: {"tool_name": "uninstall_app", "arguments": {"packageName": "com.example.app"}}

search_play_store — Search the Play Store for an app.
  Arguments: {"query": "search term"}
  Example: {"tool_name": "search_play_store", "arguments": {"query": "instagram"}}

open_play_store — Open an app's Play Store page.
  Arguments: {"packageName": "com.example.app"}
  Example: {"tool_name": "open_play_store", "arguments": {"packageName": "com.whatsapp"}}

vibrate — Vibrate the phone for a given duration in milliseconds.
  Arguments: {"duration": 500}
  Example: {"tool_name": "vibrate", "arguments": {"duration": 1000}}

set_volume — Set device volume (0.0 to 1.0).
  Arguments: {"level": 0.5}
  Example: {"tool_name": "set_volume", "arguments": {"level": 0.5}}

copy_to_clipboard — Copy text to clipboard.
  Arguments: {"text": "content"}
  Example: {"tool_name": "copy_to_clipboard", "arguments": {"text": "hello"}}

read_clipboard — Read the current clipboard contents.
  Arguments: none
  Example: {"tool_name": "read_clipboard", "arguments": {}}

get_public_ip — Get the device's public IP address.
  Arguments: none
  Example: {"tool_name": "get_public_ip", "arguments": {}}

check_connectivity — Check network connectivity status.
  Arguments: none
  Example: {"tool_name": "check_connectivity", "arguments": {}}

search_web — Search the web using DuckDuckGo.
  Arguments: {"query": "search term"}
  Example: {"tool_name": "search_web", "arguments": {"query": "weather today"}}

open_url — Open a URL in the browser.
  Arguments: {"url": "https://example.com"}
  Example: {"tool_name": "open_url", "arguments": {"url": "https://google.com"}}

get_recent_screenshots — Get recent screenshot files.
  Arguments: none
  Example: {"tool_name": "get_recent_screenshots", "arguments": {}}

IMPORTANT: If the user asks to do something and you don't know the exact package name, first call list_apps to find it, then use the correct package name.
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
          final status = await _utilityService.checkConnectivity();
          return {'connectivity': status};
        case 'search_web':
          return await _searchService.searchWeb(args['query'] as String);
        case 'open_url':
          final success = await _utilityService.openUrl(args['url'] as String);
          return {'success': success};
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
