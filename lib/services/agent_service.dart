import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
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
  AgentResponse(this.text, this.modelName, this.retryCount,
      {this.tps, this.evalTime, this.toolName});
}

class AgentService {
  static final AgentService _instance = AgentService._internal();
  factory AgentService() => _instance;
  AgentService._internal();

  static const String _modelName = 'Gemma 4 E2B';

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

    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(modelPath).install();

    // Gemma 4 E2B supports a much larger KV window than the old Qwen .task
    // (ekv1280). We give the agent room for real tool conversations.
    // Gemma 4 E2B is multimodal — enable vision so users can attach images.
    _model = await FlutterGemma.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );

    _statusController.add('');
  }

  Future<void> loadSession(int sessionId) async {
    final history = await _dbService.getChatHistory(sessionId);
    final replay = <Message>[];
    for (final msg in history) {
      final role = msg['role'] as String;
      if (role != 'user' && role != 'assistant') continue;
      replay.add(Message.text(
        text: msg['content'] as String,
        isUser: role == 'user',
      ));
    }
    await _rebuildChat(replay);
  }

  Future<void> _rebuildChat(List<Message> replay) async {
    if (_model == null) return;

    _chat = await _model!.createChat(
      temperature: 0.7,
      randomSeed: 1,
      topK: 40,
      topP: 0.95,
      tokenBuffer: 256,
      supportsFunctionCalls: true,
      tools: _tools,
      modelType: ModelType.gemma4,
      // Required for Gemma 4: enables the `<|channel>thought\n…<channel|>`
      // filter so reasoning tokens are stripped from the visible stream and
      // surfaced as ThinkingResponse events instead. Without this they leak
      // through as raw text in the chat bubble.
      isThinking: true,
    );

    // Seed the new chat with a system instruction. Kept short so we don't
    // burn KV budget — Gemma 4 already understands its role from training.
    await _chat!.addQuery(Message.text(
      text: _getSystemPrompt(),
      isUser: true,
    ));
    await _chat!.addQuery(Message.text(
      text: "Understood. I'm ready to help.",
      isUser: false,
    ));

    for (final m in replay) {
      await _chat!.addQuery(m);
    }
  }

  String _getSystemPrompt() {
    return '''You are ONYX, an on-device AI agent running on the user's Android phone. You are agentic: you chain tools to actually accomplish what the user asks, and you don't stop at half a step.

Decision flow:
1. If the user attached an image, that image is in this message — look at it directly. Do NOT call get_recent_screenshots or list_files for an attached image; those tools are only for files already on the device.
2. If the request needs current/device-specific data (apps, files, contacts, clipboard, weather, news, what's on the screen), call the right tool — don't guess from memory.
3. If a request needs more than one step, chain tools. Examples:
   - "message Sarah on WhatsApp" → search_contacts("Sarah") → send_whatsapp(<found-number>, message).
   - "open the biggest app" → list_apps → launch_app_by_name with the top result.
4. For chit-chat, greetings, definitions, and general knowledge already in your training, reply directly without a tool.

Hard rules:
- NEVER fabricate phone numbers, emails, contact names, addresses, or any personal data. If a lookup returns nothing, say so.
- When listing apps to uninstall or by size, use the sizeMB field from list_apps and present name + size, biggest first.
- When opening an app by its display name, prefer launch_app_by_name over guessing the package name.
- After a tool runs, summarize the result in one or two short sentences. Be concise.''';
  }

  Future<AgentResponse> sendMessage(
    String text,
    int sessionId, {
    String? imagePath,
  }) async {
    if (_chat == null) throw Exception('Model not initialized');

    try {
      await FlutterBackground.enableBackgroundExecution();
    } catch (_) {}
    _statusController.add('Thinking...');

    Message userMessage;
    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final Uint8List bytes = await File(imagePath).readAsBytes();
        userMessage = Message.withImage(
          text: text,
          imageBytes: bytes,
          isUser: true,
        );
      } catch (_) {
        userMessage = Message.text(text: text, isUser: true);
      }
    } else {
      userMessage = Message.text(text: text, isUser: true);
    }

    await _chat!.addQuery(userMessage);

    final result = await _streamResponseAndHandleTools(sessionId);

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (_) {}
    _statusController.add('');

    return result;
  }

  // Stream the model's response. If it emits a function call, execute the
  // tool and either short-circuit with a templated reply (simple commands)
  // or feed the result back and stream the model's natural-language summary.
  Future<AgentResponse> _streamResponseAndHandleTools(int sessionId) async {
    String fullText = '';
    String? toolName;
    Map<String, dynamic>? toolArgs;
    int tokenCount = 0;
    final startTime = DateTime.now();
    bool streamStarted = false;

    await for (final response in _chat!.generateChatResponseAsync()) {
      if (response is TextResponse) {
        final token = response.token;
        if (token.isEmpty) continue;
        if (!streamStarted) {
          streamStarted = true;
          _tokenStreamController.add('\x00');
        }
        fullText += token;
        tokenCount++;
        _tokenStreamController.add(token);
      } else if (response is FunctionCallResponse) {
        toolName = response.name;
        toolArgs = Map<String, dynamic>.from(response.args);
        // Tool interrupted the stream — \x02 tells the UI to clear the
        // streaming bubble immediately so users don't see flashed JSON-ish
        // fragments. \x01 (used at clean end-of-response) preserves the text
        // so the final ChatMessage can slot in without a one-frame gap.
        if (streamStarted) {
          _tokenStreamController.add('\x02');
          streamStarted = false;
        }
        fullText = '';
        break;
      } else if (response is ParallelFunctionCallResponse) {
        // Only honor the first tool — keeps the agent loop deterministic.
        if (response.calls.isNotEmpty) {
          toolName = response.calls.first.name;
          toolArgs = Map<String, dynamic>.from(response.calls.first.args);
        }
        if (streamStarted) {
          _tokenStreamController.add('\x02');
          streamStarted = false;
        }
        fullText = '';
        break;
      } else if (response is ThinkingResponse) {
        // Surface thinking as a status update but don't store it.
        _statusController.add('Reasoning...');
      }
    }

    final evalTimeMs = DateTime.now().difference(startTime).inMilliseconds;
    final double tps = evalTimeMs > 0 && tokenCount > 0
        ? tokenCount / (evalTimeMs / 1000.0)
        : 0;

    if (streamStarted) {
      _tokenStreamController.add('\x01');
      streamStarted = false;
    }

    if (toolName != null) {
      return _handleToolCall(
        sessionId,
        toolName,
        toolArgs ?? {},
        tps,
        evalTimeMs / 1000.0,
      );
    }

    final finalText = fullText.trim().isEmpty
        ? "I'm not sure how to help with that. Could you rephrase?"
        : fullText.trim();

    await _dbService.saveMessage('assistant', finalText, sessionId);

    return AgentResponse(finalText, _modelName, 0,
        tps: tps, evalTime: evalTimeMs / 1000.0);
  }

  Future<AgentResponse> _handleToolCall(
    int sessionId,
    String toolName,
    Map<String, dynamic> args,
    double priorTps,
    double priorEvalTime,
  ) async {
    _statusController.add('Running $toolName...');
    final toolResult = await _executeTool(toolName, args);

    // Feed the result back into chat history so the model knows what happened.
    await _chat!.addQuery(Message.toolResponse(
      toolName: toolName,
      response: toolResult,
    ));

    // For simple actions (flashlight, vibrate, etc.) we have a clean templated
    // reply — return it immediately and skip a second model call. The chat
    // history still has the tool response so future turns stay coherent.
    final direct = _formatToolResult(toolName, args, toolResult);
    if (direct != null) {
      await _dbService.saveMessage('assistant', direct, sessionId);
      return AgentResponse(direct, _modelName, 0,
          tps: priorTps, evalTime: priorEvalTime, toolName: toolName);
    }

    // Complex tool (search, list_apps, device_info, ...) — let the model
    // summarize naturally.
    _statusController.add('Summarizing...');
    final followUp = await _streamResponseAndHandleTools(sessionId);
    return AgentResponse(
      followUp.text,
      _modelName,
      0,
      tps: followUp.tps ?? priorTps,
      evalTime: followUp.evalTime ?? priorEvalTime,
      toolName: toolName,
    );
  }

  /// Direct templated reply for tools where the result is trivially stringifiable.
  /// Returns null for tools where the model should summarize.
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
        return result['success'] == true
            ? 'App launched.'
            : 'Could not launch that app.';

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

  // ─── Tool declarations ───
  // The model sees these as native function declarations via the LiteRT-LM
  // chat template. Keep descriptions concrete and parameters strict.
  static final List<Tool> _tools = const [
    Tool(
      name: 'get_date_time',
      description:
          'Get the current local date, time, day of the week, and timezone.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_device_info',
      description:
          'Get device manufacturer, model, OS version, battery percentage, '
          'free and total storage, and RAM.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'check_connectivity',
      description:
          'Check whether the device is online, the connection type (WiFi or cellular), '
          'WiFi SSID, and local IP address.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_public_ip',
      description: 'Get the public IP address of the device.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_web',
      description:
          'Search the web for facts, news, weather, sports scores, or anything '
          'that needs up-to-date information. Use this whenever the user asks '
          'about real-world current events or topics outside your training.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query in natural language.',
          },
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'open_url',
      description: 'Open a URL in the device default browser.',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The full URL including https://',
          },
        },
        'required': ['url'],
      },
    ),
    Tool(
      name: 'list_files',
      description:
          'List documents on the device (PDFs, text, images). Use when the user '
          'asks about their files.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'list_apps',
      description:
          'List apps installed on the device. Returns each app\'s name, '
          'package name, and approximate disk size in MB (sizeMB). Results are '
          'sorted largest-first, so this is the right tool to use when the '
          'user asks what to uninstall, what is taking up space, or for app '
          'sizes. Always present names and sizes in your reply.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'launch_app_by_name',
      description:
          'Launch an installed app by its display name (e.g. "WhatsApp", "Calculator").',
      parameters: {
        'type': 'object',
        'properties': {
          'appName': {
            'type': 'string',
            'description': 'The display name of the app.',
          },
        },
        'required': ['appName'],
      },
    ),
    Tool(
      name: 'launch_app',
      description: 'Launch an installed app by its Android package name.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {
            'type': 'string',
            'description': 'The Android package name (e.g. com.whatsapp).',
          },
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'uninstall_app',
      description: 'Open the Android uninstall dialog for the given package.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {'type': 'string'},
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'search_play_store',
      description: 'Search the Google Play Store for an app.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'open_play_store',
      description: 'Open a specific app page in the Google Play Store.',
      parameters: {
        'type': 'object',
        'properties': {
          'packageName': {'type': 'string'},
        },
        'required': ['packageName'],
      },
    ),
    Tool(
      name: 'toggle_flashlight',
      description: 'Turn the device flashlight on or off.',
      parameters: {
        'type': 'object',
        'properties': {
          'on': {
            'type': 'boolean',
            'description': 'true to turn on, false to turn off.',
          },
        },
        'required': ['on'],
      },
    ),
    Tool(
      name: 'vibrate',
      description: 'Vibrate the device for the given duration in milliseconds.',
      parameters: {
        'type': 'object',
        'properties': {
          'duration': {
            'type': 'integer',
            'description': 'Duration in milliseconds. Default 500.',
          },
        },
      },
    ),
    Tool(
      name: 'set_volume',
      description: 'Set the device media volume.',
      parameters: {
        'type': 'object',
        'properties': {
          'level': {
            'type': 'number',
            'description': 'Volume level between 0.0 and 1.0.',
          },
        },
        'required': ['level'],
      },
    ),
    Tool(
      name: 'copy_to_clipboard',
      description: 'Copy text to the device clipboard.',
      parameters: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    ),
    Tool(
      name: 'read_clipboard',
      description:
          'Read whatever text is currently on the device clipboard. Use this '
          'when the user asks about their clipboard or what they just copied.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'get_recent_screenshots',
      description: 'Get a list of the recent screenshots on the device.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    Tool(
      name: 'search_contacts',
      description:
          'Search the device contacts by name. Returns matching contacts with '
          'their phone numbers and emails. Call this FIRST whenever the user '
          'asks to message, call, or look up someone by name — the result '
          'gives you the phone number to pass to send_whatsapp.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The contact name to search for (partial match OK).',
          },
        },
        'required': ['query'],
      },
    ),
    Tool(
      name: 'schedule_event',
      description: 'Create a calendar event on the device.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'start': {
            'type': 'string',
            'description': 'ISO-8601 start datetime.',
          },
          'end': {
            'type': 'string',
            'description': 'ISO-8601 end datetime.',
          },
          'description': {'type': 'string'},
        },
        'required': ['title', 'start', 'end'],
      },
    ),
    Tool(
      name: 'send_whatsapp',
      description:
          'Open WhatsApp with a prefilled message for a phone number. '
          'IMPORTANT: only call this when you have a real phone number from '
          'the user or from a previous search_contacts result. NEVER invent '
          'or use placeholder numbers — if you don\'t know the number, call '
          'search_contacts first to look up the contact by name.',
      parameters: {
        'type': 'object',
        'properties': {
          'phone': {
            'type': 'string',
            'description':
                'Phone number in international format (e.g. +14155551234). '
                'Must come from search_contacts or directly from the user.',
          },
          'message': {'type': 'string'},
        },
        'required': ['phone', 'message'],
      },
    ),
  ];

  Future<Map<String, dynamic>> _executeTool(
      String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'get_date_time':
          final now = DateTime.now();
          const days = [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday', 'Sunday'
          ];
          return {
            'date':
                '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
            'time':
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            'dayOfWeek': days[now.weekday - 1],
            'timezone': now.timeZoneName,
          };
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'get_public_ip':
          return await _searchService.getPublicIP();
        case 'list_files':
          final files = await _fileService.indexDocuments();
          return {
            'files': files
                .take(30)
                .map((f) => {'name': f.name, 'path': f.path})
                .toList(),
            'total': files.length,
          };
        case 'toggle_flashlight':
          return {
            'success': await _utilityService
                .toggleFlashlight(args['on'] as bool? ?? true)
          };
        case 'list_apps':
          final apps = await _appService.getInstalledApps();
          // Sort largest-first so "what should I uninstall?" lands the
          // useful entries at the top, then truncate. Apps with unknown
          // size fall to the bottom.
          apps.sort((a, b) =>
              (b['sizeBytes'] as int? ?? 0).compareTo(a['sizeBytes'] as int? ?? 0));
          return {
            'apps': apps.take(60).map((a) {
              final bytes = a['sizeBytes'] as int? ?? 0;
              final mb = bytes > 0 ? (bytes / (1024 * 1024)) : 0;
              return {
                'name': a['name'],
                'pkg': a['packageName'],
                'sizeMB': mb > 0 ? double.parse(mb.toStringAsFixed(1)) : null,
              };
            }).toList(),
            'total': apps.length,
            'sortedBySizeDesc': true,
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
          return {
            'text': await _utilityService.readFromClipboard() ?? 'Clipboard is empty'
          };
        case 'check_connectivity':
          return await _utilityService.checkConnectivityDetailed();
        case 'search_web':
          final query = args['query'] as String? ?? '';
          if (query.isEmpty) return {'error': 'query required'};
          final raw = await _searchService.searchWeb(query);
          return _truncate(raw, 1500);
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
          return {
            'contacts':
                await _personalService.searchContacts(args['query'] as String? ?? '')
          };
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
          if (phone.isEmpty || message.isEmpty) {
            return {'error': 'phone and message required'};
          }
          return {'success': await _personalService.sendWhatsApp(phone, message)};
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // Truncate a JSON-shaped result so a single tool response doesn't blow
  // out the 4K KV window when fed back to the model.
  Map<String, dynamic> _truncate(Map<String, dynamic> result, int maxChars) {
    final encoded = jsonEncode(result);
    if (encoded.length <= maxChars) return result;
    return {
      'summary': encoded.substring(0, maxChars),
      'note': 'Result truncated to fit context window.',
    };
  }
}
