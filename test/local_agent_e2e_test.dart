// End-to-end check of the on-device agent with a real GGUF model and real
// web search. Skipped unless a model is available:
//
//   flutter test test/local_agent_e2e_test.dart \
//     --dart-define=LOCAL_MODEL_DIR=/path/to/models \
//     --dart-define=LOCAL_MODEL_FILE=gemma-4-E2B_q4_0-it.gguf
@Tags(['model'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/agent/agent_types.dart';
import 'package:local_agent/services/agent/local_agent.dart';
import 'package:local_agent/services/local/local_model.dart';
import 'package:local_agent/services/model_downloader_service.dart';
import 'package:local_agent/services/tools/tool_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Sink implements AgentEventSink {
  final events = <String>[];
  @override
  void status(String text) => events.add('status:$text');
  @override
  void partial(String text) => events.add('partial');
  @override
  void clear() => events.add('clear');
}

void main() {
  const dirDefine = String.fromEnvironment('LOCAL_MODEL_DIR');
  const fileDefine = String.fromEnvironment('LOCAL_MODEL_FILE');
  final dir = dirDefine.isEmpty ? Platform.environment['LOCAL_MODEL_DIR'] : dirDefine;
  final file = fileDefine.isEmpty ? 'gemma-4-E2B_q4_0-it.gguf' : fileDefine;
  final path = dir == null ? null : '$dir/$file';
  final available = path != null && File(path).existsSync();

  group('LocalAgent end-to-end', skip: available ? false : 'set LOCAL_MODEL_DIR to run', () {
    late LocalAgent agent;
    final executed = <String>[];
    const context = ToolContext(confirmSensitive: false);

    setUpAll(() async {
      // ignore: avoid_print
      LocalAgent.debugLog = (m) => print('  [agent] $m');
      SharedPreferences.setMockInitialValues({});
      ModelDownloaderService.debugModelsDirectory = dir;
      agent = LocalAgent(executeTool: (name, args, ctx) async {
        executed.add('$name$args');
        // Lookups hit the real network; phone actions are faked (no Android).
        if (name == 'search_web' || name == 'get_weather' || name == 'get_date_time') {
          return ToolRuntime.instance.execute(name, args, context: ctx);
        }
        if (name == 'set_timer') return {'success': true, 'seconds': args['seconds']};
        if (name == 'toggle_flashlight') return {'success': true, 'on': args['on']};
        return {'success': true};
      });
      await agent.load(LocalModel(
        id: 'e2e',
        name: 'E2E model',
        repo: 'local/e2e',
        revision: 'main',
        file: file,
        sizeBytes: File(path!).lengthSync(),
        toolUse: ToolUse.full,
        sampling: const SamplingDefaults(temperature: 0.7, topK: 40, topP: 0.95, minP: 0),
        curated: true,
      ));
    });

    tearDownAll(() async => agent.unload());
    setUp(executed.clear);

    test('searches the web and answers from the results', () async {
      final sink = _Sink();
      final reply = await agent.run(
        'Who won the most recent Formula 1 race?',
        sink: sink,
        toolContext: context,
      );
      // ignore: avoid_print
      print('F1 → tools: $executed\n     reply (${reply.seconds}s, ${reply.tokensPerSecond?.toStringAsFixed(1)} tok/s): ${reply.text}');
      expect(reply.isError, isFalse);
      expect(executed.any((e) => e.startsWith('search_web')), isTrue);
      expect(reply.toolsUsed, contains('search_web'));
      expect(reply.text.trim().length, greaterThan(20));
      expect(reply.text, isNot(contains('<tool_call')));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('phone actions reply directly after the tool runs', () async {
      final reply = await agent.run('set a timer for 10 minutes', sink: _Sink(), toolContext: context);
      // ignore: avoid_print
      print('timer → tools: $executed\n        reply: ${reply.text}');
      expect(executed.single, startsWith('set_timer'));
      expect(reply.text, 'Timer set for 10 minutes.');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('answers general questions without tools', () async {
      final reply = await agent.run('What is 17 times 23? Just the number.', sink: _Sink(), toolContext: context);
      // ignore: avoid_print
      print('math → tools: $executed\n       reply: ${reply.text}');
      expect(executed, isEmpty);
      expect(reply.text, contains('391'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('stop returns promptly with partial text', () async {
      final sink = _Sink();
      final future = agent.run(
        'Write a long, detailed essay about the history of the ocean. At least 500 words.',
        sink: sink,
        toolContext: context,
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      final sw = Stopwatch()..start();
      await agent.stop();
      final reply = await future;
      // ignore: avoid_print
      print('stop → returned ${sw.elapsedMilliseconds} ms after stop: ${reply.text.length} chars');
      expect(reply.stopped, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
