import 'package:shared_preferences/shared_preferences.dart';

import '../agent_mode.dart';

/// Where inference happens, and with whose credentials.
///
/// The product is API-first now: a user can start chatting in seconds with the
/// bundled demo key or their own, and the on-device model remains a deliberate
/// privacy choice rather than the default.
enum LlmProvider { local, gemini, groq, deepseek, openrouter, custom }

class LlmProviderSpec {
  final LlmProvider provider;
  final String label;
  final String tagline;

  /// OpenAI-compatible base URL (empty for Gemini/local).
  final String baseUrl;
  final String defaultModel;

  /// Tried in order when the primary model is unavailable for this key/tier
  /// (Groq answers 403 with an empty body for models the account may not use)
  /// or is rate-limited.
  final List<String> fallbackModels;

  final String consoleUrl;
  final String keyHint;

  /// Gemini and local use their own transports; the rest are OpenAI-compatible.
  final bool openAiCompatible;

  const LlmProviderSpec({
    required this.provider,
    required this.label,
    required this.tagline,
    required this.baseUrl,
    required this.defaultModel,
    required this.consoleUrl,
    required this.keyHint,
    required this.openAiCompatible,
    this.fallbackModels = const [],
  });
}

const Map<LlmProvider, LlmProviderSpec> kProviderSpecs = {
  LlmProvider.groq: LlmProviderSpec(
    provider: LlmProvider.groq,
    label: 'Groq',
    tagline: 'Fastest hosted inference. Great at tool calls.',
    baseUrl: 'https://api.groq.com/openai/v1',
    // Verified against a live free-tier key: the Llama models commonly cited in
    // tutorials are NOT available there (403), while gpt-oss-20b calls tools
    // reliably and is ~4x faster with reasoning_effort=low.
    defaultModel: 'openai/gpt-oss-20b',
    fallbackModels: ['openai/gpt-oss-120b', 'qwen/qwen3.8-27b'],
    consoleUrl: 'https://console.groq.com/keys',
    keyHint: 'gsk_…',
    openAiCompatible: true,
  ),
  LlmProvider.openrouter: LlmProviderSpec(
    provider: LlmProvider.openrouter,
    label: 'OpenRouter',
    tagline: 'DeepSeek 4.1 Flash — fast, strong at tool calls.',
    baseUrl: 'https://openrouter.ai/api/v1',
    // Verified live: this id exists on OpenRouter and returns a native tool
    // call in ~1.5 s. `openrouter/free` is a working fallback when the primary
    // is rate-limited or unavailable on the account.
    defaultModel: 'deepseek/deepseek-v4.1-flash',
    fallbackModels: [
      'openrouter/free',
      'deepseek/deepseek-v4-flash',
    ],
    consoleUrl: 'https://openrouter.ai/keys',
    keyHint: 'sk-or-v1-…',
    openAiCompatible: true,
  ),
  LlmProvider.deepseek: LlmProviderSpec(
    provider: LlmProvider.deepseek,
    label: 'DeepSeek',
    tagline: 'Strong reasoning, cheap. Good tool calls.',
    baseUrl: 'https://api.deepseek.com/v1',
    // DeepSeek's public model ids are `deepseek-chat` (V3.x) and
    // `deepseek-reasoner` (R1). There is no "4.x flash"; the model field is
    // editable, and an unknown id falls back to the model that actually works.
    defaultModel: 'deepseek-chat',
    fallbackModels: ['deepseek-chat'],
    consoleUrl: 'https://platform.deepseek.com/api_keys',
    keyHint: 'sk-…',
    openAiCompatible: true,
  ),
  LlmProvider.gemini: LlmProviderSpec(
    provider: LlmProvider.gemini,
    label: 'Google Gemini',
    tagline: 'Generous free tier. Native function calling.',
    baseUrl: '',
    defaultModel: 'gemini-2.5-flash',
    consoleUrl: 'https://aistudio.google.com/apikey',
    keyHint: 'AIza…',
    openAiCompatible: false,
  ),
  LlmProvider.custom: LlmProviderSpec(
    provider: LlmProvider.custom,
    label: 'Custom endpoint',
    tagline: 'Any OpenAI-compatible server (OpenRouter, Ollama, vLLM).',
    baseUrl: '',
    defaultModel: 'gpt-4o-mini',
    consoleUrl: '',
    keyHint: 'API key',
    openAiCompatible: true,
  ),
};

/// Resolved, ready-to-use configuration for the selected provider.
class ProviderConfig {
  final LlmProvider provider;
  final String apiKey;
  final String baseUrl;
  final String model;

  /// Ordered alternates for [model]. Empty for providers with a single
  /// supported chat model.
  final List<String> fallbackModels;

