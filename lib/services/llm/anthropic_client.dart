import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_stream.dart';
import 'llm_types.dart';

/// Anthropic Claude via the Messages API (raw HTTP — there is no official
/// Dart SDK).
class AnthropicClient implements LlmClient {
  static const String defaultBaseUrl = 'https://api.anthropic.com/v1';
  static const String _apiVersion = '2023-06-01';
  static const String _fallbackBeta = 'server-side-fallback-2026-07-01';

  final String apiKey;
  final String baseUrl;

  /// Capabilities of the selected model, read from `GET /v1/models` when the
  /// user picked it. Unknown (null) means "don't send the optional field".
  final bool? supportsEffort;
  final int? modelMaxOutputTokens;
  final HttpClientFactory _httpFactory;

  bool _fallbacksRejected = false;

  AnthropicClient({
    required this.apiKey,
    String? baseUrl,
    this.supportsEffort,
    this.modelMaxOutputTokens,
    HttpClientFactory? httpClientFactory,
  })  : baseUrl = _trimSlash(baseUrl ?? defaultBaseUrl),
        _httpFactory = httpClientFactory ?? defaultHttpClientFactory;

  @override
  String get providerId => 'anthropic';

  Map<String, String> _headers({bool fallbacks = false}) => {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        if (fallbacks) 'anthropic-beta': _fallbackBeta,
      };

  /// Opus 5-family and Fable models run safety classifiers that can decline
  /// a request; `fallbacks: "default"` re-runs a declined request on the
  /// recommended fallback model server-side.
  bool _useFallbacks(String model) =>
      !_fallbacksRejected &&
      (model.startsWith('claude-opus-5') || model.startsWith('claude-fable-5'));

  @override
  Stream<LlmEvent> stream(LlmRequest request, {CancelToken? cancel}) {
    return withRetries(() => _streamOnce(request, cancel), cancel: cancel);
  }

  Stream<LlmEvent> _streamOnce(LlmRequest request, CancelToken? cancel) async* {
    final fallbacks = _useFallbacks(request.model);
    OpenStream open;
    try {
      open = await _open(request, cancel, fallbacks: fallbacks);
    } on LlmException catch (e) {
      if (fallbacks &&
          e.kind == LlmErrorKind.invalidRequest &&
          e.message.toLowerCase().contains('fallback')) {
        _fallbacksRejected = true;
        open = await _open(request, cancel, fallbacks: false);
      } else {
        rethrow;
      }
    }

    final blocks = <int, Map<String, dynamic>>{};
    final jsonBuffers = <int, StringBuffer>{};
    final text = StringBuffer();
    String? stopReason;
    String? refusalCategory;
    int? outputTokens;

    try {
      await for (final event in parseSse(open.bytes())) {
        final json = decodeEventJson(event.data);
        switch (json['type']) {
          case 'content_block_start':
            final index = (json['index'] as num).toInt();
            final block =
                Map<String, dynamic>.from(json['content_block'] as Map);
            blocks[index] = block;
            if (block['type'] == 'tool_use') {
              jsonBuffers[index] = StringBuffer();
              block['input'] = <String, dynamic>{};
            } else if (block['type'] == 'text') {
              final t = block['text'];
              if (t is String && t.isNotEmpty) {
                text.write(t);
                yield LlmTextDelta(t);
              }
            }
          case 'content_block_delta':
            final index = (json['index'] as num).toInt();
            final block = blocks[index];
            final delta = json['delta'];
            if (block == null || delta is! Map) break;
            switch (delta['type']) {
              case 'text_delta':
                final t = '${delta['text'] ?? ''}';
                block['text'] = '${block['text'] ?? ''}$t';
                if (t.isNotEmpty) {
                  text.write(t);
                  yield LlmTextDelta(t);
                }
              case 'input_json_delta':
                jsonBuffers[index]?.write(delta['partial_json'] ?? '');
              case 'thinking_delta':
                block['thinking'] =
                    '${block['thinking'] ?? ''}${delta['thinking'] ?? ''}';
              case 'signature_delta':
                block['signature'] = delta['signature'];
            }
          case 'content_block_stop':
            final index = (json['index'] as num).toInt();
            final buffer = jsonBuffers[index];
            final block = blocks[index];
            if (buffer != null && block != null) {
              final raw = buffer.toString().trim();
              if (raw.isEmpty) {
                block['input'] = <String, dynamic>{};
              } else {
                // Eager input streaming means the server no longer validates
                // tool input — parse strictly and flag anything malformed.
                try {
                  final decoded = jsonDecode(raw);
                  if (decoded is Map) {
                    block['input'] = Map<String, dynamic>.from(decoded);
                  } else {
                    block['_invalid'] = raw;
                  }
                } catch (_) {
                  block['_invalid'] = raw;
                }
              }
            }
          case 'message_delta':
            final delta = json['delta'];
            if (delta is Map) {
              stopReason = delta['stop_reason'] as String? ?? stopReason;
              final details = delta['stop_details'];
              if (details is Map && details['category'] != null) {
                refusalCategory = '${details['category']}';
              }
            }
            final usage = json['usage'];
            if (usage is Map && usage['output_tokens'] is num) {
              outputTokens = (usage['output_tokens'] as num).toInt();
            }
          case 'error':
            final error = json['error'];
            throw _errorFromJson(
                500, error is Map ? error : {'message': '$error'}, const {});
          default:
            break; // message_start, ping, message_stop
        }
      }
    } catch (e) {
      throw mapTransportError(e, cancel);
    } finally {
      open.close();
    }

    final ordered = (blocks.keys.toList()..sort()).map((i) => blocks[i]!);
    final content = echoableContent(ordered.toList());
    final calls = <LlmToolCall>[
      for (final b in content)
        if (b['type'] == 'tool_use')
          LlmToolCall(
            id: '${b['id']}',
            name: '${b['name']}',
            args: b['_invalid'] == null
                ? Map<String, dynamic>.from(b['input'] as Map? ?? const {})
                : const {},
            invalidArgs: b['_invalid'] as String?,
          ),
    ];
    // Strip our private marker before the blocks are stored for replay.
    for (final b in content) {
      if (b.remove('_invalid') != null) b['input'] = <String, dynamic>{};
    }

    yield LlmDone(LlmTurn(
      text: text.toString(),
      toolCalls: calls,
      stopReason: _stopReason(stopReason),
      native: content,
      nativeProvider: providerId,
      detail: refusalCategory ?? stopReason,
      outputTokens: outputTokens,
    ));
  }

