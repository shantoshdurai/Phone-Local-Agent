import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:local_agent/services/agent/local_agent.dart';
import 'package:local_agent/services/local/device_profile.dart';
import 'package:local_agent/services/local/hf_hub.dart';
import 'package:local_agent/services/local/inference_settings.dart';
import 'package:local_agent/services/local/local_engine.dart';
import 'package:local_agent/services/local/local_model.dart';
import 'package:local_agent/services/local/model_catalog.dart';
import 'package:local_agent/services/tools/tool_catalog.dart';

dynamic fixtureJson(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync());

void main() {
  group('file names', () {
    test('quantisation', () {
      expect(quantFromFileName('Qwen3.5-0.8B-Q4_K_M.gguf'), 'Q4_K_M');
      expect(quantFromFileName('Qwen3.5-0.8B-UD-Q4_K_XL.gguf'), 'UD-Q4_K_XL');
      expect(quantFromFileName('gemma-4-E2B_q4_0-it.gguf'), 'Q4_0');
      expect(quantFromFileName('model.IQ4_XS.gguf'), 'IQ4_XS');
      expect(quantFromFileName('Qwen3.5-0.8B-BF16.gguf'), 'BF16');
      expect(quantFromFileName('weird.gguf'), isNull);
    });

    test('parameter count', () {
      expect(paramsFromName('Qwen3.5-0.8B-GGUF'), 0.8);
      expect(paramsFromName('gemma-4-E2B-it-qat-q4_0-gguf'), 2);
      expect(paramsFromName('LFM2.5-8B-A1B-GGUF'), 8);
      expect(paramsFromName('SmolLM2-135M-Instruct'), 0.135);
      expect(paramsFromName('MiniCPM5-2B-GGUF'), 2);
      expect(paramsFromName('Phi-4-mini'), isNull);
    });

    test('hub files are prefixed so repos cannot collide', () {
      const hub = LocalModel(
        id: 'a/b-GGUF/model-Q4_K_M.gguf',
        name: 'x',
        repo: 'a/b-GGUF',
        revision: 'main',
        file: 'model-Q4_K_M.gguf',
        sizeBytes: 1,
        mmprojFile: 'mmproj-F16.gguf',
        mmprojSizeBytes: 1,
      );
      expect(hub.localFileName, 'a_b-GGUF__model-Q4_K_M.gguf');
      expect(hub.localMmprojName, 'a_b-GGUF__mmproj-F16.gguf');
      expect(ModelCatalog.qwen35Small.localFileName, 'Qwen3.5-0.8B-Q4_K_M.gguf');
    });

    test('hub model JSON round-trip', () {
      final m = LocalModel.fromJson(jsonDecode(jsonEncode(ModelCatalog.qwen35Small.toJson())))!;
      expect(m.file, ModelCatalog.qwen35Small.file);
      expect(m.mmprojSizeBytes, ModelCatalog.qwen35Small.mmprojSizeBytes);
      expect(m.sampling.presencePenalty, 1.5);
      expect(m.toolUse, ToolUse.lookups);
      expect(LocalModel.fromJson({'id': 'x'}), isNull);
    });
  });

  group('device profile', () {
    test('meminfo', () {
      final m = DeviceProfile.parseMeminfo('MemTotal:        7765432 kB\nMemFree:  1 kB\nMemAvailable:    3123456 kB\n')!;
      expect(m.total, 7765432 * 1024);
      expect(m.available, 3123456 * 1024);
      expect(DeviceProfile.parseMeminfo('garbage'), isNull);
    });

    test('cpu features and big cores', () {
      const cpuinfo = 'processor\t: 0\nBogoMIPS\t: 26.00\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp\n';
      final f = DeviceProfile.parseCpuFeatures(cpuinfo);
      expect(f, contains('asimddp'));
      expect(f, isNot(contains('i8mm')));
      // Dimensity 700: 2x A76 (capacity 1024) + 6x A55 (~420).
      expect(DeviceProfile.bigCoreCount(capacities: [420, 420, 420, 420, 420, 420, 1024, 1024], frequenciesKHz: [], cores: 8), 2);
      expect(DeviceProfile.bigCoreCount(capacities: [], frequenciesKHz: [2000000, 2000000, 2200000, 2200000], cores: 4), 4);
      expect(DeviceProfile.classify(features: f, bigCores: 2, maxGHz: 2.2), PerfClass.mid);
      expect(DeviceProfile.classify(features: {'asimddp', 'i8mm'}, bigCores: 4, maxGHz: 3.3), PerfClass.flagship);
      expect(DeviceProfile.classify(features: {}, bigCores: 4, maxGHz: 2.0), PerfClass.low);
    });

    test('gpu names', () {
      expect(DeviceProfile.prettyGpuName('Adreno740v2'), 'Adreno 740');
      expect(DeviceProfile.prettyGpuName('Mali-G57 2 cores r0p1 0x9093'), 'Mali-G57 MC2');
    });

    test('memory fit and marketed size', () {
      const phone = DeviceProfile(totalRamBytes: 7765432 * 1024, cpuFeatures: {'asimddp'});
      expect(phone.marketedRamGB, 8);
      expect(phone.usableForAiGB, closeTo(5.2, 0.2));
      expect(phone.fitOf(ModelCatalog.qwen35Small), ModelFit.good);
      expect(phone.fitOf(ModelCatalog.gemma4Large), ModelFit.tooBig);
      // Estimates scale with the weights read per token.
      expect(phone.estimateTokensPerSecond(ModelCatalog.qwen35Small),
          greaterThan(phone.estimateTokensPerSecond(ModelCatalog.miniCpm)));
    });
  });

  group('inference settings', () {
    test('defaults come from the model card', () {
      final s = InferenceSettings.defaultsFor(ModelCatalog.miniCpm);
      expect(s.temperature, 1.0);
      expect(s.minP, 0);
      expect(s.repeatPenalty, 1.05);
      expect(s.contextSize, 4096);
    });

    test('low-memory phones get a smaller context', () {
      const tiny = DeviceProfile(totalRamBytes: 3 * 1024 * 1024 * 1024);
      expect(InferenceSettings.defaultsFor(ModelCatalog.miniCpm, tiny).contextSize, 2048);
    });

    test('stored values are clamped and reload is detected', () {
      final d = InferenceSettings.defaultsFor(ModelCatalog.gemma4);
      final s = InferenceSettings.fromJson({'temperature': 9, 'contextSize': 99, 'useGpu': true}, d);
      expect(s.temperature, 2);
      expect(s.contextSize, InferenceSettings.minContext);
      expect(s.needsReloadComparedTo(d), isTrue);
      expect(d.copyWith(temperature: 0.2).needsReloadComparedTo(d), isFalse);
    });
  });

  group('Hugging Face hub', () {
    test('search drops uncensored repos and keeps chat models', () {
      final results = HfHubClient.parseSearch(fixtureJson('hf_search_qwen35.json'));
      final repos = results.map((r) => r.repo).toList();
      expect(repos, contains('unsloth/Qwen3.5-2B-GGUF'));
      expect(repos.any((r) => r.toLowerCase().contains('uncensored')), isFalse);
      expect(repos.any((r) => r.toLowerCase().contains('heretic')), isFalse);
      final small = results.firstWhere((r) => r.repo == 'unsloth/Qwen3.5-2B-GGUF');
      expect(small.paramsB, 2);
      expect(small.vision, isTrue);
    });

    test('search skips image generators', () {
      final results = HfHubClient.parseSearch([
        {'id': 'x/Qwen-Image-2.1-GGUF', 'pipeline_tag': 'text-to-image', 'tags': ['gguf']},
        {'id': 'x/Flux-GGUF', 'tags': ['gguf', 'comfyui']},
        {'id': 'x/Chat-1B-GGUF', 'pipeline_tag': 'text-generation', 'tags': ['gguf']},
      ]);
      expect(results.map((r) => r.repo), ['x/Chat-1B-GGUF']);
    });

    test('repo files, default quant and projector', () {
      final d = HfHubClient.parseDetails(fixtureJson('hf_repo_qwen35_08b.json'));
      expect(d.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(d.models.any((f) => f.fileName.contains('mmproj')), isFalse);
      expect(d.models.any((f) => f.fileName.contains('imatrix')), isFalse);
      expect(d.projectors, isNotEmpty);
      expect(HfHubClient.pickDefault(d.models, usableGB: 5)!.quant, 'Q4_K_M');
      expect(HfHubClient.pickProjector(d.projectors)!.fileName, 'mmproj-F16.gguf');

      final model = HfHubClient.toLocalModel(d, HfHubClient.pickDefault(d.models, usableGB: 5)!,
          projector: HfHubClient.pickProjector(d.projectors));
      expect(model.name, 'Qwen3.5-0.8B · Q4_K_M');
      expect(model.toolUse, ToolUse.lookups, reason: 'sub-2B models only get lookups');
      expect(model.supportsVision, isTrue);
      expect(model.downloadUrl, contains('/resolve/${d.revision}/Qwen3.5-0.8B-Q4_K_M.gguf'));
    });

    test('split GGUF parts are skipped', () {
      final d = HfHubClient.parseDetails({
        'id': 'x/y',
        'sha': 'abc',
        'siblings': [
          {'rfilename': 'big-Q4_K_M-00001-of-00002.gguf', 'size': 5},
          {'rfilename': 'small-Q4_K_M.gguf', 'size': 3},
        ],
      });
      expect(d.models.map((f) => f.fileName), ['small-Q4_K_M.gguf']);
    });
  });

  group('llama.cpp glue', () {
    test('catalog schemas become typed tool declarations', () {
      final def = LocalAgent.toToolDefinition(kToolsByName['play_media']!);
      final schema = def.toJsonSchema();
      expect(schema['required'], ['query']);
      expect((schema['properties'] as Map)['app']['enum'], ['youtube', 'youtube_music', 'spotify']);
      final alarm = LocalAgent.toToolDefinition(kToolsByName['set_alarm']!).toJsonSchema();
      expect((alarm['properties'] as Map)['hour']['type'], 'integer');
    });

    test('tool turns render in the shape chat templates expect', () {
      const call = ToolCallTurn([
        LlamaToolCallContent(id: 'c1', name: 'get_weather', arguments: {'location': 'Pune'}, rawJson: '{"location":"Pune"}'),
      ]);
      final json = call.toJson();
      final fn = (json['tool_calls'] as List).single['function'] as Map;
      expect(fn['arguments'], {'location': 'Pune'}, reason: 'Gemma 4 requires an object');
      expect(json['role'], 'assistant');

      final result = ToolResultTurn('c1', 'get_weather', '{"temperatureC":30}');
      expect(result.toJson(), {
        'role': 'tool',
        'tool_call_id': 'c1',
        'name': 'get_weather',
        'content': '{"temperatureC":30}',
      });
      expect(result.parts.whereType<LlamaToolResultContent>(), isEmpty);
    });

    test('recurrent architectures skip prompt warm-up', () {
      expect(LocalEngine.isRecurrentArchitecture('qwen35'), isTrue);
      expect(LocalEngine.isRecurrentArchitecture('lfm2'), isTrue);
      expect(LocalEngine.isRecurrentArchitecture('gemma4'), isFalse);
      expect(LocalEngine.isRecurrentArchitecture('qwen3'), isFalse);
      expect(LocalEngine.isRecurrentArchitecture(null), isFalse);
    });
  });
}
