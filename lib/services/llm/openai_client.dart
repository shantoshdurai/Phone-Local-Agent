import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_stream.dart';
import 'llm_types.dart';

/// Any server speaking the OpenAI Chat Completions API: OpenAI itself, Groq,
/// OpenRouter, and self-hosted servers such as Ollama, LM Studio or vLLM.
class OpenAiCompatClient implements LlmClient {
  @override
  final String providerId;
  final String baseUrl;
  final String? apiKey;

  /// Official OpenAI endpoint: enables OpenAI-only request fields and
  /// filters its model list down to chat models.
  final bool isOfficialOpenAi;
  final Map<String, String> extraHeaders;
  final HttpClientFactory _httpFactory;

  OpenAiCompatClient({
    required this.providerId,
    required String baseUrl,
    this.apiKey,
    this.isOfficialOpenAi = false,
    this.extraHeaders = const {},
    HttpClientFactory? httpClientFactory,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _httpFactory = httpClientFactory ?? defaultHttpClientFactory;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'authorization': 'Bearer $apiKey',
        ...extraHeaders,
      };

  @override
  Stream<LlmEvent> stream(LlmRequest request, {CancelToken? cancel}) {
    return withRetries(() => _streamOnce(request, cancel), cancel: cancel);
  }

  Stream<LlmEvent> _streamOnce(LlmRequest request, CancelToken? cancel) async* {
    final httpRequest =
        http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
          ..headers.addAll(_headers)
          ..body = jsonEncode(buildBody(request));
    final open = await openStream(
      httpRequest,
      clientFactory: _httpFactory,
      errorFromBody: _errorFromBody,
      cancel: cancel,
    );

    final text = StringBuffer();
    final toolAcc = <int, _ToolAccumulator>{};
    String? finishReason;
    int? outputTokens;

    try {
      await for (final event in parseSse(open.bytes())) {
        final data = event.data.trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        final json = decodeEventJson(data);
        if (json['error'] != null) {
          throw _errorFromJson(500, json['error'], const {});
        }
        final usage = json['usage'];
        if (usage is Map && usage['completion_tokens'] is num) {
          outputTokens = (usage['completion_tokens'] as num).toInt();
        }
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first as Map;
        final delta = choice['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            text.write(content);
            yield LlmTextDelta(content);
          }
          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (var i = 0; i < toolCalls.length; i++) {
              final tc = toolCalls[i];
              if (tc is! Map) continue;
              final index = (tc['index'] as num?)?.toInt() ?? i;
              final acc = toolAcc.putIfAbsent(index, _ToolAccumulator.new);
              if (tc['id'] is String && (tc['id'] as String).isNotEmpty) {
                acc.id = tc['id'] as String;
              }
              final fn = tc['function'];
              if (fn is Map) {
                // Some servers resend the full name on every chunk; take it
                // once rather than concatenating duplicates.
                if (fn['name'] is String && acc.name.isEmpty) {
                  acc.name = fn['name'] as String;
                }
                final args = fn['arguments'];
                if (args is String) {
                  acc.args.write(args);
                } else if (args is Map) {
                  acc.args.write(jsonEncode(args));
                }
              }
            }
          }
        }
        if (choice['finish_reason'] is String) {
          finishReason = choice['finish_reason'] as String;
        }
      }
    } catch (e) {
      throw mapTransportError(e, cancel);
    } finally {
      open.close();
    }