  Future<OpenStream> _open(LlmRequest request, CancelToken? cancel,
      {required bool fallbacks}) {
    final httpRequest = http.Request('POST', Uri.parse('$baseUrl/messages'))
      ..headers.addAll(_headers(fallbacks: fallbacks))
      ..body = jsonEncode(buildBody(request, fallbacks: fallbacks));
    return openStream(
      httpRequest,
      clientFactory: _httpFactory,
      errorFromBody: _errorFromBody,
      cancel: cancel,
    );
  }

  /// After a mid-output server-side fallback, the blocks before the final
  /// `fallback` marker that belong to the declined attempt (thinking,
  /// redacted thinking, tool_use) must not be echoed back; the marker itself
  /// is an audit block we drop. Visible for testing.
  static List<Map<String, dynamic>> echoableContent(
      List<Map<String, dynamic>> blocks) {
    final lastFallback = blocks.lastIndexWhere((b) => b['type'] == 'fallback');
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final type = b['type'];
      if (type == 'fallback') continue;
      if (i < lastFallback &&
          (type == 'thinking' ||
              type == 'redacted_thinking' ||
              type == 'tool_use')) {
        continue;
      }
      if (type == 'text' && '${b['text'] ?? ''}'.isEmpty) continue;
      out.add(b);
    }
    return out;
  }

  /// Builds the Messages API body. Visible for testing.
  Map<String, dynamic> buildBody(LlmRequest request, {bool fallbacks = false}) {
    final messages = <Map<String, dynamic>>[];
    void add(String role, List<Map<String, dynamic>> content) {
      if (content.isEmpty) return;
      if (messages.isNotEmpty && messages.last['role'] == role) {
        (messages.last['content'] as List).addAll(content);
      } else {
        messages.add({'role': role, 'content': content});
      }
    }

    for (final m in request.messages) {
      switch (m.role) {
        case LlmRole.user:
          add('user', [
            for (final img in m.images)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': img.mimeType,
                  'data': base64Encode(img.bytes),
                },
              },
            if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
          ]);
        case LlmRole.assistant:
          if (m.nativeProvider == providerId && m.native is List) {
            add('assistant', [
              for (final b in m.native as List)
                Map<String, dynamic>.from(b as Map),
            ]);
          } else {
            add('assistant', [
              if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
              for (final c in m.toolCalls)
                {
                  'type': 'tool_use',
                  'id': c.id,
                  'name': c.name,
                  'input': c.args,
                },
            ]);
          }
        case LlmRole.tool:
          add('user', [
            for (final r in m.toolResults)
              {
                'type': 'tool_result',
                'tool_use_id': r.callId,
                'content': jsonEncode(r.output),
                if (r.isError) 'is_error': true,
              },
          ]);
      }
    }
    // The conversation must open with a user turn.
    while (messages.isNotEmpty && messages.first['role'] != 'user') {
      messages.removeAt(0);
    }

    final maxTokens = modelMaxOutputTokens != null && modelMaxOutputTokens! > 0
        ? (modelMaxOutputTokens! < 64000 ? modelMaxOutputTokens! : 64000)
        : 64000;

    return {
      'model': request.model,
      'max_tokens': maxTokens,
      'system': request.system,
      'messages': messages,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final t in request.tools)
            {
              'name': t.name,
              'description': t.description,
              'input_schema': {
                'type': 'object',
                'properties': const <String, dynamic>{},
                ...t.parameters,
              },
              'eager_input_streaming': true,
            },
        ],
      'stream': true,
      // A phone assistant is latency-sensitive chat: low effort keeps turns
      // quick and cheap. Only sent when the model advertises support.
      if (supportsEffort == true) 'output_config': {'effort': 'low'},
      if (fallbacks) 'fallbacks': 'default',
    };
  }

  @override
  Future<List<LlmModelInfo>> listModels({CancelToken? cancel}) async {
    final out = <LlmModelInfo>[];
    String? afterId;
    for (var page = 0; page < 10; page++) {
      final uri = Uri.parse('$baseUrl/models').replace(queryParameters: {
        'limit': '100',
        if (afterId != null) 'after_id': afterId,
      });
      final json = await requestJson(
        http.Request('GET', uri)..headers.addAll(_headers()),
        clientFactory: _httpFactory,
        errorFromBody: _errorFromBody,
        cancel: cancel,
      );
      for (final m in (json['data'] as List? ?? const [])) {
        if (m is! Map) continue;
        final caps = m['capabilities'];
        bool? supported(String key) {
          if (caps is! Map) return null;
          final entry = caps[key];
          return entry is Map ? entry['supported'] == true : null;
        }

        out.add(LlmModelInfo(
          id: '${m['id']}',
          displayName: m['display_name'] as String?,
          supportsImages: supported('image_input'),
          supportsEffort: supported('effort'),
          maxOutputTokens: (m['max_tokens'] as num?)?.toInt(),
        ));
      }
      if (json['has_more'] != true) break;
      afterId = json['last_id'] as String?;
      if (afterId == null) break;
    }
    return out;
  }

  static LlmStopReason _stopReason(String? reason) {
    switch (reason) {
      case 'tool_use':
        return LlmStopReason.toolUse;
      case 'max_tokens':
      case 'model_context_window_exceeded':
        return LlmStopReason.maxTokens;
      case 'refusal':
        return LlmStopReason.refusal;
      case null:
      case 'end_turn':
      case 'stop_sequence':
        return LlmStopReason.end;
      default:
        return LlmStopReason.other;
    }
  }

  LlmException _errorFromBody(
      int status, String body, Map<String, String> headers) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is Map) {
        return _errorFromJson(status, json['error'] as Map, headers);
      }
    } catch (_) {}
    return LlmException(kindForStatus(status),
        body.trim().isEmpty ? 'HTTP $status' : clipForError(body),
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }

  LlmException _errorFromJson(
      int status, Map error, Map<String, String> headers) {
    final message = '${error['message'] ?? 'Unknown error'}';
    final kind = switch ('${error['type']}') {
      'authentication_error' => LlmErrorKind.auth,
      'permission_error' => LlmErrorKind.permission,
      'not_found_error' => LlmErrorKind.notFound,
      'rate_limit_error' => LlmErrorKind.rateLimit,
      'overloaded_error' || 'api_error' => LlmErrorKind.server,
      'billing_error' => LlmErrorKind.quota,
      'invalid_request_error'
          when message.toLowerCase().contains('credit balance') =>
        LlmErrorKind.quota,
      _ => kindForStatus(status),
    };
    return LlmException(kind, message,
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }
}

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;
