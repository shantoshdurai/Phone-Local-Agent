import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_agent/services/llm/anthropic_client.dart';
import 'package:local_agent/services/llm/gemini_client.dart';
import 'package:local_agent/services/llm/http_stream.dart';
import 'package:local_agent/services/llm/llm_types.dart';
import 'package:local_agent/services/llm/openai_client.dart';

/// A mock HTTP layer that replays scripted responses and records requests.
class _Server {
  final List<(int, String, Map<String, String>)> responses;
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];
  _Server(this.responses);

  http.Client client() => MockClient.streaming((request, body) async {
        requests.add(request);
        bodies.add(await body.bytesToString());
        final (status, text, headers) = responses[requests.length - 1];
        return http.StreamedResponse(
          Stream.fromIterable(_chunks(utf8.encode(text))),
          status,
          headers: {'content-type': 'text/event-stream', ...headers},
        );
      });

  /// Splits bytes into small uneven chunks to exercise chunk-boundary
  /// handling (including mid-UTF-8 splits).
  static Iterable<List<int>> _chunks(List<int> bytes) sync* {
    var i = 0;
    var size = 7;
    while (i < bytes.length) {
      final end = (i + size).clamp(0, bytes.length);
      yield bytes.sublist(i, end);
      i = end;
      size = size == 7 ? 13 : 7;
    }
  }

  Map<String, dynamic> jsonBody(int i) => jsonDecode(bodies[i]) as Map<String, dynamic>;
}

String sse(List<Object> events, {bool named = false}) {
  final b = StringBuffer();
  for (final e in events) {
    if (named && e is Map) b.writeln('event: ${e['type']}');
    b.writeln('data: ${e is String ? e : jsonEncode(e)}');
    b.writeln();
  }
  return b.toString();
}

Future<(String, LlmTurn)> collect(Stream<LlmEvent> stream) async {
  final text = StringBuffer();
  LlmTurn? turn;
  await for (final e in stream) {
    switch (e) {
      case LlmTextDelta(text: final t):
        text.write(t);
      case LlmDone(turn: final t):
        turn = t;
    }
  }
  return (text.toString(), turn!);
}

const _tools = [
  LlmToolDef(name: 'get_date_time', description: 'Time', parameters: {
    'type': 'object',
    'properties': <String, dynamic>{},
  }),
  LlmToolDef(name: 'get_weather', description: 'Weather', parameters: {
    'type': 'object',
    'properties': {
      'location': {'type': 'string', 'description': 'City'},
    },
    'required': ['location'],
  }),
];

LlmRequest request(String model, {List<LlmMessage>? messages}) => LlmRequest(
      model: model,
      system: 'You are a test.',
      messages: messages ?? [LlmMessage.user('Weather in Pune? Ça va 👋')],
      tools: _tools,
    );

