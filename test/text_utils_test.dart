import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/agent/text_utils.dart';

void main() {
  const tools = {'get_weather', 'toggle_flashlight', 'set_timer'};

  group('extractToolCallFromText', () {
    test('plain JSON with parameters', () {
      final c = extractToolCallFromText('{"name": "toggle_flashlight", "parameters": {"on": true}}', tools);
      expect(c?.name, 'toggle_flashlight');
      expect(c?.args, {'on': true});
    });

    test('JSON wrapped in prose and a code fence, with arguments', () {
      final c = extractToolCallFromText(
        'Sure! I\'ll check.\n```json\n{"name":"get_weather","arguments":{"location":"Pune"}}\n```',
        tools,
      );
      expect(c?.name, 'get_weather');
      expect(c?.args, {'location': 'Pune'});
    });

    test('stringified arguments and nested function wrapper', () {
      final c = extractToolCallFromText(
        '{"function": {"name": "set_timer", "arguments": "{\\"seconds\\": 60}"}}',
        tools,
      );
      expect(c?.name, 'set_timer');
      expect(c?.args, {'seconds': 60});
    });

    test('ignores unknown tools and non-calls', () {
      expect(extractToolCallFromText('{"name": "rm_rf", "parameters": {}}', tools), isNull);
      expect(extractToolCallFromText('The JSON format is {"a": 1}', tools), isNull);
      expect(extractToolCallFromText('No braces here', tools), isNull);
      expect(extractToolCallFromText('{"name": "get_weather"', tools), isNull, reason: 'unbalanced');
    });

    test('braces inside strings do not break balancing', () {
      final c = extractToolCallFromText('{"name": "get_weather", "parameters": {"location": "a}b{c"}}', tools);
      expect(c?.args['location'], 'a}b{c');
    });
  });

  test('visiblePrefix hides tool-call markup while streaming', () {
    expect(visiblePrefix('{"name": "get_'), '');
    expect(visiblePrefix('<tool_call>{"na'), '');
    expect(visiblePrefix('Let me check.<|tool_call>call:get_weather{'), 'Let me check.');
    expect(visiblePrefix('Sure, here it is: {"name": "x"'), 'Sure, here it is: ');
    expect(visiblePrefix('Plain answer.'), 'Plain answer.');
  });

  test('cleanModelText strips control tokens and think blocks', () {
    expect(cleanModelText('<think>hmm</think>Hello<|im_end|>'), 'Hello');
    expect(cleanModelText('Hi<end_of_turn>'), 'Hi');
    expect(cleanModelText('A<tool_call>{"x":1}</tool_call>B'), 'AB');
  });

  test('degenerate output detection', () {
    expect(isDegenerateOutput(''), isTrue);
    expect(isDegenerateOutput('\n\n\n'), isTrue);
    expect(isDegenerateOutput('aaaaaaaaaaaaaaaa'), isTrue);
    expect(isDegenerateOutput(List.filled(40, 'the').join(' ')), isTrue);
    expect(isDegenerateOutput('Your battery is at 80% and charging.'), isFalse);
  });

  test('loop detection on repeating tails only', () {
    expect(isStuckInLoop('190 ' * 60), isTrue);
    expect(isStuckInLoop('This tool lets you choose. ' * 10), isTrue);
    final normal = List.generate(40, (i) => 'word$i').join(' ');
    expect(isStuckInLoop(normal), isFalse);
    expect(isStuckInLoop('short'), isFalse);
  });

  test('stripForSpeech removes markdown and links', () {
    const md = '## Weather\n**It\'s 30°C** in *Chennai*. See [the forecast](https://x.y/z).\n- Rain: 20%\n1. Stay cool';
    final spoken = stripForSpeech(md);
    expect(spoken, isNot(contains('**')));
    expect(spoken, isNot(contains('##')));
    expect(spoken, isNot(contains('https')));
    expect(spoken, contains('30 degrees'));
    expect(spoken, contains('the forecast'));
    expect(spoken, contains('Rain: 20%'));
  });

  test('splitForSpeech keeps chunks under the limit', () {
    final text = List.generate(30, (i) => 'Sentence number $i is here.').join(' ');
    final chunks = splitForSpeech(text, maxChars: 100);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 100), isTrue);
    expect(chunks.join(' ').replaceAll(' ', ''), text.replaceAll(' ', ''));
    expect(splitForSpeech(''), isEmpty);
  });

  test('estimateTokens is conservative', () {
    expect(estimateTokens('abcd' * 100), greaterThanOrEqualTo(100));
  });
}
