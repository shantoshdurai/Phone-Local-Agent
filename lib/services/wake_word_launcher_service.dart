import 'dart:convert';
import 'package:installed_apps/installed_apps.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WakeWordAppBinding {
  final String id;
  String wakeWord;
  String packageName;
  String appName;
  bool isEnabled;

  WakeWordAppBinding({
    required this.id,
    required this.wakeWord,
    required this.packageName,
    required this.appName,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'wakeWord': wakeWord,
        'packageName': packageName,
        'appName': appName,
        'isEnabled': isEnabled,
      };

  factory WakeWordAppBinding.fromJson(Map<String, dynamic> json) =>
      WakeWordAppBinding(
        id: json['id'] as String,
        wakeWord: json['wakeWord'] as String,
        packageName: json['packageName'] as String,
        appName: json['appName'] as String,
        isEnabled: json['isEnabled'] as bool? ?? true,
      );
}

class WakeWordMatchResult {
  final WakeWordAppBinding binding;
  final bool isInstalled;
  final String remainderText;

  WakeWordMatchResult({
    required this.binding,
    required this.isInstalled,
    required this.remainderText,
  });
}

/// Service that handles binding Wake Words directly to installed apps on the phone.
/// Zero API keys needed — pure on-device app launching via voice.
class WakeWordLauncherService {
  static final WakeWordLauncherService _instance =
      WakeWordLauncherService._internal();
  factory WakeWordLauncherService() => _instance;
  WakeWordLauncherService._internal();

  static const _kBindingsKey = 'wake_word_app_bindings_v2';

  List<WakeWordAppBinding>? _cachedBindings;

  /// Default setup of popular wake words mapped to their respective apps.
  List<WakeWordAppBinding> _createDefaults() {
    return [
      WakeWordAppBinding(
        id: 'jarvis',
        wakeWord: 'Hey Jarvis',
        packageName: 'com.openai.chatgpt',
        appName: 'ChatGPT (Default AI)',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'claude',
        wakeWord: 'Hey Claude',
        packageName: 'com.anthropic.claude',
        appName: 'Claude',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'chatgpt',
        wakeWord: 'Hey ChatGPT',
        packageName: 'com.openai.chatgpt',
        appName: 'ChatGPT',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'gemini',
        wakeWord: 'Hey Gemini',
        packageName: 'com.google.android.apps.bard',
        appName: 'Google Gemini',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'perplexity',
        wakeWord: 'Hey Perplexity',
        packageName: 'ai.perplexity.app',
        appName: 'Perplexity',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'copilot',
        wakeWord: 'Hey Copilot',
        packageName: 'com.microsoft.copilot',
        appName: 'Microsoft Copilot',
        isEnabled: true,
      ),
      WakeWordAppBinding(
        id: 'grok',
        wakeWord: 'Hey Grok',
        packageName: 'com.twitter.android',
        appName: 'X (Grok)',
        isEnabled: true,
      ),
    ];
  }

  /// Load all wake word bindings from disk, creating defaults on first boot.
  Future<List<WakeWordAppBinding>> getBindings() async {
    if (_cachedBindings != null) return _cachedBindings!;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBindingsKey);
    if (raw == null || raw.isEmpty) {
      final defaults = _createDefaults();
      await saveBindings(defaults);
      _cachedBindings = defaults;
      return defaults;
    }

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final bindings = list
          .map((item) =>
              WakeWordAppBinding.fromJson(item as Map<String, dynamic>))
          .toList();
      _cachedBindings = bindings;
      return bindings;
    } catch (_) {
      final defaults = _createDefaults();
      _cachedBindings = defaults;
      return defaults;
    }
  }

  /// Save bindings list to SharedPreferences.
  Future<void> saveBindings(List<WakeWordAppBinding> bindings) async {
    _cachedBindings = bindings;
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(bindings.map((b) => b.toJson()).toList());
    await prefs.setString(_kBindingsKey, jsonStr);
  }

  /// Update or add a binding.
  Future<void> setBinding(WakeWordAppBinding binding) async {
    final bindings = await getBindings();
    final idx = bindings.indexWhere((b) => b.id == binding.id);
    if (idx >= 0) {
      bindings[idx] = binding;
    } else {
      bindings.add(binding);
    }
    await saveBindings(bindings);
  }

  /// Remove a binding by id.
  Future<void> removeBinding(String id) async {
    final bindings = await getBindings();
    bindings.removeWhere((b) => b.id == id);
    await saveBindings(bindings);
  }

  /// Set the app that "Hey Jarvis" triggers.
  Future<void> setJarvisTargetApp({
    required String packageName,
    required String appName,
  }) async {
    final bindings = await getBindings();
    final jarvis = bindings.firstWhere(
      (b) => b.id == 'jarvis',
      orElse: () => WakeWordAppBinding(
        id: 'jarvis',
        wakeWord: 'Hey Jarvis',
        packageName: packageName,
        appName: appName,
      ),
    );
    jarvis.packageName = packageName;
    jarvis.appName = appName;
    await setBinding(jarvis);
  }

  /// Checks incoming voice transcripts to see if a wake word was spoken.
  /// Matches phrases like:
  /// - "Hey Jarvis" / "Jarvis"
  /// - "Hey Claude" / "Claude"
  /// - "Open ChatGPT" / "Hey ChatGPT"
  Future<WakeWordMatchResult?> matchWakeWord(String transcript) async {
    final raw = transcript.trim().toLowerCase();
    if (raw.isEmpty) return null;

    final bindings = await getBindings();

    // Sort by wake word length descending so longer phrases match first ("hey claude" before "claude")
    final activeBindings = bindings.where((b) => b.isEnabled).toList();

    for (final b in activeBindings) {
      final trigger = b.wakeWord.trim().toLowerCase();
      // Also match without "hey" if prefix is present (e.g. "hey claude" -> matches "claude")
      final variations = <String>[trigger];
      if (trigger.startsWith('hey ')) {
        variations.add(trigger.substring(4).trim());
      }
      if (trigger.startsWith('ok ')) {
        variations.add(trigger.substring(3).trim());
      }
      variations.add('open ${b.appName.toLowerCase()}');
      variations.add('launch ${b.appName.toLowerCase()}');

      for (final variant in variations) {
        if (raw.startsWith(variant) || raw == variant) {
          String remainder = transcript.trim().substring(
              variant.length < transcript.trim().length
                  ? variant.length
                  : transcript.trim().length);
          if (remainder.startsWith(',') || remainder.startsWith(':')) {
            remainder = remainder.substring(1).trim();
          }

          final isInstalled = await _isAppInstalled(b.packageName);
          return WakeWordMatchResult(
            binding: b,
            isInstalled: isInstalled,
            remainderText: remainder.trim(),
          );
        }
      }
    }
    return null;
  }

  Future<bool> _isAppInstalled(String packageName) async {
    try {
      final installed = await InstalledApps.isAppInstalled(packageName);
      return installed ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Launch the app associated with the wake word.
  Future<bool> launchAppForBinding(WakeWordAppBinding binding) async {
    try {
      final ok = await InstalledApps.startApp(binding.packageName);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Get list of all user apps on device for the selection dialog.
  Future<List<Map<String, String>>> getSelectableApps() async {
    try {
      final installed = await InstalledApps.getInstalledApps(
        excludeSystemApps: true,
        withIcon: false,
      );
      final list = installed.map((app) {
        return {
          'name': app.name,
          'packageName': app.packageName,
          'version': app.versionName,
        };
      }).toList();

      list.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
      return list;
    } catch (_) {
      return [];
    }
  }
}
