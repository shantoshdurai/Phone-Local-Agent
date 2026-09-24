import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm/providers.dart';

/// Where the agent runs.
enum AgentMode { local, cloud }

/// App-wide preferences. Everything except API keys lives in
/// SharedPreferences; keys go to [KeyStore].
class AppSettings {
  AppSettings._();

  static const _kOnboardingSeen = 'onboarding_seen_v1';
  static const _kMode = 'agent_mode_v1';
  static const _kLastModel = 'last_used_model_file';
  static const _kCloudConfig = 'cloud_config_v2';
  static const _kConfirmActions = 'confirm_actions_v1';
  static const _kInstantCommands = 'instant_commands_v1';
  static const _kUseGpu = 'local_use_gpu_v1';

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  static Future<bool> onboardingSeen() async =>
      (await _prefs).getBool(_kOnboardingSeen) ?? false;

  static Future<void> setOnboardingSeen() async =>
      (await _prefs).setBool(_kOnboardingSeen, true);

  static Future<AgentMode?> mode() async {
    final raw = (await _prefs).getString(_kMode);
    if (raw == 'local') return AgentMode.local;
    if (raw == 'cloud') return AgentMode.cloud;
    return null;
  }

  static Future<void> setMode(AgentMode mode) async =>
      (await _prefs).setString(_kMode, mode.name);

  static Future<String?> lastLocalModel() async =>
      (await _prefs).getString(_kLastModel);

  static Future<void> setLastLocalModel(String? fileName) async {
    final prefs = await _prefs;
    if (fileName == null) {
      await prefs.remove(_kLastModel);
    } else {
      await prefs.setString(_kLastModel, fileName);
    }
  }

  static Future<CloudConfig?> cloudConfig() async {
    final raw = (await _prefs).getString(_kCloudConfig);
    if (raw == null) return null;
    try {
      return CloudConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setCloudConfig(CloudConfig config) async =>
      (await _prefs).setString(_kCloudConfig, jsonEncode(config.toJson()));

  /// Ask before actions that contact people or change data.
  static Future<bool> confirmActions() async =>
      (await _prefs).getBool(_kConfirmActions) ?? true;

  static Future<void> setConfirmActions(bool value) async =>
      (await _prefs).setBool(_kConfirmActions, value);

  /// Handle simple commands ("flashlight on", "timer 5 min") instantly
  /// without the language model.
  static Future<bool> instantCommands() async =>
      (await _prefs).getBool(_kInstantCommands) ?? true;

  static Future<void> setInstantCommands(bool value) async =>
      (await _prefs).setBool(_kInstantCommands, value);

  /// Run local models on the GPU instead of the CPU.
  static Future<bool> useGpu() async => (await _prefs).getBool(_kUseGpu) ?? false;

  static Future<void> setUseGpu(bool value) async =>
      (await _prefs).setBool(_kUseGpu, value);
}

/// API keys, encrypted at rest with an Android Keystore-backed key.
class KeyStore {
  KeyStore._();

  static const _storage = FlutterSecureStorage();
  static const _kLegacyGeminiKey = 'gemini_api_key_v1';

  static String _name(String providerId) => 'api_key_$providerId';

  static Future<String?> read(String providerId) async {
    try {
      final key = (await _storage.read(key: _name(providerId)))?.trim();
      return (key == null || key.isEmpty) ? null : key;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String providerId, String key) =>
      _storage.write(key: _name(providerId), value: key.trim());

  static Future<void> delete(String providerId) =>
      _storage.delete(key: _name(providerId));

  /// Earlier builds stored the Gemini key in plain SharedPreferences. Move it
  /// into secure storage once and scrub the plaintext copy.
  static Future<void> migrateLegacyKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_kLegacyGeminiKey)?.trim();
    if (legacy == null) return;
    try {
      if (legacy.isNotEmpty && await read('gemini') == null) {
        await write('gemini', legacy);
      }
      await prefs.remove(_kLegacyGeminiKey);
    } catch (_) {
      // Leave the legacy value in place; we'll retry next launch.
    }
  }
}
