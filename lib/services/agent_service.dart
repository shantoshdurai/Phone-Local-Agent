import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openai_dart/openai_dart.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'device_service.dart';
import 'file_service.dart';
import 'database_service.dart';
import 'app_service.dart';
import 'utility_service.dart';
import 'personal_service.dart';
import 'search_service.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:google_generative_ai/google_generative_ai.dart' as gemini;
import '../models/chat_message.dart';

class AgentResponse {
  final String text;
  final String modelName;
  final int retryCount;
  AgentResponse(this.text, this.modelName, this.retryCount);
}

class AgentService {
  late OpenAIClient _client;
  gemini.GenerativeModel? _geminiModel;
  gemini.ChatSession? _geminiChat;
  final List<ChatCompletionMessage> _messages = [];
  
  final DeviceService _deviceService = DeviceService();
  final FileService _fileService = FileService();
  final DatabaseService _dbService = DatabaseService();
  final AppService _appService = AppService();
  final UtilityService _utilityService = UtilityService();
  final PersonalService _personalService = PersonalService();
  final SearchService _searchService = SearchService();
  
  List<String> _textModels = [
    'llama-3.3-70b-versatile',
    'gemma2-9b-it',
  ];

  List<String> _visionModels = [
    'llama-3.2-11b-vision-preview',
  ];

  bool _isGemini = false;
  String? _activeApiKey;
  int _geminiModelIndex = 0;
  final List<String> _geminiModels = [
    'gemini-1.5-pro',
    'gemini-1.5-flash',
    'gemini-1.5-flash-8b',
  ];
  
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  void _updateStatus(String status) {
    _statusController.add(status);
  }
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    String? geminiKey = dotenv.env['GEMINI_API_KEY'] ?? prefs.getString('gemini_api_key');
    String? groqKey = dotenv.env['GROQ_API_KEY'] ?? prefs.getString('api_key');
    