  /// True when this request rides on the build-time demo key rather than a key
  /// the user supplied. Surfaced in the UI so nobody thinks a shared key is
  /// private.
  final bool isDemo;

  const ProviderConfig({
    required this.provider,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.fallbackModels = const [],
    this.isDemo = false,
  });

  /// The primary model followed by each unique alternate.
  List<String> get modelChain {
    final out = <String>[];
    for (final m in [model, ...fallbackModels]) {
      if (m.trim().isNotEmpty && !out.contains(m)) out.add(m);
    }
    return out.isEmpty ? [model] : out;
  }

  LlmProviderSpec get spec => kProviderSpecs[provider]!;

  String get label => spec.label;

  String get displayName => '$model · $label';
}

/// Persistence + credential resolution.
///
/// Keys live in SharedPreferences (same store the Gemini key already used).
/// See AUDIT.md: a production build should move them to the Android keystore
/// and, for the demo key, to a server-side proxy.
class ProviderStore {
  ProviderStore._();

  static const _kProvider = 'llm_provider_v2';
  static const _kKeyPrefix = 'llm_key_v2_';
  static const _kModelPrefix = 'llm_model_v2_';
  static const _kBasePrefix = 'llm_base_v2_';
  static const _kDemoDay = 'demo_key_day_v1';
  static const _kDemoUsed = 'demo_key_used_v1';

  /// Shared keys baked in at build time, one per provider:
  ///   --dart-define=OPENROUTER_FREE_KEY=sk-or-v1-...
  ///   --dart-define=GROQ_FREE_KEY=gsk_...
  ///   --dart-define=FREE_UNLIMITED=true
  ///
  /// These are *shared* keys, not secrets: anything in an APK can be extracted.
  /// With FREE_UNLIMITED the per-install daily quota is disabled, which is what
  /// "everyone gets the model free" means in practice — rotate the keys and put
  /// a proxy in front before this is public.
  static const String openRouterFreeKey =
      String.fromEnvironment('OPENROUTER_FREE_KEY');
  static const String groqFreeKey =
      String.fromEnvironment('GROQ_FREE_KEY');
  static const String legacyGroqDemoKey =
      String.fromEnvironment('GROQ_DEMO_KEY');
  static const bool freeUnlimited =
      bool.fromEnvironment('FREE_UNLIMITED', defaultValue: false);

  static const String demoGroqModel = String.fromEnvironment(
    'GROQ_DEMO_MODEL',
    defaultValue: 'openai/gpt-oss-20b',
  );

  /// Requests per install per day on a shared key, unless unlimited.
  static const int demoDailyLimit = 25;

  /// The shared key for [provider], empty when none is compiled in.
  static String freeKeyFor(LlmProvider provider) {
    switch (provider) {
      case LlmProvider.openrouter:
        return openRouterFreeKey.trim();
      case LlmProvider.groq:
        return groqFreeKey.trim().isNotEmpty
            ? groqFreeKey.trim()
            : legacyGroqDemoKey.trim();
      default:
        return '';
    }
  }

  static bool get hasDemoKey => freeKeyFor(LlmProvider.openrouter).isNotEmpty ||
      freeKeyFor(LlmProvider.groq).isNotEmpty;

  /// The provider that "Start free" should use: DeepSeek 4.1 Flash via
  /// OpenRouter when available, otherwise Groq.
  static LlmProvider get freeProvider =>
      freeKeyFor(LlmProvider.openrouter).isNotEmpty
          ? LlmProvider.openrouter
          : LlmProvider.groq;

