import 'anthropic_client.dart';
import 'gemini_client.dart';
import 'http_stream.dart';
import 'llm_types.dart';
import 'openai_client.dart';

enum ProviderKind { hosted, gemini, openai, anthropic, groq, openrouter, custom }

/// The developer-run proxy behind "Free cloud" (see proxy/README.md). Set at
/// build time: flutter build appbundle --dart-define=HOSTED_API_URL=https://…
/// Without it the option doesn't appear.
const String kHostedApiUrl = String.fromEnvironment('HOSTED_API_URL');

/// Identifies this app to the proxy. Not a secret (anything in an APK can
/// be extracted); the proxy's per-install rate limits are the protection.
const String kHostedAppToken = String.fromEnvironment('HOSTED_APP_TOKEN', defaultValue: 'local-agent-app');

bool get hostedCloudAvailable => kHostedApiUrl.isNotEmpty;

/// Free cloud: Gemini through the developer's proxy, so users need no key.
const ProviderPreset kHostedPreset = ProviderPreset(
  kind: ProviderKind.hosted,
  id: 'hosted',
  name: 'Free cloud',
  shortName: 'Free cloud',
  tagline: 'No key needed. Runs on Google Gemini with fair-use limits.',
  baseUrl: kHostedApiUrl,
  keyUrl: '',
  keyHint: '',
  keyRequired: false,
  preferredModels: ['gemini-flash-lite-latest', 'gemini-flash-latest'],
);

/// Providers to show, with Free cloud first when this build has it.
List<ProviderPreset> get availableProviders => [if (hostedCloudAvailable) kHostedPreset, ...kProviders];

/// Static description of a cloud provider the user can bring a key for.
class ProviderPreset {
  final ProviderKind kind;
  final String id;
  final String name;
  final String shortName;
  final String tagline;
  final String baseUrl;

  /// Where the user creates a key. Empty for [ProviderKind.custom].
  final String keyUrl;
  final String keyHint;
  final bool keyRequired;

  /// Tried in order against the key's model list; the first match becomes
  /// the default. Model names churn, so this is a preference list rather
  /// than a hard-coded model — whatever the key can actually use wins.
  final List<String> preferredModels;

  const ProviderPreset({
    required this.kind,
    required this.id,
    required this.name,
    required this.shortName,
    required this.tagline,
    required this.baseUrl,
    required this.keyUrl,
    required this.keyHint,
    this.keyRequired = true,
    this.preferredModels = const [],
  });
}

const List<ProviderPreset> kProviders = [
  ProviderPreset(
    kind: ProviderKind.gemini,
    id: 'gemini',
    name: 'Google Gemini',
    shortName: 'Gemini',
    tagline: 'Free tier on most accounts. Recommended.',
    baseUrl: GeminiClient.defaultBaseUrl,
    keyUrl: 'https://aistudio.google.com/apikey',
    keyHint: 'AIza…',
    // `-latest` aliases are hot-swapped by Google on every release, so the
    // app keeps working when individual model versions are retired (the
    // hard-coded gemini-2.5-flash is what broke the old build).
    preferredModels: [
      'gemini-flash-latest',
      'gemini-flash-lite-latest',
      'gemini-3.8-flash',
      'gemini-3.5-flash-lite',
    ],
  ),
  ProviderPreset(
    kind: ProviderKind.anthropic,
    id: 'anthropic',
    name: 'Anthropic Claude',
    shortName: 'Claude',
    tagline: 'Strong at multi-step tool use. Paid.',
    baseUrl: AnthropicClient.defaultBaseUrl,
    keyUrl: 'https://platform.claude.com/settings/keys',
    keyHint: 'sk-ant-…',
    preferredModels: ['claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5'],
  ),
  ProviderPreset(
    kind: ProviderKind.openai,
    id: 'openai',
    name: 'OpenAI',
    shortName: 'OpenAI',
    tagline: 'GPT models. Paid.',
    baseUrl: 'https://api.openai.com/v1',
    keyUrl: 'https://platform.openai.com/api-keys',
    keyHint: 'sk-…',
    preferredModels: ['gpt-5-mini', 'gpt-4.1-mini', 'gpt-4o-mini'],
  ),
  ProviderPreset(
    kind: ProviderKind.groq,
    id: 'groq',
    name: 'Groq',
    shortName: 'Groq',
    tagline: 'Very fast open models. Free tier.',
    baseUrl: 'https://api.groq.com/openai/v1',
    keyUrl: 'https://console.groq.com/keys',
    keyHint: 'gsk_…',
    preferredModels: ['openai/gpt-oss-120b', 'llama-3.3-70b-versatile'],
  ),
  ProviderPreset(
    kind: ProviderKind.openrouter,
    id: 'openrouter',
    name: 'OpenRouter',
    shortName: 'OpenRouter',
    tagline: 'Hundreds of models behind one key.',
    baseUrl: 'https://openrouter.ai/api/v1',
    keyUrl: 'https://openrouter.ai/keys',
    keyHint: 'sk-or-…',
    preferredModels: ['openrouter/auto', 'google/gemini-3.5-flash-lite'],
  ),
  ProviderPreset(
    kind: ProviderKind.custom,
    id: 'custom',
    name: 'Custom server',
    shortName: 'Custom',
    tagline: 'Ollama, LM Studio, vLLM or any OpenAI-compatible URL.',
    baseUrl: '',
    keyUrl: '',
    keyHint: 'Optional',
    keyRequired: false,
  ),
];

