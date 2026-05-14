import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter_gemma/flutter_gemma.dart';
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

  InferenceModel? _model;
  InferenceChat? _chat;

  // In-memory history for session replay (index 0 = system marker)
  final List<Map<String, String>> _messages = [];
  // Whether the current chat session hasn't received any user turn yet
  bool _isFirstMessage = true;

  // Lazy native-init guards. We moved these off the app boot path to cut
  // cold-start latency — the heavy work (loading MediaPipe .so files,
  // registering the background-service notification channel) only happens
  // the first time the user actually enters a chat.
  static bool _gemmaReady = false;
  static bool _backgroundReady = false;

  Future<void> _ensureNativeReady() async {
    if (!_gemmaReady) {
      await FlutterGemma.initialize();
      _gemmaReady = true;
    }
    if (!_backgroundReady) {
      try {
        const androidConfig = FlutterBackgroundAndroidConfig(
          notificationTitle: "Onyx Intelligence",
          notificationText: "Background processing active",
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon:
              AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        );
        await FlutterBackground.initialize(androidConfig: androidConfig);
      } catch (_) {}
      _backgroundReady = true;
    }
  }

  Future<void> initialize(String modelFileName) async {
    _statusController.add('Initializing Local Engine...');

    await _ensureNativeReady();

    final downloader = ModelDownloaderService();
    final dir = await downloader.getModelsDirectory();
    final modelPath = '$dir/$modelFileName';

    if (!await File(modelPath).exists()) {
      throw Exception('Model file not found at $modelPath');
    }

    // Register the local .task file with flutter_gemma
    await FlutterGemma.installModel(modelType: ModelType.qwen)
        .fromFile(modelPath)
        .install();

    // Load model with GPU backend (LiteRT / OpenCL)
    // The Qwen2.5 .task files we ship are built with ekv1280 — their
    // KV-cache caps at 1280 tokens. Asking for more makes the LiteRT
    // resource calculator refuse to open the graph.
    _model = await FlutterGemma.getActiveModel(
      maxTokens: 1280,
      preferredBackend: PreferredBackend.gpu,
    );

    _messages.clear();
    _isFirstMessage = true;
    _statusController.add('');
  }

  Future<void> loadSession(int sessionId) async {
    _messages.clear();
    _addSystemInstruction();
    await _loadHistory(sessionId);
    await _rebuildChat();
  }

  Future<void> _loadHistory(int sessionId) async {
    final history = await _dbService.getChatHistory(sessionId);
    for (var msg in history) {
      _messages.add({'role': msg['role'] as String, 'content': msg['content'] as String});
    }
  }

  void _addSystemInstruction() {
    _messages.insert(0, {'role': 'system', 'content': _getSystemPrompt()});
  }

  Future<void> _rebuildChat() async {
    if (_model == null) return;

    _chat = await _model!.createChat(
      temperature: 0.1,
      topK: 1,
      modelType: ModelType.qwen,
    );

    _isFirstMessage = true;

    final replay = _buildReplayMessages();
    if (replay.isEmpty) return;

    for (final message in replay) {
      await _chat!.addQueryChunk(message);
    }
    _isFirstMessage = false;
  }

  // Treat a stored assistant message as a raw tool call (so we can filter it
  // out of the session replay — the model doesn't need the JSON, just the
  // final user-facing answer that followed it).
  bool _isToolCallJson(String s) {
    final t = s.trimLeft();
    return t.startsWith('{') &&
        (t.contains('"tool_name"') || t.contains('"name"'));
  }

  // Build a compact replay history for clearHistory(): user turns + clean
  // assistant replies only. JSON tool calls and "Tool result: …" bridge
  // messages are dropped — they were intermediate machinery, not chat.
  List<Message> _buildReplayMessages() {
    final out = <Message>[];
    bool firstUser = true;
    for (final m in _messages) {
      final role = m['role'];
      final content = m['content'] ?? '';
      if (role == 'system' || role == 'tool_call' || role == 'tool_result') {
        continue;
      }
      // Defensive: catch any unlabelled assistant JSON tool call from older
      // session data still in the DB.
      if (role == 'assistant' && _isToolCallJson(content)) continue;
      final isUser = role == 'user';
      var text = content;
      if (isUser && firstUser) {
        text = '${_getSystemPrompt()}\n\n$content';
        firstUser = false;
      }
      out.add(Message.text(text: text, isUser: isUser));
    }
    return out;
  }

  // flutter_gemma 0.11.16 sometimes leaves the underlying LlmInferenceSession
  // in a "finished" state after generation (sizeInTokens / stream teardown
  // appear to be the trigger). The next addQueryChunk then throws
  // IllegalStateException with a DetokenizerCalculator RET_CHECK. When that
  // happens, close the session and replay our history into a fresh one.
  Future<void> _safeAddChunk(String text, {required bool isUser}) async {
    try {
      await _chat!.addQueryChunk(Message.text(text: text, isUser: isUser));
      _isFirstMessage = false;
    } catch (_) {
      await _chat!.clearHistory(replayHistory: _buildReplayMessages());
      _isFirstMessage = false;
    }
  }

  String _getSystemPrompt() {
    // Kept compact: ekv1280 KV cache gives ~1200 usable tokens. A bloated
    // system prompt overflows the cache after 1-2 turns and the
    // DetokenizerCalculator crashes with id=-1.
    return '''You are ONYX, an on-device AI agent on Android. You control the phone via tools.

RULES:
- To call a tool, reply with ONLY this JSON, nothing else: {"tool_name":"NAME","arguments":{}}
- Facts/news/weather/info → search_web. Date/time → get_date_time. Network → check_connectivity. Clipboard → read_clipboard (never guess). Open an app → launch_app_by_name.
- You have internet via search_web. Never say "I can't".

TOOLS:
get_date_time, get_device_info, check_connectivity, get_public_ip, search_web(query), open_url(url), list_files, list_apps, launch_app_by_name(appName), launch_app(packageName), uninstall_app(packageName), search_play_store(query), open_play_store(packageName), toggle_flashlight(on), vibrate(duration), set_volume(level), copy_to_clipboard(text), read_clipboard, get_recent_screenshots, search_contacts(query), schedule_event(title,start,end,description), send_whatsapp(phone,message)
''';
  }

  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
    double? previousTps,
    double? previousEvalTime,
    String? forcedToolName,
  }) async {
    if (_chat == null) throw Exception('Model not initialized');

    final bool isTopLevel = forcedToolName == null;

    if (isTopLevel) {
      try { await FlutterBackground.enableBackgroundExecution(); } catch (_) {}
      _statusController.add('Thinking...');
      _messages.add({'role': 'user', 'content': text});

      // Inject system prompt into the very first user turn of a fresh session
      String msgToSend = text;
      if (_isFirstMessage) {
        msgToSend = '${_getSystemPrompt()}\n\n$text';
      }
      await _safeAddChunk(msgToSend, isUser: true);
    }

    String fullResponse = '';
    int tokenCount = 0;
    final startTime = DateTime.now();
    bool streamStarted = false;

    try {
      await for (final response in _chat!.generateChatResponseAsync()) {
        if (response is TextResponse) {
          final token = response.token;
          if (token.isEmpty) continue;
          if (!streamStarted) {
            streamStarted = true;
            _tokenStreamController.add('\x00');
          }
          fullResponse += token;
          tokenCount++;
          _tokenStreamController.add(token);
        }
      }

      final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;
      if (tokenCount == 0 && fullResponse.isNotEmpty) {
        tokenCount = fullResponse.split(RegExp(r'\s+')).length;
      }
      final double tps =
          evalTimeMs > 0 && tokenCount > 0 ? tokenCount / (evalTimeMs / 1000.0) : 0;

      _statusController.add('');
      _tokenStreamController.add('\x01');

      final String responseText = fullResponse.trim();

      // ─── Tool Detection ───
      String? jsonStr;
      final toolBlockMatch =
          RegExp(r'\{.*"tool_name".*\}', dotAll: true).firstMatch(responseText);
      if (toolBlockMatch != null) {
        jsonStr = toolBlockMatch.group(0)!.trim();
      }

      if (jsonStr != null) {
        try {
          final toolCall = jsonDecode(jsonStr);
          final toolName = toolCall['tool_name'] as String;
          final rawArgs = toolCall['arguments'];
          final toolArgs =
              (rawArgs is Map) ? Map<String, dynamic>.from(rawArgs) : <String, dynamic>{};

          _statusController.add('Running $toolName...');
          final toolResult = await _executeTool(toolName, jsonEncode(toolArgs));

          // Direct response for simple tools — skip second LLM call
          final directResponse = _formatToolResult(toolName, toolArgs, toolResult);
          if (directResponse != null) {
            // Mark the raw JSON turn so the replay filter can drop it later.
            _messages.add({'role': 'tool_call', 'content': responseText});
            _messages.add({'role': 'assistant', 'content': directResponse});
            await _dbService.saveMessage('assistant', directResponse, sessionId);
            if (isTopLevel) {
              try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
            }
            return AgentResponse(directResponse, 'Qwen 2.5', 0,
                tps: previousTps ?? tps,
                evalTime: previousEvalTime ?? (evalTimeMs / 1000.0),
                toolName: toolName);
          }

          // Complex tool — inject result and ask model to summarize
          _messages.add({'role': 'tool_call', 'content': responseText});
          final toolResultMsg =
              "Tool result: ${_truncateToolResult(toolName, toolResult)}\n\nBased on this, answer the user's question concisely and helpfully.";
          _messages.add({'role': 'tool_result', 'content': toolResultMsg});
          await _safeAddChunk(toolResultMsg, isUser: true);

          final res = await sendMessage(
            '',
            sessionId,
            previousTps: previousTps ?? tps,
            previousEvalTime: previousEvalTime ?? (evalTimeMs / 1000.0),
            forcedToolName: toolName,
          );
          if (isTopLevel) {
            try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
          }
          return res;
        } catch (_) {}
      }

      // ─── Keyword Fallback ───
      if (previousTps == null &&
          previousEvalTime == null &&
          forcedToolName == null &&
          responseText.length < 40) {
        final autoTool = _detectToolFromUserMessage(text);
        if (autoTool != null) {
          final toolName = autoTool['tool_name'] as String;
          final rawAutoArgs = autoTool['arguments'] ?? {};
          final toolArgs = Map<String, dynamic>.from(rawAutoArgs as Map);
          _statusController.add('Running $toolName...');
          final toolResult = await _executeTool(toolName, jsonEncode(toolArgs));

          final directResponse = _formatToolResult(toolName, toolArgs, toolResult);
          if (directResponse != null) {
            _messages.add({'role': 'assistant', 'content': directResponse});
            await _dbService.saveMessage('assistant', directResponse, sessionId);
            if (isTopLevel) {
              try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
            }
            return AgentResponse(directResponse, 'Qwen 2.5', 0,
                tps: tps, evalTime: evalTimeMs / 1000.0, toolName: toolName);
          }

          _messages.add({'role': 'assistant', 'content': "I'll help you with that."});
          final toolResultMsg =
              "Tool result: ${_truncateToolResult(toolName, toolResult)}\n\nSummarize this in one short sentence.";
          _messages.add({'role': 'tool_result', 'content': toolResultMsg});
          await _safeAddChunk(toolResultMsg, isUser: true);

          final res = await sendMessage(
            '',
            sessionId,
            previousTps: tps,
            previousEvalTime: evalTimeMs / 1000.0,
            forcedToolName: toolName,
          );
          if (isTopLevel) {
            try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
          }
          return res;
        }
      }

      final finalText = responseText.isEmpty
          ? "I'm not sure how to help with that. Could you rephrase?"
          : responseText;

      await _dbService.saveMessage('assistant', finalText, sessionId);
      _messages.add({'role': 'assistant', 'content': finalText});

      if (isTopLevel) {
        try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
      }

      return AgentResponse(finalText, 'Qwen 2.5', 0,
          tps: previousTps ?? tps,
          evalTime: previousEvalTime ?? (evalTimeMs / 1000.0),
          toolName: forcedToolName);
    } catch (e) {
      _statusController.add('');
      _tokenStreamController.add('\x01');
      if (isTopLevel) {
        try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
      }
      return AgentResponse('Error: $e', 'error', 0);
    }
  }

  /// Direct format for simple tools — skips a second LLM call.
  String? _formatToolResult(
      String toolName, Map<String, dynamic> args, Map<String, dynamic> result) {
    if (result.containsKey('error')) return null;

    switch (toolName) {
      case 'toggle_flashlight':
        final on = args['on'] as bool? ?? true;
        return result['success'] == true
            ? 'Flashlight turned ${on ? "on" : "off"}.'
            : 'Could not toggle flashlight. Another app may be using the camera.';

      case 'vibrate':
        final ms = result['duration'] as int? ?? 500;
        final secs = ms / 1000.0;
        final label = secs == secs.truncateToDouble()
            ? '${secs.toInt()} second${secs.toInt() == 1 ? "" : "s"}'
            : '${secs.toStringAsFixed(1)} seconds';
        return 'Phone vibrated for $label.';

      case 'set_volume':
        final pct = ((result['level'] as num?)?.toDouble() ?? 0.5) * 100;
        return 'Volume set to ${pct.toStringAsFixed(0)}%.';

      case 'copy_to_clipboard':
        return 'Copied to clipboard.';

      case 'read_clipboard':
        final text = result['text'] as String? ?? '';
        return text == 'Clipboard is empty'
            ? 'Your clipboard is empty.'
            : 'Clipboard contains: "$text"';

      case 'open_url':
        return result['success'] == true
            ? 'Opening in your browser.'
            : 'Could not open that URL.';

      case 'launch_app':
        return result['success'] == true ? 'App launched.' : 'Could not launch that app.';

      case 'launch_app_by_name':
        if (result['success'] == true) {
          return '${result['appName'] ?? 'App'} opened.';
        }
        final suggestions = (result['suggestions'] as List?)?.cast<String>() ?? [];
        return suggestions.isNotEmpty
            ? 'App not found. Did you mean: ${suggestions.join(', ')}?'
            : 'App not found on this device.';

      case 'uninstall_app':
        return result['success'] == true
            ? 'Uninstall dialog opened.'
            : 'Could not initiate uninstall.';

      case 'search_play_store':
        return 'Opened Play Store search.';

      case 'open_play_store':
        return result['success'] == true
            ? 'Opened in Play Store.'
            : 'Could not open Play Store.';

      case 'get_public_ip':
        final ip = result['ip'] as String? ?? result['query'] as String? ?? 'unknown';
        return 'Your public IP address is $ip.';

      case 'get_date_time':
        final day = result['dayOfWeek'] as String? ?? '';
        final date = result['date'] as String? ?? '';
        final time = result['time'] as String? ?? '';
        return 'Today is $day, $date. The current time is $time.';

      case 'get_device_info':
        final mfr = result['manufacturer'] as String? ?? '';
        final model = result['model'] as String? ?? '';
        final ver = result['version']?.toString() ?? '';
        final battery = result['batteryLevel'];
        final freeMb = (result['freeDiskSpaceMB'] as num?)?.toDouble();
        final totalMb = (result['totalDiskSpaceMB'] as num?)?.toDouble();
        final parts = <String>[];
        if (mfr.isNotEmpty || model.isNotEmpty) {
          parts.add('Device: ${[mfr, model].where((s) => s.isNotEmpty).join(' ')}'
              '${ver.isNotEmpty ? ' (Android $ver)' : ''}');
        }
        if (battery != null) parts.add('Battery: $battery%');
        if (freeMb != null && totalMb != null) {
          final freeGb = (freeMb / 1024).toStringAsFixed(1);
          final totalGb = (totalMb / 1024).toStringAsFixed(1);
          parts.add('Storage: $freeGb GB free of $totalGb GB');
        } else if (freeMb != null) {
          parts.add('Storage: ${(freeMb / 1024).toStringAsFixed(1)} GB free');
        }
        return parts.isEmpty ? null : '${parts.join('. ')}.';

      case 'check_connectivity':
        final type = result['type'] as String? ?? result['connectionType'] as String? ?? '';
        final online = result['online'] as bool? ?? result['isConnected'] as bool?;
        final ssid = result['ssid'] as String?;
        final ip = result['ip'] as String? ?? result['localIp'] as String?;
        if (online == false) return 'No internet connection.';
        final bits = <String>[];
        if (type.isNotEmpty) bits.add('Connected via $type');
        if (ssid != null && ssid.isNotEmpty) bits.add('Wi-Fi: $ssid');
        if (ip != null && ip.isNotEmpty) bits.add('IP: $ip');
        return bits.isEmpty ? 'You are online.' : '${bits.join('. ')}.';

      case 'send_whatsapp':
        return result['success'] == true
            ? 'Opening WhatsApp...'
            : 'Could not open WhatsApp. Make sure it is installed.';

      case 'schedule_event':
        return result['success'] == true
            ? 'Event added to your calendar.'
            : 'Could not create the calendar event.';

      default:
        return null;
    }
  }

  String _truncateToolResult(String toolName, Map<String, dynamic> result) {
    if (toolName == 'list_apps') {
      final apps = result['apps'] as List? ?? [];
      final total = result['total'] as int? ?? apps.length;
      final limited = apps.take(30).map((a) {
        if (a is Map) return {'name': a['name'], 'pkg': a['packageName'] ?? a['pkg']};
        return a;
      }).toList();
      return jsonEncode({'apps': limited, 'total': total, 'showing': limited.length});
    }
    if (toolName == 'list_files') {
      final files = result['files'] as List? ?? [];
      final limited = files.take(30).toList();
      return jsonEncode({'files': limited, 'total': files.length});
    }
    final encoded = jsonEncode(result);
    // Hard cap matches our 1280-token KV budget: ~600 chars ≈ ~250 Qwen
    // tokens, leaving room for the rest of the prompt + assistant reply.
    if (encoded.length > 600) return '${encoded.substring(0, 600)}... [truncated]';
    return encoded;
  }

  Map<String, dynamic>? _detectToolFromUserMessage(String userText) {
    final msg = userText.toLowerCase().trim();
    final wordCount = msg.split(RegExp(r'\s+')).length;

    if (wordCount <= 3 && !_hasSpecificToolKeyword(msg)) return null;

    if (msg.contains('time') || msg.contains('date') || msg.contains('today') ||
        msg.contains('day is it') || msg.contains('clock')) {
      return {'tool_name': 'get_date_time', 'arguments': {}};
    }
    if (msg.contains('clipboard') || msg.contains('copied') || msg.contains('paste')) {
      return {'tool_name': 'read_clipboard', 'arguments': {}};
    }
    if (msg.contains('network') || msg.contains('wifi') || msg.contains('internet') ||
        msg.contains('connectivity')) {
      return {'tool_name': 'check_connectivity', 'arguments': {}};
    }
    if (msg.contains('battery') || msg.contains('device info') || msg.contains('storage') ||
        msg.contains('ram') || msg.contains('my phone')) {
      return {'tool_name': 'get_device_info', 'arguments': {}};
    }
    if (msg.contains('flashlight') || msg.contains('torch')) {
      return {'tool_name': 'toggle_flashlight', 'arguments': {'on': !msg.contains('off')}};
    }
    if (msg.contains('vibrat')) {
      return {'tool_name': 'vibrate', 'arguments': {'duration': _extractDurationMs(msg)}};
    }
    if (msg.contains('screenshot')) {
      return {'tool_name': 'get_recent_screenshots', 'arguments': {}};
    }
    if (msg.contains('files') || msg.contains('pdf') || msg.contains('document')) {
      return {'tool_name': 'list_files', 'arguments': {}};
    }
    if ((msg.contains('app') || msg.contains('application')) &&
        (msg.contains('list') || msg.contains('show') || msg.contains('installed'))) {
      return {'tool_name': 'list_apps', 'arguments': {}};
    }
    for (final p in ['launch ', 'open ', 'start app ', 'run app ']) {
      if (msg.startsWith(p)) {
        var appName = msg.substring(p.length).trim();
        appName = appName.replaceAll(RegExp(r'\s*(app|application|the)\s*$'), '').trim();
        if (appName.isNotEmpty) {
          return {'tool_name': 'launch_app_by_name', 'arguments': {'appName': appName}};
        }
      }
    }

    const metaQueries = [
      'what can you do', 'who are you', 'what is your name', 'how are you',
      'what are the things you can do', 'what do you do',
    ];
    for (final mq in metaQueries) {
      if (msg.contains(mq)) return null;
    }

    if (wordCount >= 4) {
      if (msg.startsWith('what i have') || msg.startsWith('why are you')) return null;
      const searchKeywords = [
        'who is', 'what is', 'when is', 'where is', 'how do', 'how to',
        'why is', 'meaning of', 'capital of', 'weather in', 'search'
      ];
      for (final k in searchKeywords) {
        if (msg.startsWith(k) || msg.contains('search for')) {
          return {'tool_name': 'search_web', 'arguments': {'query': userText}};
        }
      }
    }

    return null;
  }

  int _extractDurationMs(String msg) {
    final secMatch = RegExp(r'(\d+(?:\.\d+)?)\s*(?:sec|second)').firstMatch(msg);
    if (secMatch != null) {
      return ((double.tryParse(secMatch.group(1)!) ?? 1.0) * 1000).round();
    }
    final msMatch = RegExp(r'(\d+)\s*ms').firstMatch(msg);
    if (msMatch != null) return int.tryParse(msMatch.group(1)!) ?? 500;
    final minMatch = RegExp(r'(\d+)\s*min').firstMatch(msg);
    if (minMatch != null) return (int.tryParse(minMatch.group(1)!) ?? 1) * 60000;
    return 500;
  }

  bool _hasSpecificToolKeyword(String msg) {
    const keywords = [
      'clipboard', 'battery', 'flashlight', 'vibrate', 'screenshot',
      'wifi', 'open', 'launch', 'run', 'start', 'search', 'call', 'time', 'date'
    ];
    return keywords.any((k) => msg.contains(k));
  }

  Future<Map<String, dynamic>> _executeTool(String name, String? argumentsJson) async {
    Map<String, dynamic> args = {};
    if (argumentsJson != null && argumentsJson.isNotEmpty) {
      try { args = jsonDecode(argumentsJson) as Map<String, dynamic>; } catch (_) {}
    }
    try {
      switch (name) {
        case 'get_date_time':
          final now = DateTime.now();
          const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
          return {
            'date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
            'time': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            'dayOfWeek': days[now.weekday - 1],
            'timezone': now.timeZoneName,
          };
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'get_public_ip':
          return await _searchService.getPublicIP();
        case 'list_files':
          final files = await _fileService.indexDocuments();
          return {'files': files.map((f) => {'name': f.name, 'path': f.path}).toList()};
        case 'toggle_flashlight':
          return {'success': await _utilityService.toggleFlashlight(args['on'] as bool? ?? true)};
        case 'list_apps':
          final apps = await _appService.getInstalledApps();
          return {
            'apps': apps.take(50).map((a) => {'name': a['name'], 'pkg': a['packageName']}).toList(),
            'total': apps.length,
          };
        case 'launch_app':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.launchApp(pkg)};
        case 'uninstall_app':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.uninstallApp(pkg)};
        case 'search_play_store':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          await _appService.searchPlayStore(query);
          return {'success': true};
        case 'open_play_store':
          final pkg = args['packageName'] as String? ?? '';
          if (pkg.isEmpty) return {'error': 'packageName required'};
          return {'success': await _appService.openPlayStore(pkg)};
        case 'vibrate':
          final duration = (args['duration'] as num?)?.toInt() ?? 500;
          await _utilityService.vibrate(duration: duration);
          return {'success': true, 'duration': duration};
        case 'set_volume':
          final level = (args['level'] as num?)?.toDouble() ?? 0.5;
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'copy_to_clipboard':
          final text = args['text'] as String? ?? '';
          if (text.isEmpty) return {'error': 'text required'};
          await _utilityService.copyToClipboard(text);
          return {'success': true};
        case 'read_clipboard':
          return {'text': await _utilityService.readFromClipboard() ?? 'Clipboard is empty'};
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          return await _searchService.searchWeb(query);
        case 'open_url':
          final url = args['url'] as String? ?? '';
          if (url.isEmpty) return {'error': 'url required'};
          return {'success': await _utilityService.openUrl(url)};
        case 'launch_app_by_name':
          final appName = args['appName'] as String? ?? '';
          if (appName.isEmpty) return {'error': 'appName required'};
          return await _appService.launchAppByName(appName);
        case 'get_recent_screenshots':
          return {'screenshots': await _fileService.getRecentScreenshots()};
        case 'search_contacts':
          return {'contacts': await _personalService.searchContacts(args['query'] as String? ?? '')};
        case 'schedule_event':
          final title = args['title'] as String? ?? '';
          final startStr = args['start'] as String? ?? '';
          final endStr = args['end'] as String? ?? '';
          if (title.isEmpty || startStr.isEmpty || endStr.isEmpty) {
            return {'error': 'title, start, and end are required'};
          }
          try {
            return {
              'success': await _personalService.scheduleEvent(
                title: title,
                start: DateTime.parse(startStr),
                end: DateTime.parse(endStr),
                description: args['description'] as String?,
              )
            };
          } catch (e) {
            return {'error': 'Invalid date format: $e'};
          }
        case 'send_whatsapp':
          final phone = args['phone'] as String? ?? '';
          final message = args['message'] as String? ?? '';
          if (phone.isEmpty || message.isEmpty) return {'error': 'phone and message required'};
          return {'success': await _personalService.sendWhatsApp(phone, message)};
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