  static Future<LlmProvider> readProvider() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProvider);
      if (raw != null) {
        for (final p in LlmProvider.values) {
          if (p.name == raw) return p;
        }
      }
      // Migration: installs from before the provider layer only had
      // local/cloud; if cloud was selected, assume Gemini.
      final legacy = await AgentModeStore.read();
      if (legacy == AgentMode.cloud) return LlmProvider.gemini;
    } catch (_) {}
    return LlmProvider.local;
  }

  static Future<void> writeProvider(LlmProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProvider, provider.name);
    // Keep the legacy flag in sync so boot/routing code that still reads it
    // behaves consistently.
    await AgentModeStore.write(
      provider == LlmProvider.local ? AgentMode.local : AgentMode.cloud,
    );
  }

  static Future<String?> readKey(LlmProvider provider) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final direct = prefs.getString('$_kKeyPrefix${provider.name}')?.trim();
      if (direct != null && direct.isNotEmpty) return direct;
      if (provider == LlmProvider.gemini) {
        // Reuse the key the original Gemini screen stored.
        final legacy = await AgentModeStore.readApiKey();
        if (legacy != null && legacy.isNotEmpty) return legacy;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> writeKey(LlmProvider provider, String? key) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key?.trim() ?? '';
    if (trimmed.isEmpty) {
      await prefs.remove('$_kKeyPrefix${provider.name}');
      if (provider == LlmProvider.gemini) await AgentModeStore.clearApiKey();
    } else {
      await prefs.setString('$_kKeyPrefix${provider.name}', trimmed);
      if (provider == LlmProvider.gemini) {
        await AgentModeStore.writeApiKey(trimmed);
      }
    }
  }

  static Future<String> readModel(LlmProvider provider) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('$_kModelPrefix${provider.name}')?.trim();
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return kProviderSpecs[provider]?.defaultModel ?? '';
  }

  static Future<void> writeModel(LlmProvider provider, String? model) async {
    final prefs = await SharedPreferences.getInstance();
    final v = model?.trim() ?? '';
    if (v.isEmpty) {
      await prefs.remove('$_kModelPrefix${provider.name}');
    } else {
      await prefs.setString('$_kModelPrefix${provider.name}', v);
    }
  }

  static Future<String?> readBaseUrl(LlmProvider provider) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_kBasePrefix${provider.name}')?.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeBaseUrl(LlmProvider provider, String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final v = url?.trim() ?? '';
    if (v.isEmpty) {
      await prefs.remove('$_kBasePrefix${provider.name}');
    } else {
      await prefs.setString('$_kBasePrefix${provider.name}', v);
    }
  }

  /// True when the provider can be used right now (user key or shared key).
  static Future<bool> hasCredential(LlmProvider provider) async {
    if (provider == LlmProvider.local) return false;
    final key = await readKey(provider);
    if (key != null && key.isNotEmpty) return true;
    return freeKeyFor(provider).isNotEmpty;
  }

  /// Providers other than [exclude] that already hold a usable credential.
  ///
  /// Used only as a last resort: if the selected provider's key is rejected
  /// outright, retrying on a provider the user has already configured beats
  /// showing a dead end.
  static Future<List<LlmProvider>> otherConfiguredProviders(
      LlmProvider exclude) async {
    const order = [
      LlmProvider.openrouter,
      LlmProvider.groq,
      LlmProvider.deepseek,
      LlmProvider.gemini,
      LlmProvider.custom,
    ];
    final out = <LlmProvider>[];
    for (final provider in order) {
      if (provider == exclude) continue;
      if (await hasCredential(provider)) out.add(provider);
    }
    return out;
  }

  /// Resolve everything a request needs. Falls back to the shared key for the
  /// provider when the user has not supplied one.
  static Future<ProviderConfig> resolve(LlmProvider provider) async {
    var key = await readKey(provider) ?? '';
    var demo = false;
    if (key.isEmpty) {
      final shared = freeKeyFor(provider);
      if (shared.isNotEmpty) {
        key = shared;
        demo = true;
      }
    }
    final customModel = await _hasCustomModel(provider);
    final spec = kProviderSpecs[provider];
    var model = customModel
        ? await readModel(provider)
        : (spec?.defaultModel ?? '');
    if (!customModel && demo && provider == LlmProvider.groq) {
      model = demoGroqModel;
    }
    final base = (await readBaseUrl(provider)) ?? (spec?.baseUrl ?? '');
    return ProviderConfig(
      provider: provider,
      apiKey: key,
      baseUrl: base,
      model: model.isEmpty ? (spec?.defaultModel ?? '') : model,
      fallbackModels: spec?.fallbackModels ?? const [],
      isDemo: demo,
    );
  }

  static Future<bool> _hasCustomModel(LlmProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('$_kModelPrefix${provider.name}')?.trim();
    return v != null && v.isNotEmpty;
  }

  // ── Shared-key quota ────────────────────────────────────────────────────

  /// Remaining shared-key messages today, or -1 when unlimited.
  static Future<int> demoRemainingToday() async {
    if (!hasDemoKey) return 0;
    if (freeUnlimited) return -1;
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _dayKey();
      if (prefs.getString(_kDemoDay) != today) return demoDailyLimit;
      final used = prefs.getInt(_kDemoUsed) ?? 0;
      return (demoDailyLimit - used).clamp(0, demoDailyLimit);
    } catch (_) {
      return 0;
    }
  }

  /// Consume one shared-key request. Returns false only when a quota is
  /// enforced and exhausted.
  static Future<bool> consumeDemoUse() async {
    if (!hasDemoKey) return false;
    if (freeUnlimited) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _dayKey();
      var used = 0;
      if (prefs.getString(_kDemoDay) == today) {
        used = prefs.getInt(_kDemoUsed) ?? 0;
      } else {
        await prefs.setString(_kDemoDay, today);
      }
      if (used >= demoDailyLimit) return false;
      await prefs.setInt(_kDemoUsed, used + 1);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _dayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }
}