    String? apiKey = geminiKey ?? groqKey;

    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('API Key not found. Please set it in Settings or .env file.');
    }

    // Auto-detect Gemini vs Groq
    _isGemini = apiKey.startsWith('AIza');
    _activeApiKey = apiKey;
    
    if (_isGemini) {
      _geminiModel = gemini.GenerativeModel(
        model: _geminiModels[_geminiModelIndex % _geminiModels.length],
        apiKey: _activeApiKey!,
        systemInstruction: gemini.Content.system(_getSystemPrompt()),
        tools: [_getGeminiTools()],
      );
      _geminiChat = _geminiModel!.startChat();
    } else {
      _client = OpenAIClient(
        apiKey: _activeApiKey!,
        baseUrl: 'https://api.groq.com/openai/v1',
      );
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
      if (role == 'user') {
        _messages.add(ChatCompletionMessage.user(content: ChatCompletionUserMessageContent.string(content)));
      } else if (role == 'assistant') {
        _messages.add(ChatCompletionMessage.assistant(content: content));
      }
    }
  }

  String _getSystemPrompt() {
    return '''
          You are **Agent**, a high-performance, autonomous AI OS agent for Android. 
          You don't just "talk"; you **act**. Your goal is to solve the user's request by intelligently chaining the tools provided.

          ### 🧠 THOUGHT PROCESS (Internal)
          Before calling any tool, you must:
          1. **Analyze**: What is the core intent? (e.g., "Find a file", "System control", "Information query").
          2. **Plan**: Do I need multiple steps? (e.g., `list_apps` -> `uninstall_app`).
          3. **Verify**: Did the tool succeed? If not, why? (e.g., "File not found" -> Try `search_files` with a partial name).

          ### 🛠 TOOL MASTERY RULES
          1. **Direct Action**: Never ask "Would you like me to...?" Just do it. If the user says "Uninstall WhatsApp," call the tool immediately.
          2. **Package Name Accuracy**: For app actions, if you aren't 100% sure of the `packageName`, call `list_apps` first. If you want to open the Play Store for an app but don't know the package ID, use `search_play_store` with the app name.
          3. **Search Depth**: When searching for files, use broad queries. If "Project_Doc_v2.pdf" fails, try searching for "Project" or ".pdf".
          4. **Web Search Diligence**: When searching the web (e.g., for APK downloads), carefully inspect the "links" and "result" fields in the tool output. 
             - For WhatsApp, try official URLs like `https://www.whatsapp.com/android/` or `https://www.whatsapp.com/download`.
             - Reputable mirrors like `apkmirror.com` or `apkpure.com` are also acceptable.
             - If you find a direct APK link, use the `download_file` tool immediately.
          5. **Hardware Authority**: When reporting specs (RAM, CPU), use the exact keys from `get_device_info`. NEVER use phrases like "depending on the variant" or "it seems".
          6. **Autonomous Recovery**: If a tool returns an error, look at the error message and try a different tool or a different argument. Be a problem solver.
          7. **Concise Reporting**: After successful tool use, give a brief, professional confirmation. "Flashlight toggled." is better than a long paragraph.

          ### 🛡 SAFETY & PRIVACY
          - Only delete files if explicitly asked.
          - Never share API keys or system-level tokens.

          Capabilities: File System, App Management, Play Store, Hardware Control, System Settings, Web Navigation, Communications (WhatsApp).
    ''';
  }

  void _addSystemInstruction() {
    _messages.add(
      ChatCompletionMessage.system(
        content: _getSystemPrompt(),
      ),
    );
  }

  gemini.Tool _getGeminiTools() {
    return gemini.Tool(functionDeclarations: [
      gemini.FunctionDeclaration(
        'get_device_info',
        'Retrieves current device hardware info, battery, and storage.',
        gemini.Schema(gemini.SchemaType.object, properties: {}),
      ),
      gemini.FunctionDeclaration(
        'search_files',
        'Searches the entire local file system for files.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'query': gemini.Schema(gemini.SchemaType.string, description: 'Keyword or filename'),
          },
          requiredProperties: ['query'],
        ),
      ),
      gemini.FunctionDeclaration(
        'read_file',
        'Reads the full content of a file.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'path': gemini.Schema(gemini.SchemaType.string, description: 'Absolute path'),
          },
          requiredProperties: ['path'],
        ),
      ),
      gemini.FunctionDeclaration(
        'delete_file',
        'Deletes a file permanently.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'path': gemini.Schema(gemini.SchemaType.string, description: 'Absolute path'),
          },
          requiredProperties: ['path'],
        ),
      ),
      gemini.FunctionDeclaration(
        'list_apps',
        'Lists all installed applications.',
        gemini.Schema(gemini.SchemaType.object, properties: {}),
      ),
      gemini.FunctionDeclaration(
        'uninstall_app',
        'Triggers system uninstall for an app.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'packageName': gemini.Schema(gemini.SchemaType.string, description: 'App package ID'),
          },
          requiredProperties: ['packageName'],
        ),
      ),
      gemini.FunctionDeclaration(
        'launch_app',
        'Launches a specific app.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'packageName': gemini.Schema(gemini.SchemaType.string, description: 'App package ID'),
          },
          requiredProperties: ['packageName'],
        ),
      ),
      gemini.FunctionDeclaration(
        'toggle_flashlight',
        'Turns flashlight on/off.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'enable': gemini.Schema(gemini.SchemaType.boolean, description: 'True to enable'),
          },
          requiredProperties: ['enable'],
        ),
      ),
      gemini.FunctionDeclaration(
        'get_recent_screenshots',
        'Retrieves paths to the most recent screenshots on the device.',
        gemini.Schema(gemini.SchemaType.object, properties: {}),
      ),
      gemini.FunctionDeclaration(
        'search_play_store',
        'Searches for an app in the Play Store.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'query': gemini.Schema(gemini.SchemaType.string, description: 'App name or search query'),
          },
          requiredProperties: ['query'],
        ),
      ),
      gemini.FunctionDeclaration(
        'open_web_url',
        'Opens a website or deep link in the system browser.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'url': gemini.Schema(gemini.SchemaType.string, description: 'Full URL (e.g., https://instagram.com)'),
          },
          requiredProperties: ['url'],
        ),
      ),
      gemini.FunctionDeclaration(
        'google_search',
        'Searches the live web for information.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'query': gemini.Schema(gemini.SchemaType.string, description: 'Search query'),
          },
          requiredProperties: ['query'],
        ),
      ),
      gemini.FunctionDeclaration(
        'get_network_info',
        'Retrieves public IP and connectivity status.',
        gemini.Schema(gemini.SchemaType.object, properties: {}),
      ),
      gemini.FunctionDeclaration(
        'download_file',
        'Downloads a file or APK from a URL.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'url': gemini.Schema(gemini.SchemaType.string, description: 'Direct URL'),
            'fileName': gemini.Schema(gemini.SchemaType.string, description: 'Save as name'),
          },
          requiredProperties: ['url', 'fileName'],
        ),
      ),
      gemini.FunctionDeclaration(
        'clipboard_copy',
        'Copies text to clipboard.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'text': gemini.Schema(gemini.SchemaType.string, description: 'Text to copy'),
          },
          requiredProperties: ['text'],
        ),
      ),
      gemini.FunctionDeclaration(
        'clipboard_paste',
        'Reads text from clipboard.',
        gemini.Schema(gemini.SchemaType.object, properties: {}),
      ),
      gemini.FunctionDeclaration(
        'search_contacts',
        'Searches for contacts by name.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'query': gemini.Schema(gemini.SchemaType.string, description: 'Name to search'),
          },
          requiredProperties: ['query'],
        ),
      ),
      gemini.FunctionDeclaration(
        'get_calendar_events',
        'Retrieves calendar events for a range.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'startDate': gemini.Schema(gemini.SchemaType.string, description: 'ISO 8601 start'),
            'endDate': gemini.Schema(gemini.SchemaType.string, description: 'ISO 8601 end'),
          },
          requiredProperties: ['startDate', 'endDate'],
        ),
      ),
      gemini.FunctionDeclaration(
        'schedule_event',
        'Schedules a new calendar event.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'title': gemini.Schema(gemini.SchemaType.string),
            'start': gemini.Schema(gemini.SchemaType.string, description: 'ISO 8601 start'),
            'end': gemini.Schema(gemini.SchemaType.string, description: 'ISO 8601 end'),
            'description': gemini.Schema(gemini.SchemaType.string),
          },
          requiredProperties: ['title', 'start', 'end'],
        ),
      ),
      gemini.FunctionDeclaration(
        'set_volume',
        'Sets the device system volume (0.0 to 1.0).',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'level': gemini.Schema(gemini.SchemaType.number),
          },
          requiredProperties: ['level'],
        ),
      ),
      gemini.FunctionDeclaration(
        'vibrate',
        'Makes the device vibrate.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'durationMs': gemini.Schema(gemini.SchemaType.integer),
          },
        ),
      ),
      gemini.FunctionDeclaration(
        'whatsapp_send',
        'Opens WhatsApp with a pre-filled message.',
        gemini.Schema(
          gemini.SchemaType.object,
          properties: {
            'phone': gemini.Schema(gemini.SchemaType.string, description: 'Phone with country code'),
            'message': gemini.Schema(gemini.SchemaType.string),
          },
          requiredProperties: ['phone', 'message'],
        ),
      ),
    ]);
  }

  Future<AgentResponse> sendMessage(String text, int sessionId, {String? imagePath}) async {
    if (imagePath != null) {
      final bytes = await File(imagePath).readAsBytes();
      final base64Image = base64Encode(bytes);
      _messages.add(ChatCompletionMessage.user(
        content: ChatCompletionUserMessageContent.parts([
          ChatCompletionMessageContentPart.text(text: text),
          ChatCompletionMessageContentPart.image(
            imageUrl: ChatCompletionMessageImageUrl(
              url: 'data:image/jpeg;base64,$base64Image',
            ),
          ),
        ]),
      ));
    } else {
      _messages.add(ChatCompletionMessage.user(content: ChatCompletionUserMessageContent.string(text)));
    }
    
    if (_isGemini) {
      return await _sendGeminiMessage(text, sessionId, imagePath: imagePath);
    }

    // Original Groq Logic below
    int retryCount = 0;
    const int maxRetries = 5;
    int textModelIndex = 0;
    int visionModelIndex = 0;

    final tools = [
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'get_device_info',
          description: 'Retrieves the current device hardware info, battery level, and available storage space.',
          parameters: {
            'type': 'object',
            'properties': {},
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'search_files',
          description: 'Searches the entire local file system for files. Use this if you need to find a path for reading/deleting.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'Search keyword, filename, or extension (e.g. ".pdf")',
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
          description: 'Reads the full content of a file. Use this to find info inside files.',
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
          parameters: {
            'type': 'object',
            'properties': {},
          },
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
          name: 'open_play_store_updates',
          description: 'Open the Play Store "Updates" or "Manage apps" page where the user can see and install pending updates.',
          parameters: {
            'type': 'object',
            'properties': {},
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
          parameters: {
            'type': 'object',
            'properties': {},
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'download_file',
          description: 'Downloads a file or APK from a URL to the device Downloads folder.',
          parameters: {
            'type': 'object',
            'properties': {
              'url': {
                'type': 'string',
                'description': 'The direct URL of the file to download.',
              },
              'fileName': {
                'type': 'string',
                'description': 'The name to save the file as (e.g. "app.apk").',
              },
            },
            'required': ['url', 'fileName'],
          },
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
          parameters: {
            'type': 'object',
            'properties': {},
          },
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
          name: 'get_recent_screenshots',
          description: 'Retrieves paths to the most recent screenshots on the device.',
          parameters: {
            'type': 'object',
            'properties': {},
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'search_play_store',
          description: 'Searches for an app in the Play Store.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': { 'type': 'string', 'description': 'App name or search query' },
            },
            'required': ['query'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'open_web_url',
          description: 'Opens a website or deep link in the system browser.',
          parameters: {
            'type': 'object',
            'properties': {
              'url': { 'type': 'string', 'description': 'Full URL' },
            },
            'required': ['url'],
          },
        ),
      ),
      ChatCompletionTool(
        type: ChatCompletionToolType.function,
        function: FunctionObject(
          name: 'google_search',
          description: 'Searches the live web for information, news, or facts that are not on the device.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'The search query',
              },
            },
            'required': ['query'],
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
        // Token Optimization: Always keep system prompt + last 12 messages
        List<ChatCompletionMessage> windowMessages = [];
        if (_messages.isNotEmpty) {
          windowMessages.add(_messages.first); // Keep system prompt
          if (_messages.length > 13) {
            windowMessages.addAll(_messages.sublist(_messages.length - 12));
          } else if (_messages.length > 1) {
            windowMessages.addAll(_messages.sublist(1));
          }
        }

        final String currentModel = imagePath != null 
            ? _visionModels[visionModelIndex % _visionModels.length]
            : _textModels[textModelIndex % _textModels.length];

        final request = CreateChatCompletionRequest(
          model: ChatCompletionModel.modelId(currentModel),
          messages: windowMessages,
          tools: tools,
          toolChoice: ChatCompletionToolChoiceOption.mode(ChatCompletionToolChoiceMode.auto),
        );

        _statusController.add('Agent is thinking...');

        var response = await _client.createChatCompletion(request: request);
        if (response.choices.isEmpty) {
          return AgentResponse('The AI provider returned an empty response. This might be due to safety filters or a connection glitch.', 'error', retryCount);
        }
        var choice = response.choices.first;
        var message = choice.message;

        _messages.add(ChatCompletionMessage.assistant(
          content: message.content,
          toolCalls: message.toolCalls,
        ));

        // Agent Loop for tool calling
        while (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
          final List<ChatCompletionMessage> toolOutputs = [];
          for (final toolCall in message.toolCalls!) {
            if (toolCall is ChatCompletionMessageToolCall) {
              _statusController.add('Agent is ${toolCall.function.name.replaceAll('_', ' ')}...');
              final result = await _executeTool(
                toolCall.function.name,
                toolCall.function.arguments,
              );
              toolOutputs.add(ChatCompletionMessage.tool(
                toolCallId: toolCall.id,
                content: jsonEncode(result),
              ));
            }
          }
          _messages.addAll(toolOutputs);

          final String loopModel = imagePath != null 
              ? _visionModels[visionModelIndex % _visionModels.length]
              : _textModels[textModelIndex % _textModels.length];

          // Use windowed history in the tool loop too
          List<ChatCompletionMessage> loopWindow = [];
          if (_messages.isNotEmpty) {
            loopWindow.add(_messages.first);
            if (_messages.length > 13) {
              loopWindow.addAll(_messages.sublist(_messages.length - 12));
            } else if (_messages.length > 1) {
              loopWindow.addAll(_messages.sublist(1));
            }
          }

          final nextRequest = CreateChatCompletionRequest(
            model: ChatCompletionModel.modelId(loopModel),
            messages: loopWindow,
            tools: tools,
          );

          response = await _client.createChatCompletion(request: nextRequest);
          if (response.choices.isEmpty) {
            _statusController.add('');
            return AgentResponse('The AI provider returned an empty response during a tool loop.', 'error', retryCount);
          }
          choice = response.choices.first;
          message = choice.message;
          
          _messages.add(ChatCompletionMessage.assistant(
            content: message.content,
            toolCalls: message.toolCalls,
          ));
        }

        _statusController.add(''); // Clear status
        String assistantText = message.content ?? '';
        
        // Gemma/Llama Filter: Strip internal thinking/reasoning
        if (assistantText.contains('<thought>')) {
          assistantText = assistantText.split('</thought>').last.trim();
        }
        if (assistantText.startsWith('The user is asking') || assistantText.contains('\nI should use the')) {
          // Find the actual final answer or the last paragraph
          final lines = assistantText.split('\n');
          if (lines.length > 1) {
            assistantText = lines.last.trim();
            if (assistantText.isEmpty && lines.length > 2) {
              assistantText = lines[lines.length - 2].trim();
            }
          }
        }

        await _dbService.saveMessage('assistant', assistantText, sessionId);
        final activeModel = imagePath != null 
              ? _visionModels[visionModelIndex % _visionModels.length]
              : _textModels[textModelIndex % _textModels.length];
        return AgentResponse(assistantText, activeModel, retryCount);
      } catch (e) {
        _statusController.add(''); // Clear status
        if (e.toString().contains('503') || e.toString().contains('429') || e.toString().contains('400')) {
          retryCount++;
          if (imagePath != null) {
            visionModelIndex++;
          } else {
            textModelIndex++;
          }
          final nextModel = imagePath != null 
              ? _visionModels[visionModelIndex % _visionModels.length]
              : _textModels[textModelIndex % _textModels.length];
          
          _statusController.add('Rate limited. Retrying...');
          await Future.delayed(Duration(seconds: 2 * retryCount));
          continue;
        }
        if (e.toString().contains('Failed to call a function')) {
          return AgentResponse('I encountered a slight technical glitch while trying to use my tools. Could you try rephrasing your request?', 'error', retryCount);
        }
        return AgentResponse('Error: $e', 'error', retryCount);
      }
    }
    return AgentResponse('🚨 AI Service Limit Reached. Please wait a few minutes before trying again.', 'error', retryCount);
  }

  Future<AgentResponse> _sendGeminiMessage(String text, int sessionId, {String? imagePath}) async {
    int retryCount = 0;
    const int maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final List<gemini.DataPart> imageParts = [];
        if (imagePath != null) {
          final bytes = await File(imagePath).readAsBytes();
          imageParts.add(gemini.DataPart('image/jpeg', bytes));
        }

        final content = gemini.Content.multi([
          gemini.TextPart(text),
          ...imageParts,
        ]);

        final currentModel = _geminiModels[_geminiModelIndex % _geminiModels.length];
        _statusController.add('Agent is thinking...');
        
        _geminiChat ??= _geminiModel!.startChat();

        final response = await _geminiChat!.sendMessage(content);

        if (response.candidates.isEmpty) {
          return AgentResponse('The AI returned no response candidates. This usually means the content was blocked by safety filters.', 'error', retryCount);
        }

        String? assistantText = response.text;
        
        var currentResponse = response;
        while (currentResponse.functionCalls.isNotEmpty) {
          final List<gemini.FunctionResponse> toolResponses = [];
          
          for (final call in currentResponse.functionCalls) {
            _statusController.add('Agent is ${call.name.replaceAll('_', ' ')}...');
            final result = await _executeTool(call.name, jsonEncode(call.args));
            toolResponses.add(gemini.FunctionResponse(call.name, result));
          }

          currentResponse = await _geminiChat!.sendMessage(
            gemini.Content.functionResponses(toolResponses),
          );
          
          if (currentResponse.text != null) {
            assistantText = (assistantText ?? '') + (currentResponse.text!);
          }
        }

        _statusController.add('');
        String finalResponse = assistantText ?? 'I have processed your request.';
        
        // Filter out "Thinking/Reasoning" steps if they are present in the output
        if (finalResponse.contains('<thought>')) {
          finalResponse = finalResponse.split('</thought>').last.trim();
        }
        if (finalResponse.contains('The user wants') || 
            finalResponse.contains('The user is asking') ||
            finalResponse.contains('I should look through') ||
            finalResponse.contains('I will now provide')) {
          // Attempt to extract the actual answer after the reasoning
          final lastSentenceIndex = finalResponse.lastIndexOf('. ');
          if (lastSentenceIndex != -1 && lastSentenceIndex < finalResponse.length - 2) {
             finalResponse = finalResponse.substring(lastSentenceIndex + 2);
          }
        }

        await _dbService.saveMessage('assistant', finalResponse, sessionId);
        return AgentResponse(
          finalResponse, 
          _geminiModels[_geminiModelIndex % _geminiModels.length],
          retryCount,
        );

      } catch (e) {
        _statusController.add('');
        final errorStr = e.toString().toLowerCase();
        if (errorStr.contains('503') || 
            errorStr.contains('429') || 
            errorStr.contains('quota') || 
            errorStr.contains('limit') || 
            errorStr.contains('not found')) {
          retryCount++;
          if (_geminiModels.length > 1) {
            _geminiModelIndex++;
            final nextModel = _geminiModels[_geminiModelIndex % _geminiModels.length];
            _statusController.add('Model unavailable. Switching...');
            
            _geminiModel = gemini.GenerativeModel(
              model: nextModel,
              apiKey: _activeApiKey!,
              systemInstruction: gemini.Content.system(_getSystemPrompt()),
              tools: [_getGeminiTools()],
            );
            _geminiChat = _geminiModel!.startChat();
          } else {
            _statusController.add('Service busy. Retrying in ${2 * retryCount}s...');
          }
          
          await Future.delayed(Duration(seconds: 2 * retryCount));
          continue;
        }
        final errorMsg = 'Service Error: $e';
        await _dbService.saveMessage('assistant', errorMsg, sessionId);
        return AgentResponse(errorMsg, 'error', retryCount);
      }
    }
    const finalError = '🚨 AI Service is currently unavailable. Please try again later.';
    await _dbService.saveMessage('assistant', finalError, sessionId);
    return AgentResponse(finalError, 'error', retryCount);
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
        case 'search_play_store':
          final query = args['query'] as String? ?? '';
          _updateStatus('Searching Play Store for "$query"...');
          final searchRes = await _appService.searchPlayStore(query);
          return {'success': searchRes, 'query': query};
        case 'open_web_url':
          final url = args['url'] as String? ?? '';
          _updateStatus('Opening "$url"...');
          final openRes = await _utilityService.openUrl(url);
          return {'success': openRes, 'url': url};
        case 'google_search':
          final query = args['query'] as String? ?? '';
          _updateStatus('Searching the web for "$query"...');
          return await _searchService.searchWeb(query);
        case 'open_play_store_updates':
          _updateStatus('Opening Play Store updates...');
          final updatesRes = await _appService.openPlayStoreUpdates();
          return {'success': updatesRes, 'message': updatesRes ? 'Opened Play Store updates page' : 'Failed to open Play Store updates'};
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
        case 'download_file':
          final url = args['url'] as String? ?? '';
          final name = args['fileName'] as String? ?? 'downloaded_file';
          final result = await _fileService.downloadFile(url, name);
          return {'result': result};
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
        case 'get_recent_screenshots':
          final screenshots = await _dbService.searchFiles('screenshot');
          // Sort by modified date if available
          screenshots.sort((a, b) => (b['modified_date'] as String).compareTo(a['modified_date'] as String));
          return {'screenshots': screenshots.take(5).toList()};
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
