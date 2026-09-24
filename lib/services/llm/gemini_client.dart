import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_stream.dart';
import 'llm_types.dart';

/// Google Gemini via the `generateContent` REST API (no SDK).
///
/// Replaces the deprecated `google_generative_ai` package, which could not
/// parse Gemini 2.5+/3 responses (empty `content` on thinking models threw
/// "Unhandled format for Content") and dropped thought signatures that
/// Gemini 3 requires on function-call turns.
class GeminiClient implements LlmClient {
  static const String defaultBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// Older Gemini models don't return call ids; we mint local ones with this
  /// prefix and never send them back to the API.
  static const String syntheticIdPrefix = 'local-gemini-call-';

  final String apiKey;
  final String baseUrl;
  final Map<String, String> extraHeaders;
  final HttpClientFactory _httpFactory;

  /// Set once a model rejects `thinkingConfig`, so later turns skip it.
  bool _thinkingConfigRejected = false;

  GeminiClient({
    required this.apiKey,
    String? baseUrl,
    this.extraHeaders = const {},
    HttpClientFactory? httpClientFactory,
  })  : baseUrl = _trimSlash(baseUrl ?? defaultBaseUrl),
        _httpFactory = httpClientFactory ?? defaultHttpClientFactory;

  @override
  String get providerId => 'gemini';

  @override
  Stream<LlmEvent> stream(LlmRequest request, {CancelToken? cancel}) {
    return withRetries(
      () => _streamOnce(request, cancel),
      cancel: cancel,
    );
  }

  Stream<LlmEvent> _streamOnce(LlmRequest request, CancelToken? cancel) async* {
    final useThinking =
        !_thinkingConfigRejected && _supportsThinkingLevel(request.model);
    OpenStream open;
    try {
      open = await _open(request, cancel, includeThinking: useThinking);
    } on LlmException catch (e) {
      // Older/non-thinking models 400 on thinkingConfig. Retry once without
      // it instead of failing the user's message.
      if (useThinking &&
          e.kind == LlmErrorKind.invalidRequest &&
          e.message.toLowerCase().contains('think')) {
        _thinkingConfigRejected = true;
        open = await _open(request, cancel, includeThinking: false);
      } else {
        rethrow;
      }
    }

    final rawParts = <Map<String, dynamic>>[];
    final text = StringBuffer();
    final calls = <LlmToolCall>[];
    String? finishReason;
    String? blockReason;
    int? outputTokens;

    try {
      await for (final event in parseSse(open.bytes())) {
        final json = decodeEventJson(event.data);
        final error = json['error'];
        if (error is Map) {
          throw _errorFromJson(
              (error['code'] as num?)?.toInt() ?? 500, error, const {});
        }
        final feedback = json['promptFeedback'];
        if (feedback is Map && feedback['blockReason'] != null) {
          blockReason = '${feedback['blockReason']}';
        }
        final usage = json['usageMetadata'];
        if (usage is Map && usage['candidatesTokenCount'] is num) {
          outputTokens = (usage['candidatesTokenCount'] as num).toInt();
        }
        final candidates = json['candidates'];
        if (candidates is! List || candidates.isEmpty) continue;
        final candidate = candidates.first as Map;
        final content = candidate['content'];
        final parts = content is Map ? content['parts'] : null;
        if (parts is List) {
          for (final p in parts) {
            if (p is! Map) continue;
            final part = Map<String, dynamic>.from(p);
            rawParts.add(part);
            if (part['thought'] == true) continue;
            final t = part['text'];
            if (t is String && t.isNotEmpty) {
              text.write(t);
              yield LlmTextDelta(t);
            }
            final fc = part['functionCall'];
            if (fc is Map) {
              final args = fc['args'];
              calls.add(LlmToolCall(
                id: (fc['id'] as String?) ?? '$syntheticIdPrefix${calls.length}',
                name: '${fc['name']}',
                args: args is Map ? Map<String, dynamic>.from(args) : {},
              ));
            }
          }
        }
        if (candidate['finishReason'] != null) {
          finishReason = '${candidate['finishReason']}';
        }
      }
    } catch (e) {
      throw mapTransportError(e, cancel);
    } finally {
      open.close();
    }

    yield LlmDone(LlmTurn(
      text: text.toString(),
      toolCalls: calls,
      stopReason: _stopReason(calls, finishReason, blockReason),
      native: compactParts(rawParts),
      nativeProvider: providerId,
      detail: blockReason ?? finishReason,
      outputTokens: outputTokens,
    ));
  }

