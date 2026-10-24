import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'agent_service.dart';
import 'ai_apps_service.dart';

enum AIProvider {
  gemini('Gemini', 'Google Gemini 2.5 Flash'),
  claude('Claude', 'Anthropic Claude 3.5'),
  chatgpt('ChatGPT', 'OpenAI GPT-4o'),
  grok('Grok', 'xAI Grok 2'),
  local('Local Agent', 'On-Device LiteRT');

  final String displayName;
  final String description;
  const AIProvider(this.displayName, this.description);
}

class WakeWordMatch {
  final AIProvider provider;
  final String cleanQuery;
  final String triggerWord;
  final bool matched;

  const WakeWordMatch({
    required this.provider,
    required this.cleanQuery,
    required this.triggerWord,
    required this.matched,
  });
}

/// Service that handles:
/// 1. Hardware Assistant triggers (Power button hold / Corner swipe) via Android MethodChannel.
/// 2. Multi-AI routing (Claude, Gemini, Grok, ChatGPT, Local Agent).
/// 3. Wake word parsing & dynamic dispatch.
class AssistantRouterService {
  static final AssistantRouterService _instance =
      AssistantRouterService._internal();
  factory AssistantRouterService() => _instance;
  AssistantRouterService._internal();

  static const MethodChannel _channel = MethodChannel('com.localagent/assistant');
  static const EventChannel _eventChannel =
      EventChannel('com.localagent/assistant_events');

  Stream<String> get assistantEvents =>
      _eventChannel.receiveBroadcastStream().map((e) => e.toString());

  // Preference keys
  static const _kCustomWakeWordKey = 'assistant_custom_wake_word';
  static const _kCustomTargetKey = 'assistant_custom_target';
  static const _kWakeWordEnabledKey = 'assistant_wake_words_enabled';
  static const _kClaudeKey = 'claude_api_key_v1';
  static const _kOpenAiKey = 'openai_api_key_v1';
  static const _kGrokKey = 'grok_api_key_v1';
  static const _kDefaultProviderKey = 'assistant_default_provider';

  /// Check if the app was launched via Android's Assistant trigger (Long-press Power button).
  Future<bool> wasLaunchedAsAssistant() async {
    try {
      final String? action = await _channel.invokeMethod<String>('getLaunchIntent');
      return action == 'assist' || action == 'voice_command';
    } catch (_) {
      return false;
    }
  }

  /// Open Android Default Apps Settings to allow the user to pick Local Agent as Digital Assistant.
  Future<bool> openAssistantSettings() async {
    try {
      final bool? success =
          await _channel.invokeMethod<bool>('openAssistantSettings');
      return success ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Check if Display Over Other Apps permission is granted.
  Future<bool> isOverlayPermissionGranted() async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('isOverlayGranted');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open Android settings to grant Display Over Other Apps.
  Future<bool> openOverlaySettings() async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('openOverlaySettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open Android settings to exclude app from aggressive battery killing.
  Future<bool> openBatteryOptimizationSettings() async {
    try {
      final bool? res = await _channel.invokeMethod<bool>('openBatterySettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  // --- API Key Management ---
  Future<String?> getClaudeKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kClaudeKey)?.trim();
  }

  Future<void> setClaudeKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kClaudeKey, key.trim());
  }

  Future<String?> getOpenAiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kOpenAiKey)?.trim();
  }