ProviderPreset providerById(String id) => id == kHostedPreset.id
    ? kHostedPreset
    : kProviders.firstWhere((p) => p.id == id, orElse: () => kProviders.first);

/// The user's saved cloud choice (never contains the key — keys live in
/// secure storage, see [KeyStore]).
class CloudConfig {
  final String providerId;
  final String model;

  /// Only used for [ProviderKind.custom].
  final String? baseUrl;

  /// Capabilities captured from the provider's model list when the model was
  /// picked. Null when unknown (e.g. a model id typed by hand).
  final bool? supportsImages;
  final bool? supportsEffort;
  final int? maxOutputTokens;

  const CloudConfig({
    required this.providerId,
    required this.model,
    this.baseUrl,
    this.supportsImages,
    this.supportsEffort,
    this.maxOutputTokens,
  });

  ProviderPreset get preset => providerById(providerId);

  String get label => '${preset.shortName} · $model';

  String get effectiveBaseUrl =>
      preset.kind == ProviderKind.custom ? (baseUrl ?? '') : preset.baseUrl;

  CloudConfig copyWith({String? model, String? baseUrl}) => CloudConfig(
        providerId: providerId,
        model: model ?? this.model,
        baseUrl: baseUrl ?? this.baseUrl,
        supportsImages: supportsImages,
        supportsEffort: supportsEffort,
        maxOutputTokens: maxOutputTokens,
      );

  Map<String, dynamic> toJson() => {
        'provider': providerId,
        'model': model,
        if (baseUrl != null) 'baseUrl': baseUrl,
        if (supportsImages != null) 'images': supportsImages,
        if (supportsEffort != null) 'effort': supportsEffort,
        if (maxOutputTokens != null) 'maxOut': maxOutputTokens,
      };

  static CloudConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final provider = json['provider'] as String?;
    final model = json['model'] as String?;
    if (provider == null || model == null || model.isEmpty) return null;
    return CloudConfig(
      providerId: provider,
      model: model,
      baseUrl: json['baseUrl'] as String?,
      supportsImages: json['images'] as bool?,
      supportsEffort: json['effort'] as bool?,
      maxOutputTokens: (json['maxOut'] as num?)?.toInt(),
    );
  }
}

/// Builds the right client for a provider. [model] is used to look up
/// Claude capabilities; pass null when only listing models.
LlmClient createLlmClient({
  required ProviderPreset preset,
  required String apiKey,
  String? baseUrl,
  CloudConfig? config,
  String? installId,
  HttpClientFactory? httpClientFactory,
}) {
  switch (preset.kind) {
    case ProviderKind.hosted:
      // The proxy speaks the Gemini API and swaps in the real key.
      return GeminiClient(
        apiKey: kHostedAppToken,
        baseUrl: '${preset.baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1beta',
        extraHeaders: {if (installId != null) 'x-install-id': installId},
        httpClientFactory: httpClientFactory,
      );
    case ProviderKind.gemini:
      return GeminiClient(apiKey: apiKey, httpClientFactory: httpClientFactory);
    case ProviderKind.anthropic:
      return AnthropicClient(
        apiKey: apiKey,
        supportsEffort: config?.supportsEffort,
        modelMaxOutputTokens: config?.maxOutputTokens,
        httpClientFactory: httpClientFactory,
      );
    case ProviderKind.openai:
      return OpenAiCompatClient(
        providerId: preset.id,
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        isOfficialOpenAi: true,
        httpClientFactory: httpClientFactory,
      );
    case ProviderKind.groq:
      return OpenAiCompatClient(
        providerId: preset.id,
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        httpClientFactory: httpClientFactory,
      );
    case ProviderKind.openrouter:
      return OpenAiCompatClient(
        providerId: preset.id,
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        // Optional attribution headers OpenRouter recommends.
        extraHeaders: const {
          'x-title': 'Local Agent',
          'http-referer': 'https://github.com/shantoshdurai/Phone-Local-Agent',
        },
        httpClientFactory: httpClientFactory,
      );
    case ProviderKind.custom:
      return OpenAiCompatClient(
        providerId: preset.id,
        baseUrl: baseUrl ?? config?.baseUrl ?? '',
        apiKey: apiKey,
        httpClientFactory: httpClientFactory,
      );
  }
}

/// Picks the default model for [preset] from what the key can access.
String? pickDefaultModel(ProviderPreset preset, List<LlmModelInfo> models) {
  if (models.isEmpty) {
    return preset.preferredModels.isEmpty ? null : preset.preferredModels.first;
  }
  final ids = models.map((m) => m.id).toSet();
  for (final wanted in preset.preferredModels) {
    if (ids.contains(wanted)) return wanted;
  }
  // Gemini's list doesn't always include the `-latest` aliases even though
  // the API serves them.
  if (preset.kind == ProviderKind.gemini &&
      preset.preferredModels.isNotEmpty) {
    return preset.preferredModels.first;
  }
  return models.first.id;
}

/// Ordered model list for the picker: preferred models first (including
/// aliases the API doesn't list), then everything else.
List<LlmModelInfo> orderModelsForPicker(
    ProviderPreset preset, List<LlmModelInfo> models) {
  final byId = {for (final m in models) m.id: m};
  final out = <LlmModelInfo>[];
  for (final id in preset.preferredModels) {
    final known = byId.remove(id);
    if (known != null) {
      out.add(known);
    } else if (preset.kind == ProviderKind.gemini && id.endsWith('-latest')) {
      out.add(LlmModelInfo(id: id, supportsImages: true));
    }
  }
  out.addAll(byId.values);
  return out;
}