void main() {
  group('GeminiClient', () {
    test('streams text and function calls, preserving thought signatures', () async {
      final server = _Server([
        (
          200,
          sse([
            {
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {'text': 'Checking ☀️ '}
                    ]
                  }
                }
              ]
            },
            {
              'candidates': [
                {
                  'content': {
                    'role': 'model',
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'get_weather',
                          'args': {'location': 'Pune'},
                          'id': 'fc_1'
                        },
                        'thoughtSignature': 'SIG123'
                      }
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ],
              'usageMetadata': {'candidatesTokenCount': 12}
            },
          ]),
          const {},
        ),
      ]);
      final client = GeminiClient(apiKey: 'k', httpClientFactory: server.client);
      final (text, turn) = await collect(client.stream(request('gemini-flash-latest')));

      expect(text, 'Checking ☀️ ');
      expect(turn.stopReason, LlmStopReason.toolUse);
      expect(turn.toolCalls.single.name, 'get_weather');
      expect(turn.toolCalls.single.id, 'fc_1');
      expect(turn.toolCalls.single.args, {'location': 'Pune'});
      final parts = turn.native as List;
      expect(parts.last['thoughtSignature'], 'SIG123');
      expect(turn.outputTokens, 12);

      final req = server.requests.single;
      expect(req.url.path, endsWith('/models/gemini-flash-latest:streamGenerateContent'));
      expect(req.url.queryParameters['alt'], 'sse');
      expect(req.headers['x-goog-api-key'], 'k');
      expect(req.url.queryParameters.containsKey('key'), isFalse, reason: 'key stays out of URLs');
    });

    test('request body: schemas, zero-arg tools, replay and tool results', () {
      final client = GeminiClient(apiKey: 'k');
      final body = client.buildBody(request('gemini-flash-latest', messages: [
        LlmMessage.user('hi'),
        LlmMessage.assistant('', toolCalls: const [
          LlmToolCall(id: 'fc_9', name: 'get_weather', args: {'location': 'Pune'}),
        ], native: [
          {
            'functionCall': {'name': 'get_weather', 'args': {'location': 'Pune'}, 'id': 'fc_9'},
            'thoughtSignature': 'S'
          }
        ], nativeProvider: 'gemini'),
        LlmMessage.toolResults(const [
          LlmToolResult(callId: 'fc_9', name: 'get_weather', output: {'temperatureC': 30}),
        ]),
      ]));

      final decls = body['tools'][0]['functionDeclarations'] as List;
      expect(decls[0].containsKey('parameters'), isFalse, reason: 'Gemini rejects empty OBJECT schemas');
      expect(decls[1]['parameters']['type'], 'OBJECT');
      expect(decls[1]['parameters']['properties']['location']['type'], 'STRING');
      expect(body['generationConfig']['thinkingConfig']['thinkingLevel'], 'low');
      expect(body['systemInstruction']['parts'][0]['text'], 'You are a test.');

      final contents = body['contents'] as List;
      expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
      expect(contents[1]['parts'][0]['thoughtSignature'], 'S', reason: 'native parts replayed verbatim');
      final fr = contents[2]['parts'][0]['functionResponse'];
      expect(fr['name'], 'get_weather');
      expect(fr['id'], 'fc_9');
      expect(fr['response'], {'temperatureC': 30});
    });

    test('retries without thinkingConfig when the model rejects it', () async {
      final server = _Server([
        (
          400,
          jsonEncode({
            'error': {'code': 400, 'message': 'Thinking level is not supported for this model.', 'status': 'INVALID_ARGUMENT'}
          }),
          const {},
        ),
        (
          200,
          sse([
            {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'ok'}
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ]
            }
          ]),
          const {},
        ),
      ]);
      final client = GeminiClient(apiKey: 'k', httpClientFactory: server.client);
      final (text, turn) = await collect(client.stream(request('gemini-3.8-flash')));
      expect(text, 'ok');
      expect(turn.stopReason, LlmStopReason.end);
      expect(server.jsonBody(0).containsKey('generationConfig'), isTrue);
      expect(server.jsonBody(1).containsKey('generationConfig'), isFalse);
    });

    test('maps an invalid key to an auth error', () async {
      final server = _Server([
        (
          400,
          jsonEncode({
            'error': {
              'code': 400,
              'message': 'API key not valid. Please pass a valid API key.',
              'status': 'INVALID_ARGUMENT',
              'details': [
                {'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'reason': 'API_KEY_INVALID'}
              ]
            }
          }),
          const {},
        ),
      ]);
      final client = GeminiClient(apiKey: 'bad', httpClientFactory: server.client);
      await expectLater(
        client.listModels(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.auth)),
      );
    });

    test('blocked prompts surface as blocked', () async {
      final server = _Server([
        (
          200,
          sse([
            {
              'promptFeedback': {'blockReason': 'SAFETY'}
            }
          ]),
          const {},
        ),
      ]);
      final client = GeminiClient(apiKey: 'k', httpClientFactory: server.client);
      final (_, turn) = await collect(client.stream(request('gemini-flash-latest')));
      expect(turn.stopReason, LlmStopReason.blocked);
    });

    test('listModels keeps chat models only', () async {
      final server = _Server([
        (
          200,
          jsonEncode({
            'models': [
              {'name': 'models/gemini-3.8-flash', 'displayName': 'Gemini 3.8 Flash', 'supportedGenerationMethods': ['generateContent']},
              {'name': 'models/gemini-embedding-001', 'supportedGenerationMethods': ['embedContent']},
              {'name': 'models/gemini-3.5-flash-tts', 'supportedGenerationMethods': ['generateContent']},
            ]
          }),
          const {'content-type': 'application/json'},
        ),
      ]);
      final client = GeminiClient(apiKey: 'k', httpClientFactory: server.client);
      final models = await client.listModels();
      expect(models.map((m) => m.id), ['gemini-3.8-flash']);
      expect(models.single.displayName, 'Gemini 3.8 Flash');
    });
  });

  group('OpenAiCompatClient', () {
    test('accumulates streamed tool-call fragments, including parallel calls', () async {
      final server = _Server([
        (
          200,
          sse([
            {
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {'index': 0, 'id': 'call_a', 'type': 'function', 'function': {'name': 'get_weather', 'arguments': '{"loc'}}
                    ]
                  }
                }
              ]
            },
            {
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {'index': 0, 'function': {'arguments': 'ation": "Pune"}'}},
                      {'index': 1, 'id': 'call_b', 'function': {'name': 'get_date_time', 'arguments': ''}}
                    ]
                  }
                }
              ]
            },
            {
              'choices': [
                {'delta': {}, 'finish_reason': 'tool_calls'}
              ]
            },
            '[DONE]',
          ]),
          const {},
        ),
      ]);
      final client = OpenAiCompatClient(
          providerId: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk',
          isOfficialOpenAi: true,
          httpClientFactory: server.client);
      final (_, turn) = await collect(client.stream(request('gpt-5-mini')));
      expect(turn.stopReason, LlmStopReason.toolUse);
      expect(turn.toolCalls.map((c) => c.id), ['call_a', 'call_b']);
      expect(turn.toolCalls[0].args, {'location': 'Pune'});
      expect(turn.toolCalls[1].args, isEmpty);
      expect(server.requests.single.headers['authorization'], 'Bearer sk');
      expect(server.jsonBody(0)['reasoning_effort'], 'low');
    });

    test('flags malformed arguments instead of guessing', () async {
      final server = _Server([
        (
          200,
          sse([
            {
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {'index': 0, 'id': 'c1', 'function': {'name': 'get_weather', 'arguments': '{"location": Pune'}}
                    ]
                  },
                  'finish_reason': 'tool_calls'
                }
              ]
            },
            '[DONE]',
          ]),
          const {},
        ),
      ]);
      final client = OpenAiCompatClient(providerId: 'groq', baseUrl: 'https://x/v1', apiKey: 'k', httpClientFactory: server.client);
      final (_, turn) = await collect(client.stream(request('llama')));
      expect(turn.toolCalls.single.invalidArgs, '{"location": Pune');
      expect(turn.toolCalls.single.args, isEmpty);
      expect(server.jsonBody(0).containsKey('reasoning_effort'), isFalse, reason: 'only official OpenAI');
    });

    test('streams text and maps quota errors', () async {
      final server = _Server([
        (
          200,
          sse([
            {
              'choices': [
                {'delta': {'content': 'Hel'}}
              ]
            },
            {
              'choices': [
                {'delta': {'content': 'lo'}, 'finish_reason': 'stop'}
              ]
            },
            '[DONE]',
          ]),
          const {},
        ),
        (
          429,
          jsonEncode({
            'error': {'message': 'You exceeded your current quota.', 'type': 'insufficient_quota', 'code': 'insufficient_quota'}
          }),
          const {},
        ),
      ]);
      final client = OpenAiCompatClient(providerId: 'openai', baseUrl: 'https://x/v1', apiKey: 'k', httpClientFactory: server.client);
      final (text, turn) = await collect(client.stream(request('gpt-4.1-mini')));
      expect(text, 'Hello');
      expect(turn.stopReason, LlmStopReason.end);
      await expectLater(
        collect(client.stream(request('gpt-4.1-mini'))),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.quota)),
      );
    });

    test('body: tool calls and results use chat-completions shape', () {
      final client = OpenAiCompatClient(providerId: 'custom', baseUrl: 'http://pc:11434/v1');
      final body = client.buildBody(request('llama3.2', messages: [
        LlmMessage.user('hi'),
        LlmMessage.assistant('', toolCalls: const [
          LlmToolCall(id: 'c1', name: 'get_weather', args: {'location': 'Pune'}),
        ]),
        LlmMessage.toolResults(const [
          LlmToolResult(callId: 'c1', name: 'get_weather', output: {'ok': true}),
        ]),
      ]));
      final messages = body['messages'] as List;
      expect(messages[0]['role'], 'system');
      expect(messages[2]['content'], isNull);
      expect(messages[2]['tool_calls'][0]['function']['arguments'], '{"location":"Pune"}');
      expect(messages[3], {'role': 'tool', 'tool_call_id': 'c1', 'content': '{"ok":true}'});
      expect(body['tools'][0]['function']['parameters']['type'], 'object');
    });

    test('retries a rate-limited request before streaming', () async {
      final server = _Server([
        (429, jsonEncode({'error': {'message': 'slow down'}}), const {'retry-after': '0'}),
        (
          200,
          sse([
            {
              'choices': [
                {'delta': {'content': 'ok'}, 'finish_reason': 'stop'}
              ]
            },
            '[DONE]'
          ]),
          const {},
        ),
      ]);
      final client = OpenAiCompatClient(providerId: 'groq', baseUrl: 'https://x/v1', apiKey: 'k', httpClientFactory: server.client);
      final (text, _) = await collect(client.stream(request('m')));
      expect(text, 'ok');
      expect(server.requests.length, 2);
    });
  });

  group('AnthropicClient', () {
    List<Map<String, dynamic>> toolTurnEvents() => [
          {'type': 'message_start', 'message': {'id': 'msg_1', 'model': 'claude-opus-5'}},
          {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}},
          {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'THINKSIG'}},
          {'type': 'content_block_stop', 'index': 0},
          {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'text', 'text': ''}},
          {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'Let me check. '}},
          {'type': 'content_block_stop', 'index': 1},
          {'type': 'ping'},
          {
            'type': 'content_block_start',
            'index': 2,
            'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': 'get_weather', 'input': {}}
          },
          {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': '{"loca'}},
          {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': 'tion": "Pune"}'}},
          {'type': 'content_block_stop', 'index': 2},
          {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}, 'usage': {'output_tokens': 40}},
          {'type': 'message_stop'},
        ];

    test('parses tool_use, keeps thinking blocks for replay', () async {
      final server = _Server([(200, sse(toolTurnEvents(), named: true), const {})]);
      final client = AnthropicClient(apiKey: 'sk-ant', httpClientFactory: server.client);
      final (text, turn) = await collect(client.stream(request('claude-opus-5')));

      expect(text, 'Let me check. ');
      expect(turn.stopReason, LlmStopReason.toolUse);
      expect(turn.toolCalls.single.id, 'toolu_1');
      expect(turn.toolCalls.single.args, {'location': 'Pune'});
      final blocks = turn.native as List;
      expect(blocks.first['type'], 'thinking');
      expect(blocks.first['signature'], 'THINKSIG');
      expect(blocks.last['input'], {'location': 'Pune'});

      final req = server.requests.single;
      expect(req.headers['x-api-key'], 'sk-ant');
      expect(req.headers['anthropic-version'], '2023-06-01');
      expect(req.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      final body = server.jsonBody(0);
      expect(body['fallbacks'], 'default');
      expect(body['stream'], isTrue);
      expect(body['tools'][0]['eager_input_streaming'], isTrue);
      expect(body.containsKey('output_config'), isFalse, reason: 'effort only when the model supports it');
    });

    test('refusal and malformed tool input are surfaced, not executed', () async {
      final server = _Server([
        (
          200,
          sse([
            {'type': 'message_start', 'message': {'id': 'm'}},
            {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 't1', 'name': 'get_weather', 'input': {}}},
            {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"location": "Pu'}},
            {'type': 'content_block_stop', 'index': 0},
            {'type': 'message_delta', 'delta': {'stop_reason': 'refusal', 'stop_details': {'type': 'refusal', 'category': 'cyber'}}},
          ], named: true),
          const {},
        ),
      ]);
      final client = AnthropicClient(apiKey: 'k', httpClientFactory: server.client);
      final (_, turn) = await collect(client.stream(request('claude-haiku-4-5')));
      expect(turn.stopReason, LlmStopReason.refusal);
      expect(turn.detail, 'cyber');
      expect(turn.toolCalls.single.invalidArgs, '{"location": "Pu');
      expect(server.requests.single.headers.containsKey('anthropic-beta'), isFalse);
      expect(server.jsonBody(0).containsKey('fallbacks'), isFalse);
    });

    test('echoableContent drops blocks from a declined attempt', () {
      final out = AnthropicClient.echoableContent([
        {'type': 'thinking', 'thinking': '', 'signature': 'old'},
        {'type': 'text', 'text': 'Partial '},
        {'type': 'tool_use', 'id': 'x', 'name': 'n', 'input': {}},
        {'type': 'fallback', 'from': {'model': 'a'}, 'to': {'model': 'b'}},
        {'type': 'text', 'text': 'continued'},
        {'type': 'tool_use', 'id': 'y', 'name': 'n', 'input': {}},
      ]);
      expect(out.map((b) => b['type']), ['text', 'text', 'tool_use']);
      expect(out.last['id'], 'y');
    });

    test('body merges tool results and trims leading assistant turns', () {
      final client = AnthropicClient(apiKey: 'k', supportsEffort: true, modelMaxOutputTokens: 32000);
      final body = client.buildBody(request('claude-sonnet-5', messages: [
        LlmMessage.assistant('stray greeting'),
        LlmMessage.user('hi'),
        LlmMessage.assistant('', toolCalls: const [LlmToolCall(id: 't1', name: 'get_date_time', args: {})]),
        LlmMessage.toolResults(const [
          LlmToolResult(callId: 't1', name: 'get_date_time', output: {'error': 'boom'}, isError: true),
        ]),
        LlmMessage.user('and now?'),
      ]));
      final messages = body['messages'] as List;
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      final last = messages.last['content'] as List;
      expect(last[0]['type'], 'tool_result');
      expect(last[0]['is_error'], isTrue);
      expect(last[1], {'type': 'text', 'text': 'and now?'});
      expect(body['max_tokens'], 32000);
      expect(body['output_config'], {'effort': 'low'});
    });

    test('retries overloaded responses and maps auth errors', () async {
      final server = _Server([
        (529, jsonEncode({'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'Overloaded'}}), const {'retry-after': '0'}),
        (
          200,
          sse([
            {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': 'hi'}},
            {'type': 'content_block_stop', 'index': 0},
            {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}},
          ], named: true),
          const {},
        ),
        (401, jsonEncode({'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}), const {}),
      ]);
      final client = AnthropicClient(apiKey: 'k', httpClientFactory: server.client);
      final (text, turn) = await collect(client.stream(request('claude-haiku-4-5')));
      expect(text, 'hi');
      expect(turn.stopReason, LlmStopReason.end);
      await expectLater(
        client.listModels(),
        throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.auth)),
      );
    });

    test('listModels reads capabilities', () async {
      final server = _Server([
        (
          200,
          jsonEncode({
            'data': [
              {
                'id': 'claude-opus-5',
                'display_name': 'Claude Opus 5',
                'max_tokens': 128000,
                'capabilities': {
                  'image_input': {'supported': true},
                  'effort': {'supported': true},
                }
              },
              {
                'id': 'claude-haiku-4-5',
                'display_name': 'Claude Haiku 4.5',
                'max_tokens': 64000,
                'capabilities': {
                  'image_input': {'supported': true},
                  'effort': {'supported': false},
                }
              },
            ],
            'has_more': false,
          }),
          const {'content-type': 'application/json'},
        ),
      ]);
      final client = AnthropicClient(apiKey: 'k', httpClientFactory: server.client);
      final models = await client.listModels();
      expect(models.map((m) => m.supportsEffort), [true, false]);
      expect(models.first.maxOutputTokens, 128000);
    });
  });

  test('SSE parser handles comments, multi-line data and CRLF', () async {
    const raw = ': keep-alive\r\nevent: x\r\ndata: line1\r\ndata: line2\r\n\r\ndata: {"a":1}\n\n';
    final events = await parseSse(Stream.value(utf8.encode(raw))).toList();
    expect(events.map((e) => e.data), ['line1\nline2', '{"a":1}']);
    expect(events.first.event, 'x');
  });
}
