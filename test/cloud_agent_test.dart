import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/agent/agent_types.dart';
import 'package:local_agent/services/agent/cloud_agent.dart';
import 'package:local_agent/services/llm/llm_types.dart';
import 'package:local_agent/services/llm/providers.dart';
import 'package:local_agent/services/tools/tool_runtime.dart';

/// Replays scripted turns and records every request it receives.
class FakeClient implements LlmClient {
  final List<Object> script; // LlmTurn, or LlmException to throw
  final List<LlmRequest> requests = [];
  final Completer<void>? hold;
  FakeClient(this.script, {this.hold});

  @override
  String get providerId => 'fake';

  @override
  Stream<LlmEvent> stream(LlmRequest request, {CancelToken? cancel}) async* {
    requests.add(request);
    final next = script[requests.length - 1];
    if (next is LlmException) throw next;
    final turn = next as LlmTurn;
    if (turn.text.isNotEmpty) yield LlmTextDelta(turn.text);
    if (hold != null) {
      await Future.any([hold!.future, Future.delayed(const Duration(seconds: 5))]);
      if (cancel?.isCancelled ?? false) {
        throw const LlmException(LlmErrorKind.cancelled, 'Cancelled');
      }
    }
    yield LlmDone(turn);
  }

  @override
  Future<List<LlmModelInfo>> listModels({CancelToken? cancel}) async => const [];
}

class RecordingSink implements AgentEventSink {
  final List<String> events = [];
  @override
  void status(String text) => events.add('status:$text');
  @override
  void partial(String text) => events.add('partial:$text');
  @override
  void clear() => events.add('clear');
}

LlmTurn text(String t) => LlmTurn(text: t, toolCalls: const [], stopReason: LlmStopReason.end);
LlmTurn calls(List<LlmToolCall> c, {String text = '', LlmStopReason stop = LlmStopReason.toolUse}) =>
    LlmTurn(text: text, toolCalls: c, stopReason: stop);

void main() {
  const config = CloudConfig(providerId: 'gemini', model: 'gemini-flash-latest');
  final executed = <String>[];

  CloudAgent agent(FakeClient client) => CloudAgent(
        client: client,
        config: config,
        clock: () => DateTime(2026, 9, 24, 14, 5),
        executeTool: (name, args, context) async {
          executed.add('$name$args');
          if (name == 'get_weather') return {'temperatureC': 30, 'location': args['location']};
          return {'ok': true};
        },
      );

  setUp(executed.clear);

  test('plain answer is returned and remembered as text history', () async {
    final client = FakeClient([text('Paris.'), text('About 2.1 million.')]);
    final a = agent(client);
    final sink = RecordingSink();
    final r1 = await a.run('Capital of France?', sink: sink, toolContext: const ToolContext());
    expect(r1.text, 'Paris.');
    expect(r1.modelLabel, config.label);
    expect(sink.events, contains('partial:Paris.'));

    await a.run('Population?', sink: sink, toolContext: const ToolContext());
    final history = client.requests.last.messages;
    expect(history.map((m) => m.role), [LlmRole.user, LlmRole.assistant, LlmRole.user]);
    expect(history[1].text, 'Paris.');
    expect(client.requests.last.system, contains('Thursday, 24 September 2026'));
  });

  test('parallel tool calls are all answered in one message', () async {
    final client = FakeClient([
      calls(const [
        LlmToolCall(id: 'a', name: 'get_weather', args: {'location': 'Pune'}),
        LlmToolCall(id: 'b', name: 'get_date_time', args: {}),
      ], text: 'Let me look.'),
      text('It is 30°C in Pune.'),
    ]);
    final sink = RecordingSink();
    final reply = await agent(client).run('Weather and time?', sink: sink, toolContext: const ToolContext());

    expect(reply.text, 'It is 30°C in Pune.');
    expect(reply.toolsUsed, ['get_weather', 'get_date_time']);
    expect(executed, ['get_weather{location: Pune}', 'get_date_time{}']);
    final second = client.requests[1].messages;
    expect(second.map((m) => m.role), [LlmRole.user, LlmRole.assistant, LlmRole.tool]);
    expect(second.last.toolResults.map((r) => r.callId), ['a', 'b']);
    expect(sink.events, contains('clear'), reason: 'preamble text is cleared before tools run');
  });

  test('invalid tool JSON is reported back instead of executed', () async {
    final client = FakeClient([
      calls(const [LlmToolCall(id: 'x', name: 'get_weather', args: {}, invalidArgs: '{"location": Pu')]),
      text('Sorry, which city?'),
    ]);
    final reply = await agent(client).run('Weather?', sink: RecordingSink(), toolContext: const ToolContext());
    expect(executed, isEmpty);
    final result = client.requests[1].messages.last.toolResults.single;
    expect(result.isError, isTrue);
    expect(result.output, {'INVALID_JSON': '{"location": Pu'});
    expect(reply.text, 'Sorry, which city?');
  });

  test('refusals and truncated tool turns never run tools', () async {
    var r = await agent(FakeClient([
      calls(const [LlmToolCall(id: 'x', name: 'get_weather', args: {'location': 'A'})],
          stop: LlmStopReason.refusal),
    ])).run('x', sink: RecordingSink(), toolContext: const ToolContext());
    expect(r.isError, isTrue);
    expect(executed, isEmpty);

    r = await agent(FakeClient([
      calls(const [LlmToolCall(id: 'x', name: 'get_weather', args: {'location': 'A'})],
          stop: LlmStopReason.maxTokens),
    ])).run('x', sink: RecordingSink(), toolContext: const ToolContext());
    expect(r.isError, isTrue);
    expect(executed, isEmpty);
  });

  test('provider errors become readable replies and are not remembered', () async {
    final client = FakeClient([
      const LlmException(LlmErrorKind.auth, 'bad key'),
      text('ok'),
    ]);
    final a = agent(client);
    final r = await a.run('hi', sink: RecordingSink(), toolContext: const ToolContext());
    expect(r.isError, isTrue);
    expect(r.text, contains('API key was rejected'));
    await a.run('again', sink: RecordingSink(), toolContext: const ToolContext());
    expect(client.requests.last.messages.length, 1, reason: 'failed turn left no history');
  });

  test('stop returns the partial text', () async {
    final hold = Completer<void>();
    final client = FakeClient([text('Partial answer')], hold: hold);
    final a = agent(client);
    final future = a.run('long question', sink: RecordingSink(), toolContext: const ToolContext());
    await Future.delayed(const Duration(milliseconds: 20));
    a.stop();
    hold.complete();
    final r = await future;
    expect(r.stopped, isTrue);
    expect(r.text, 'Partial answer');
  });

  test('gives up after the step limit', () async {
    final loop = List<Object>.generate(
      CloudAgent.maxSteps,
      (i) => calls([LlmToolCall(id: 'c$i', name: 'get_date_time', args: const {})]),
    );
    final r = await agent(FakeClient(loop)).run('loop', sink: RecordingSink(), toolContext: const ToolContext());
    expect(r.isError, isTrue);
    expect(executed.length, CloudAgent.maxSteps);
  });

  test('mimeTypeForPath', () {
    expect(mimeTypeForPath('/a/b.PNG'), 'image/png');
    expect(mimeTypeForPath('/a/b.jpeg'), 'image/jpeg');
    expect(mimeTypeForPath('/a/b.webp'), 'image/webp');
  });
}