  Future<OpenStream> _open(
    LlmRequest request,
    CancelToken? cancel, {
    required bool includeThinking,
  }) {
    final uri = Uri.parse(
        '$baseUrl/models/${Uri.encodeComponent(request.model)}:streamGenerateContent?alt=sse');
    final httpRequest = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(request, includeThinking: includeThinking));
    return openStream(
      httpRequest,
      clientFactory: _httpFactory,
      errorFromBody: _errorFromBody,
      cancel: cancel,
    );
  }

  Map<String, String> get _headers => {
        ...extraHeaders,
        'content-type': 'application/json',
        'x-goog-api-key': apiKey,
      };

  /// Builds the `generateContent` body. Visible for testing.
  Map<String, dynamic> buildBody(LlmRequest request,
      {bool includeThinking = true}) {
    final contents = <Map<String, dynamic>>[];
    void add(String role, List<Map<String, dynamic>> parts) {
      if (parts.isEmpty) return;
      if (contents.isNotEmpty && contents.last['role'] == role) {
        (contents.last['parts'] as List).addAll(parts);
      } else {
        contents.add({'role': role, 'parts': parts});
      }
    }

    for (final m in request.messages) {
      switch (m.role) {
        case LlmRole.user:
          add('user', [
            for (final img in m.images)
              {
                'inlineData': {
                  'mimeType': img.mimeType,
                  'data': base64Encode(img.bytes),
                }
              },
            if (m.text.isNotEmpty) {'text': m.text},
          ]);
        case LlmRole.assistant:
          if (m.nativeProvider == providerId && m.native is List) {
            add('model', [
              for (final p in m.native as List)
                Map<String, dynamic>.from(p as Map),
            ]);
          } else {
            add('model', [
              if (m.text.isNotEmpty) {'text': m.text},
              for (final call in m.toolCalls)
                {
                  'functionCall': {'name': call.name, 'args': call.args},
                  // A call that didn't come from Gemini has no signature.
                  // Gemini 3 validates signatures on function-call turns and
                  // documents this placeholder for injected history.
                  'thoughtSignature': 'skip_thought_signature_validator',
                },
            ]);
          }
        case LlmRole.tool:
          add('user', [
            for (final r in m.toolResults)
              {
                'functionResponse': {
                  'name': r.name,
                  'response': r.output,
                  if (!r.callId.startsWith(syntheticIdPrefix)) 'id': r.callId,
                }
              },
          ]);
      }
    }

    final declarations = [
      for (final t in request.tools)
        {
          'name': t.name,
          'description': t.description,
          // Gemini rejects OBJECT schemas with no properties, so zero-arg
          // tools omit `parameters` entirely.
          if (t.hasParameters) 'parameters': toGeminiSchema(t.parameters),
        }
    ];

    return {
      'systemInstruction': {
        'parts': [
          {'text': request.system}
        ]
      },
      'contents': contents,
      if (declarations.isNotEmpty)
        'tools': [
          {'functionDeclarations': declarations}
        ],
      // Temperature and maxOutputTokens are left at the model defaults:
      // Google advises against lowering temperature on Gemini 3, and a small
      // token cap on thinking models returns empty candidates.
      if (includeThinking)
        'generationConfig': {
          // Low thinking keeps a phone assistant snappy.
          'thinkingConfig': {'thinkingLevel': 'low'},
        },
    };
  }

  @override
  Future<List<LlmModelInfo>> listModels({CancelToken? cancel}) async {
    final models = <LlmModelInfo>[];
    String? pageToken;
    do {
      final uri = Uri.parse('$baseUrl/models').replace(queryParameters: {
        'pageSize': '1000',
        if (pageToken != null) 'pageToken': pageToken,
      });
      final json = await requestJson(
        http.Request('GET', uri)..headers.addAll(_headers),
        clientFactory: _httpFactory,
        errorFromBody: _errorFromBody,
        cancel: cancel,
      );
      for (final m in (json['models'] as List? ?? const [])) {
        if (m is! Map) continue;
        final name = '${m['name']}';
        final id = name.startsWith('models/') ? name.substring(7) : name;
        final methods = (m['supportedGenerationMethods'] as List?) ?? const [];
        if (!methods.contains('generateContent')) continue;
        if (!_isChatModel(id)) continue;
        models.add(LlmModelInfo(
          id: id,
          displayName: m['displayName'] as String?,
          supportsImages: true,
          maxOutputTokens: (m['outputTokenLimit'] as num?)?.toInt(),
        ));
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return models;
  }

  static bool _isChatModel(String id) {
    if (!id.startsWith('gemini')) return false;
    const excluded = [
      'embedding',
      'tts',
      'image',
      'live',
      'audio',
      'robotics',
      'computer-use',
      'translate',
    ];
    return !excluded.any(id.contains);
  }

  /// `thinkingLevel` exists on Gemini 3.x; the `-latest` aliases track 3.x.
  static bool _supportsThinkingLevel(String model) =>
      model.startsWith('gemini-3') ||
      model.startsWith('gemini-4') ||
      model.endsWith('-latest');

  static LlmStopReason _stopReason(
      List<LlmToolCall> calls, String? finish, String? block) {
    if (block != null) return LlmStopReason.blocked;
    if (calls.isNotEmpty) return LlmStopReason.toolUse;
    switch (finish) {
      case null:
      case 'STOP':
      case 'FINISH_REASON_UNSPECIFIED':
        return LlmStopReason.end;
      case 'MAX_TOKENS':
        return LlmStopReason.maxTokens;
      case 'SAFETY':
      case 'RECITATION':
      case 'BLOCKLIST':
      case 'PROHIBITED_CONTENT':
      case 'SPII':
      case 'IMAGE_SAFETY':
        return LlmStopReason.blocked;
      default:
        return LlmStopReason.other;
    }
  }

  /// Merge adjacent plain-text parts (keeps anything carrying a
  /// thoughtSignature or other metadata separate and in order).
  static List<Map<String, dynamic>> compactParts(
      List<Map<String, dynamic>> parts) {
    final out = <Map<String, dynamic>>[];
    for (final p in parts) {
      final isPlainText = p.length == 1 && p['text'] is String;
      if (isPlainText &&
          out.isNotEmpty &&
          out.last.length == 1 &&
          out.last['text'] is String) {
        out.last = {'text': '${out.last['text']}${p['text']}'};
      } else if (isPlainText && (p['text'] as String).isEmpty) {
        continue;
      } else {
        out.add(p);
      }
    }
    return out;
  }

  /// Converts JSON Schema into Gemini's OpenAPI-subset schema (upper-case
  /// type enums, unsupported keywords dropped).
  static Map<String, dynamic> toGeminiSchema(Map<String, dynamic> schema) {
    final out = <String, dynamic>{};
    final type = schema['type'];
    if (type is String) out['type'] = type.toUpperCase();
    for (final key in const [
      'description',
      'enum',
      'format',
      'nullable',
      'minimum',
      'maximum',
      'required',
    ]) {
      if (schema.containsKey(key)) out[key] = schema[key];
    }
    final props = schema['properties'];
    if (props is Map) {
      out['properties'] = {
        for (final e in props.entries)
          '${e.key}': toGeminiSchema(Map<String, dynamic>.from(e.value as Map)),
      };
    }
    final items = schema['items'];
    if (items is Map) {
      out['items'] = toGeminiSchema(Map<String, dynamic>.from(items));
    }
    return out;
  }

  LlmException _errorFromBody(
      int status, String body, Map<String, String> headers) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        return _errorFromJson(status, json['error'] as Map, headers);
      }
    } catch (_) {}
    return LlmException(kindForStatus(status), clipForError(body),
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }

  LlmException _errorFromJson(
      int status, Map error, Map<String, String> headers) {
    final message = '${error['message'] ?? 'Unknown error'}';
    final reasons = [
      for (final d in (error['details'] as List? ?? const []))
        if (d is Map && d['reason'] != null) '${d['reason']}'
    ];
    var kind = kindForStatus(status);
    final lower = message.toLowerCase();
    if (reasons.contains('API_KEY_INVALID') ||
        lower.contains('api key not valid') ||
        lower.contains('api key expired')) {
      kind = LlmErrorKind.auth;
    } else if (lower.contains('location is not supported')) {
      kind = LlmErrorKind.permission;
    } else if (status == 429 &&
        (lower.contains('quota') || lower.contains('billing'))) {
      kind = LlmErrorKind.quota;
    } else if (status == 404 || lower.contains('is not found for api version')) {
      kind = LlmErrorKind.notFound;
    }
    return LlmException(kind, message,
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }
}

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;
