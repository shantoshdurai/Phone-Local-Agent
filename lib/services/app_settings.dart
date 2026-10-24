import 'package:shared_preferences/shared_preferences.dart';

/// Persisted agent settings.
///
/// The three switches in Settings used to live in `State` only: leaving the
/// screen reset them, and "Confirm before actions" — a safety control — was
/// wired to nothing at all. They now survive restarts and the confirm flag is
/// actually enforced by [ToolRuntime] before destructive tools run.
class AppSettings {
  AppSettings._();

  static const _kConfirm = 'settings_confirm_actions_v1';
  static const _kStream = 'settings_stream_tokens_v1';
  static const _kHistory = 'settings_save_history_v1';

  /// Cached copies so hot paths (tool dispatch) can read them synchronously.
  /// Defaults are the safe ones: confirm = true, streaming = true.
  static bool confirmBeforeActions = true;
  static bool streamTokens = true;
  static bool saveHistory = true;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      confirmBeforeActions = prefs.getBool(_kConfirm) ?? true;
      streamTokens = prefs.getBool(_kStream) ?? true;
      saveHistory = prefs.getBool(_kHistory) ?? true;
    } catch (_) {
      // Keep defaults.
    }
  }

  static Future<void> setConfirmBeforeActions(bool value) async {
    confirmBeforeActions = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kConfirm, value);
  }

  static Future<void> setStreamTokens(bool value) async {
    streamTokens = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kStream, value);
  }

  static Future<void> setSaveHistory(bool value) async {
    saveHistory = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHistory, value);
  }
}
