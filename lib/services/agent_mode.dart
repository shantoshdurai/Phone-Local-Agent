import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the agent currently runs locally or talks to a cloud API.
/// Stored in SharedPreferences so the choice survives restarts.
enum AgentMode { local, cloud }

class AgentModeStore {
  AgentModeStore._();

  static const _kModeKey = 'agent_mode_v1';
  static const _kApiKeyKey = 'gemini_api_key_v1';

  static Future<AgentMode?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kModeKey);
    if (raw == 'local') return AgentMode.local;
    if (raw == 'cloud') return AgentMode.cloud;
    return null;
  }

  static Future<void> write(AgentMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModeKey, mode == AgentMode.local ? 'local' : 'cloud');
  }

  static Future<String?> readApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_kApiKeyKey)?.trim();
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> writeApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApiKeyKey, key.trim());
  }

  static Future<void> clearApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kApiKeyKey);
  }
}
