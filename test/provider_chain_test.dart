import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/llm/provider_config.dart';

void main() {
  group('ProviderConfig.modelChain', () {
    test('primary first, fallbacks deduped and ordered', () {
      const config = ProviderConfig(
        provider: LlmProvider.groq,
        apiKey: 'test',
        baseUrl: 'https://example.test/v1',
        model: 'openai/gpt-oss-20b',
        fallbackModels: [
          'openai/gpt-oss-120b',
          'openai/gpt-oss-20b', // duplicate of primary
          'qwen/qwen3.8-27b',
        ],
      );
      expect(config.modelChain, [
        'openai/gpt-oss-20b',
        'openai/gpt-oss-120b',
        'qwen/qwen3.8-27b',
      ]);
    });

    test('blank entries are ignored', () {
      const config = ProviderConfig(
        provider: LlmProvider.custom,
        apiKey: 'test',
        baseUrl: 'https://example.test/v1',
        model: 'my-model',
        fallbackModels: ['', '  '],
      );
      expect(config.modelChain, ['my-model']);
    });
  });

  test('Groq ships a model that its free tier actually serves', () {
    final spec = kProviderSpecs[LlmProvider.groq]!;
    // Verified against a live key: llama-3.3-70b-versatile 403s, gpt-oss-20b
    // calls tools. This test pins the default so a copy-paste from a tutorial
    // cannot silently break new installs.
    expect(spec.defaultModel, 'openai/gpt-oss-20b');
    expect(spec.fallbackModels, isNotEmpty);
    expect(spec.baseUrl, contains('groq.com'));
  });
}
