import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openai_dart/openai_dart.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'database_service.dart';
import 'app_service.dart';
import 'utility_service.dart';
import 'personal_service.dart';
import 'package:intl/intl.dart';

class AgentService {
  late OpenAIClient _client;
  final List<ChatCompletionMessage> _messages = [];
  
  final DeviceService _deviceService = DeviceService();
  final FileService _fileService = FileService();
  final DatabaseService _dbService = DatabaseService();
  final AppService _appService = AppService();
  final UtilityService _utilityService = UtilityService();
  final PersonalService _personalService = PersonalService();

  Future<void> initialize() async {
    String? apiKey = dotenv.env['GROQ_API_KEY'];
    
    // Fallback to SharedPreferences if not found in .env
    if (apiKey == null || apiKey.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      apiKey = prefs.getString('api_key');
    }

    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Groq API Key not found. Please set it in Settings or .env file.');
    }

    _client = OpenAIClient(
      apiKey: apiKey,
      baseUrl: 'https://api.groq.com/openai/v1',
    );

    _messages.clear();
    _messages.add(
      ChatCompletionMessage.system(
        content: '''
          You are a powerful, autonomous local AI agent running on the user's Android device. 
          You have full access to manage the local file system (including Screenshots), device hardware status, INSTALLED APPS, and SYSTEM UTILITIES.
          You can search, read, or DELETE files, and you can also LIST, LAUNCH, or trigger UNINSTALLS for apps.
          You have hardware control: you can toggle the FLASHLIGHT, adjust VOLUME, and VIBRATE the device.
          You can manage the CLIPBOARD and check NETWORK status (IP, connectivity).
          You have access to the user's PERSONAL DATA: you can search CONTACTS, view/schedule CALENDAR events, and send WHATSAPP messages.
          Always be precise and careful when performing destructive actions like deletion or uninstallation.
          If the user asks a general question, answer normally.
        ''',
      ),
    );
  }

  Future<String> sendMessage(String text) async {
    _messages.add(ChatCompletionMessage.user(content: ChatCompletionUserMessageContent.string(text)));

    int retryCount = 0;
    const int maxRetries = 3;

    final tools = [
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'get_device_info',
          description: 'Retrieves the current device hardware info, battery level, and available storage space.',
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'search_files',
          description: 'Searches the local indexed files by name or extension.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'The search query or keyword',
              },
            },
            'required': ['query'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'read_file',
          description: 'Reads the content of a file given its exact path.',
          parameters: {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'The absolute path to the file',
              },
            },
            'required': ['path'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'delete_file',
          description: 'Deletes a file permanently from the device storage. Use with caution.',
          parameters: {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'The absolute path to the file to delete',
              },
            },
            'required': ['path'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'list_apps',
          description: 'Lists all installed applications on the device (names and package IDs).',
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'uninstall_app',
          description: 'Triggers the system uninstall dialog for a specific app.',
          parameters: {
            'type': 'object',
            'properties': {
              'packageName': {
                'type': 'string',
                'description': 'The package ID of the app to uninstall (e.g., com.example.app)',
              },
            },
            'required': ['packageName'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'launch_app',
          description: 'Launches/Opens a specific app installed on the device.',
          parameters: {
            'type': 'object',
            'properties': {
              'packageName': {
                'type': 'string',
                'description': 'The package ID of the app to launch',
              },
            },
            'required': ['packageName'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'open_play_store',
          description: 'Opens the Play Store page for a specific app.',
          parameters: {
            'type': 'object',
            'properties': {
              'packageName': {
                'type': 'string',
                'description': 'The package ID of the app to find in Play Store',
              },
            },
            'required': ['packageName'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'toggle_flashlight',
          description: 'Turns the device flashlight on or off.',
          parameters: {
            'type': 'object',
            'properties': {
              'enable': {
                'type': 'boolean',
                'description': 'True to turn on, False to turn off',
              },
            },
            'required': ['enable'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'vibrate',
          description: 'Makes the device vibrate.',
          parameters: {
            'type': 'object',
            'properties': {
              'durationMs': {
                'type': 'integer',
                'description': 'Duration of vibration in milliseconds',
              },
            },
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'set_volume',
          description: 'Sets the device system volume.',
          parameters: {
            'type': 'object',
            'properties': {
              'level': {
                'type': 'number',
                'description': 'Volume level from 0.0 to 1.0',
              },
            },
            'required': ['level'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'get_network_info',
          description: 'Retrieves public IP and connectivity status.',
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'clipboard_copy',
          description: 'Copies text to the device clipboard.',
          parameters: {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description': 'The text to copy',
              },
            },
            'required': ['text'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'clipboard_paste',
          description: 'Reads text from the device clipboard.',
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'search_contacts',
          description: 'Searches for contacts by name.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'The name or part of the name to search for',
              },
            },
            'required': ['query'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'get_calendar_events',
          description: 'Retrieves calendar events for a date range.',
          parameters: {
            'type': 'object',
            'properties': {
              'startDate': {
                'type': 'string',
                'description': 'ISO 8601 start date string',
              },
              'endDate': {
                'type': 'string',
                'description': 'ISO 8601 end date string',
              },
            },
            'required': ['startDate', 'endDate'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'schedule_event',
          description: 'Schedules a new event in the user\'s calendar.',
          parameters: {
            'type': 'object',
            'properties': {
              'title': { 'type': 'string' },
              'start': { 'type': 'string', 'description': 'ISO 8601 start time' },
              'end': { 'type': 'string', 'description': 'ISO 8601 end time' },
              'description': { 'type': 'string' },
            },
            'required': ['title', 'start', 'end'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'whatsapp_send',
          description: 'Opens WhatsApp with a pre-filled message for a contact.',
          parameters: {
            'type': 'object',
            'properties': {
              'phone': { 'type': 'string', 'description': 'Phone number with country code' },
              'message': { 'type': 'string' },
            },
            'required': ['phone', 'message'],
          },
        ),
      ),
    ];

    while (retryCount < maxRetries) {
      try {
        final request = CreateChatCompletionRequest(
          model: ChatCompletionModel.modelId('llama-3.3-70b-versatile'),
          messages: _messages,
          tools: tools,
          toolChoice: ChatCompletionToolChoiceOption.mode(ChatCompletionToolChoiceMode.auto),
        );

        var response = await _client.createChatCompletion(request: request);
        var choice = response.choices.first;
        var message = choice.message;

        _messages.add(ChatCompletionMessage.assistant(
          content: message.content,
          toolCalls: message.toolCalls,
        ));

        // Agent Loop for tool calling
        while (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
          for (final toolCall in message.toolCalls!) {
            if (toolCall is ChatCompletionMessageToolCall) {
              final result = await _executeTool(
                toolCall.function.name,
                toolCall.function.arguments,
              );
              _messages.add(ChatCompletionMessage.tool(
                toolCallId: toolCall.id,
                content: jsonEncode(result),
              ));
            }
          }

          final nextRequest = CreateChatCompletionRequest(
            model: ChatCompletionModel.modelId('llama-3.3-70b-versatile'),
            messages: _messages,
            tools: tools,
          );

          response = await _client.createChatCompletion(request: nextRequest);
          choice = response.choices.first;
          message = choice.message;
          
          _messages.add(ChatCompletionMessage.assistant(
            content: message.content,
            toolCalls: message.toolCalls,
          ));
        }

        return message.content ?? 'No response';
      } catch (e) {
        if (e.toString().contains('503') || e.toString().contains('429')) {
          retryCount++;
          await Future.delayed(Duration(seconds: 2 * retryCount)); // Exponential backoff
          continue;
        }
        return 'Error: $e';
      }
    }
    return 'Error: Maximum retries reached due to server load.';
  }

  Future<Map<String, dynamic>> _executeTool(String name, String? argumentsJson) async {
    print('Executing tool: $name with args: $argumentsJson');
    
    Map<String, dynamic> args = {};
    if (argumentsJson != null && argumentsJson.isNotEmpty) {
      try {
        args = jsonDecode(argumentsJson) as Map<String, dynamic>;
      } catch (e) {
        print('Error decoding arguments: $e');
      }
    }

    try {
      switch (name) {
        case 'get_device_info':
          return await _deviceService.getDeviceInfo();
        case 'search_files':
          final query = args['query'] as String? ?? '';
          final files = await _dbService.searchFiles(query);
          return {'result': files};
        case 'read_file':
          final path = args['path'] as String? ?? '';
          final content = await _fileService.readFileContent(path);
          return {'content': content};
        case 'delete_file':
          final path = args['path'] as String? ?? '';
          final success = await _fileService.deleteFile(path);
          return {'success': success, 'path': path};
        case 'list_apps':
          return {'apps': await _appService.getInstalledApps()};
        case 'uninstall_app':
          final pkg = args['packageName'] as String? ?? '';
          final success = await _appService.uninstallApp(pkg);
          return {'triggered': success, 'packageName': pkg};
        case 'launch_app':
          final pkg = args['packageName'] as String? ?? '';
          final success = await _appService.launchApp(pkg);
          return {'success': success, 'packageName': pkg};
        case 'open_play_store':
          final pkg = args['packageName'] as String? ?? '';
          final success = await _appService.openPlayStore(pkg);
          return {'success': success, 'packageName': pkg};
        case 'toggle_flashlight':
          final enable = args['enable'] as bool? ?? false;
          final success = await _utilityService.toggleFlashlight(enable);
          return {'success': success, 'enabled': enable};
        case 'vibrate':
          final duration = args['durationMs'] as int? ?? 500;
          await _utilityService.vibrate(duration: duration);
          return {'success': true};
        case 'set_volume':
          final level = (args['level'] as num? ?? 0.5).toDouble();
          await _utilityService.setVolume(level);
          return {'success': true, 'level': level};
        case 'get_network_info':
          final ip = await _utilityService.getPublicIP();
          final conn = await _utilityService.checkConnectivity();
          return {'publicIP': ip, 'connectivity': conn};
        case 'clipboard_copy':
          final text = args['text'] as String? ?? '';
          await _utilityService.copyToClipboard(text);
          return {'success': true};
        case 'clipboard_paste':
          final text = await _utilityService.readFromClipboard();
          return {'text': text};
        case 'search_contacts':
          final query = args['query'] as String? ?? '';
          return {'contacts': await _personalService.searchContacts(query)};
        case 'get_calendar_events':
          final start = DateTime.parse(args['startDate'] as String);
          final end = DateTime.parse(args['endDate'] as String);
          return {'events': await _personalService.getCalendarEvents(start, end)};
        case 'schedule_event':
          final title = args['title'] as String;
          final start = DateTime.parse(args['start'] as String);
          final end = DateTime.parse(args['end'] as String);
          final desc = args['description'] as String?;
          final success = await _personalService.scheduleEvent(
            title: title, start: start, end: end, description: desc,
          );
          return {'success': success};
        case 'whatsapp_send':
          final phone = args['phone'] as String;
          final msg = args['message'] as String;
          final success = await _personalService.sendWhatsApp(phone, msg);
          return {'success': success};
        default:
          return {'error': 'Unknown tool: $name'};
      }
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