    final calls = <LlmToolCall>[];
    final ordered = toolAcc.keys.toList()..sort();
    for (final index in ordered) {
      final acc = toolAcc[index]!;
      if (acc.name.isEmpty) continue;
      final raw = acc.args.toString().trim();
      Map<String, dynamic> args = {};
      String? invalid;
      if (raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            args = Map<String, dynamic>.from(decoded);
          } else {
            invalid = raw;
          }
        } catch (_) {
          invalid = raw;
        }
      }
      calls.add(LlmToolCall(
        id: acc.id ?? 'call_${calls.length}',
        name: acc.name,
        args: args,
        invalidArgs: invalid,
      ));
    }

    yield LlmDone(LlmTurn(
      text: text.toString(),
      toolCalls: calls,
      stopReason: _stopReason(calls, finishReason),
      detail: finishReason,
      outputTokens: outputTokens,
    ));
  }

  /// Builds the chat-completions body. Visible for testing.
  Map<String, dynamic> buildBody(LlmRequest request) {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': request.system},
    ];
    for (final m in request.messages) {
      switch (m.role) {
        case LlmRole.user:
          if (m.images.isEmpty) {
            messages.add({'role': 'user', 'content': m.text});
          } else {
            messages.add({
              'role': 'user',
              'content': [
                if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
                for (final img in m.images)
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url':
                          'data:${img.mimeType};base64,${base64Encode(img.bytes)}',
                    },
                  },
              ],
            });
          }
        case LlmRole.assistant:
          messages.add({
            'role': 'assistant',
            'content': m.text.isEmpty && m.toolCalls.isNotEmpty ? null : m.text,
            if (m.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final c in m.toolCalls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': c.invalidArgs ?? jsonEncode(c.args),
                    },
                  },
              ],
          });
        case LlmRole.tool:
          for (final r in m.toolResults) {
            messages.add({
              'role': 'tool',
              'tool_call_id': r.callId,
              'content': jsonEncode(r.output),
            });
          }
      }
    }
    return {
      'model': request.model,
      'messages': messages,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final t in request.tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': {
                  'type': 'object',
                  'properties': const <String, dynamic>{},
                  ...t.parameters,
                },
              },
            },
        ],
      'stream': true,
      // Reasoning models default to "medium" effort, which is slow for a
      // phone assistant. Only OpenAI's own endpoint is guaranteed to accept
      // the field, and only on reasoning models.
      if (isOfficialOpenAi && _isReasoningModel(request.model))
        'reasoning_effort': 'low',
    };
  }

  static bool _isReasoningModel(String model) =>
      model.startsWith('gpt-5') ||
      model.startsWith('o1') ||
      model.startsWith('o3') ||
      model.startsWith('o4');

  @override
  Future<List<LlmModelInfo>> listModels({CancelToken? cancel}) async {
    final json = await requestJson(
      http.Request('GET', Uri.parse('$baseUrl/models'))..headers.addAll(_headers),
      clientFactory: _httpFactory,
      errorFromBody: _errorFromBody,
      cancel: cancel,
    );
    final data = json['data'] ?? json['models'];
    final out = <LlmModelInfo>[];
    if (data is List) {
      for (final m in data) {
        if (m is! Map) continue;
        final id = (m['id'] ?? m['name'] ?? '').toString();
        if (id.isEmpty) continue;
        if (isOfficialOpenAi && !_isOpenAiChatModel(id)) continue;
        out.add(LlmModelInfo(id: id, displayName: m['name'] as String?));
      }
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  static bool _isOpenAiChatModel(String id) {
    if (!(id.startsWith('gpt-') || RegExp(r'^o\d').hasMatch(id) || id.startsWith('chatgpt'))) {
      return false;
    }
    const excluded = [
      'audio',
      'realtime',
      'transcribe',
      'tts',
      'image',
      'search',
      'embedding',
      'moderation',
      'instruct',
      'computer-use',
    ];
    return !excluded.any(id.contains);
  }

  static LlmStopReason _stopReason(List<LlmToolCall> calls, String? finish) {
    if (calls.isNotEmpty) return LlmStopReason.toolUse;
    switch (finish) {
      case 'length':
        return LlmStopReason.maxTokens;
      case 'content_filter':
        return LlmStopReason.blocked;
      case null:
      case 'stop':
      case 'eos':
      case 'end_turn':
        return LlmStopReason.end;
      default:
        return LlmStopReason.other;
    }
  }

  LlmException _errorFromBody(
      int status, String body, Map<String, String> headers) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        if (json['error'] != null) {
          return _errorFromJson(status, json['error'], headers);
        }
        if (json['message'] is String) {
          return _errorFromJson(status, json['message'], headers);
        }
      }
    } catch (_) {}
    return LlmException(kindForStatus(status),
        body.trim().isEmpty ? 'HTTP $status' : clipForError(body),
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }

  LlmException _errorFromJson(
      int status, Object error, Map<String, String> headers) {
    var message = error is Map ? '${error['message'] ?? error}' : '$error';
    final code = error is Map ? '${error['code'] ?? error['type'] ?? ''}' : '';
    var kind = kindForStatus(status);
    if (code == 'insufficient_quota' ||
        message.toLowerCase().contains('insufficient credits') ||
        message.toLowerCase().contains('exceeded your current quota')) {
      kind = LlmErrorKind.quota;
    } else if (code == 'invalid_api_key' ||
        message.toLowerCase().contains('invalid api key') ||
        message.toLowerCase().contains('incorrect api key')) {
      kind = LlmErrorKind.auth;
    } else if (code == 'model_not_found' ||
        message.toLowerCase().contains('model') &&
            message.toLowerCase().contains('not found')) {
      kind = LlmErrorKind.notFound;
    }
    if (message.isEmpty) message = 'HTTP $status';
    return LlmException(kind, message,
        statusCode: status, retryAfter: retryAfterFrom(headers));
  }
}

class _ToolAccumulator {
  String? id;
  String name = '';
  final StringBuffer args = StringBuffer();
}