  Future<void> setOpenAiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kOpenAiKey, key.trim());
  }

  Future<String?> getGrokKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kGrokKey)?.trim();
  }

  Future<void> setGrokKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kGrokKey, key.trim());
  }

  // --- Wake Word Configuration ---
  Future<bool> areWakeWordsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWakeWordEnabledKey) ?? true;
  }

  Future<void> setWakeWordsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWakeWordEnabledKey, enabled);
  }

  Future<String> getCustomWakeWord() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kCustomWakeWordKey) ?? 'Jarvis';
  }

  Future<void> setCustomWakeWord(String word) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomWakeWordKey, word.trim());
  }

  Future<AIProvider> getCustomWakeWordTarget() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kCustomTargetKey);
    return AIProvider.values.firstWhere(
      (p) => p.name == name,
      orElse: () => AIProvider.claude,
    );
  }

  Future<void> setCustomWakeWordTarget(AIProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCustomTargetKey, provider.name);
  }

  Future<AIProvider> getDefaultProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kDefaultProviderKey);
    return AIProvider.values.firstWhere(
      (p) => p.name == name,
      orElse: () => AIProvider.gemini,
    );
  }

  Future<void> setDefaultProvider(AIProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDefaultProviderKey, provider.name);
  }

  /// Parses an incoming user transcript to detect wake words like:
  /// - "Hey Claude, what is quantum computing?"
  /// - "Grok, tell me about Mars"
  /// - "Hey Gemini, check my battery"
  /// - "ChatGPT, explain recursion"
  /// - Custom configured wake word (e.g. "Jarvis, summarize")
  Future<WakeWordMatch> parseWakeWord(String transcript) async {
    final raw = transcript.trim();
    final lower = raw.toLowerCase();

    final enabled = await areWakeWordsEnabled();
    final defaultProv = await getDefaultProvider();

    if (!enabled) {
      return WakeWordMatch(
        provider: defaultProv,
        cleanQuery: raw,
        triggerWord: '',
        matched: false,
      );
    }

    final customWord = (await getCustomWakeWord()).toLowerCase();
    final customTarget = await getCustomWakeWordTarget();

    // Map of trigger phrase -> AIProvider
    final triggers = <String, AIProvider>{
      'hey jarvis': customTarget,
      'jarvis': customTarget,
      'hey claude': AIProvider.claude,
      'claude': AIProvider.claude,
      'hey grok': AIProvider.grok,
      'grok': AIProvider.grok,
      'hey chatgpt': AIProvider.chatgpt,
      'chatgpt': AIProvider.chatgpt,
      'hey gpt': AIProvider.chatgpt,
      'hey gemini': AIProvider.gemini,
      'gemini': AIProvider.gemini,
      'hey agent': AIProvider.local,
      'local agent': AIProvider.local,
    };

    if (customWord.isNotEmpty) {
      triggers['hey $customWord'] = customTarget;
      triggers[customWord] = customTarget;
    }

    // Sort triggers by length descending to match longer phrases first ("hey claude" before "claude")
    final sortedKeys = triggers.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final trigger in sortedKeys) {
      if (lower.startsWith(trigger)) {
        String clean = raw.substring(trigger.length).trim();
        // Strip common leading punctuation like comma or colon
        if (clean.startsWith(',') || clean.startsWith(':')) {
          clean = clean.substring(1).trim();
        }
        return WakeWordMatch(
          provider: triggers[trigger]!,
          cleanQuery: clean.isEmpty ? raw : clean,
          triggerWord: trigger,
          matched: true,
        );
      }
    }

    // No wake word matched: route to current default
    return WakeWordMatch(
      provider: defaultProv,
      cleanQuery: raw,
      triggerWord: '',
      matched: false,
    );
  }

  /// Execute query across the specified AI provider or launch installed AI app
  Future<String> executeQuery({
    required AIProvider provider,
    required String prompt,
    required int sessionId,
  }) async {
    // 1. First check if prompt is an app launching command (e.g. "open claude", "launch chatgpt")
    final appMatch = AiAppsService().matchLaunchQuery(prompt);
    if (appMatch != null) {
      if (appMatch.isInstalled) {
        final launched = await AiAppsService().launchApp(appMatch.packageName);
        if (launched) {
          return "Opening ${appMatch.name}...";
        }
      } else {
        return "${appMatch.name} is not installed on this phone. You can install it from Google Play Store.";
      }
    }

    switch (provider) {
      case AIProvider.gemini:
      case AIProvider.local:
        // Use existing AgentService / GeminiService with full device tool capabilities
        final agent = AgentService();
        final response = await agent.sendMessage(prompt, sessionId);
        return response.text;

      case AIProvider.claude:
        return _queryClaude(prompt);

      case AIProvider.chatgpt:
        return _queryOpenAI(prompt);

      case AIProvider.grok:
        return _queryGrok(prompt);
    }
  }

  Future<String> _queryClaude(String prompt) async {
    final key = await getClaudeKey();
    if (key == null || key.isEmpty) {
      return "Claude API key not configured. Add it in Settings → Assistant & Wake Words.";
    }
    final uri = Uri.parse('https://api.anthropic.com/v1/messages');
    final res = await http.post(
      uri,
      headers: {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': 'claude-3-5-sonnet-20241022',
        'max_tokens': 1024,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );
    if (res.statusCode == 200) {
      final json = jsonDecode(res.body);
      final content = json['content'] as List<dynamic>?;
      if (content != null && content.isNotEmpty) {
        return content[0]['text'] as String? ?? 'No response';
      }
    }
    return "Claude Error (${res.statusCode}): ${res.body}";
  }

  Future<String> _queryOpenAI(String prompt) async {
    final key = await getOpenAiKey();
    if (key == null || key.isEmpty) {
      return "OpenAI API key not configured. Add it in Settings → Assistant & Wake Words.";
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final res = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );
    if (res.statusCode == 200) {
      final json = jsonDecode(res.body);
      final choices = json['choices'] as List<dynamic>?;
      if (choices != null && choices.isNotEmpty) {
        return choices[0]['message']['content'] as String? ?? 'No response';
      }
    }
    return "OpenAI Error (${res.statusCode}): ${res.body}";
  }

  Future<String> _queryGrok(String prompt) async {
    final key = await getGrokKey();
    if (key == null || key.isEmpty) {
      return "xAI Grok API key not configured. Add it in Settings → Assistant & Wake Words.";
    }
    final uri = Uri.parse('https://api.x.ai/v1/chat/completions');
    final res = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $key',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': 'grok-2-latest',
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );
    if (res.statusCode == 200) {
      final json = jsonDecode(res.body);
      final choices = json['choices'] as List<dynamic>?;
      if (choices != null && choices.isNotEmpty) {
        return choices[0]['message']['content'] as String? ?? 'No response';
      }
    }
    return "Grok Error (${res.statusCode}): ${res.body}";
  }
}
