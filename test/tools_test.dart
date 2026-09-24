import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/app_service.dart';
import 'package:local_agent/services/llm/llm_types.dart';
import 'package:local_agent/services/llm/providers.dart';
import 'package:local_agent/services/local/device_profile.dart';
import 'package:local_agent/services/local/model_catalog.dart';
import 'package:local_agent/services/tools/tool_args.dart';
import 'package:local_agent/services/tools/tool_catalog.dart';
import 'package:local_agent/services/tools/tool_runtime.dart';
import 'package:local_agent/services/utility_service.dart';

void main() {
  group('tool args', () {
    test('lenient coercion', () {
      final args = {'b': 'true', 'n': '7', 'd': 7.6, 's': 42, 'p': '50%', 'f': 0.3, 'big': 80, 'x': []};
      expect(argBool(args, 'b'), isTrue);
      expect(argBool({'v': 'off'}, 'v'), isFalse);
      expect(argInt(args, 'n'), 7);
      expect(argInt(args, 'd'), 8);
      expect(argString(args, 's'), '42');
      expect(argString({'e': '  '}, 'e'), isNull);
      expect(argFraction(args, 'p'), 0.5);
      expect(argFraction(args, 'f'), 0.3);
      expect(argFraction(args, 'big'), 0.8);
      expect(argInt(args, 'x'), isNull);
      expect(argBool({'v': 'maybe'}, 'v'), isNull);
    });
  });

  group('catalog', () {
    test('names are unique and required params are declared', () {
      final names = kToolCatalog.map((t) => t.name).toList();
      expect(names.toSet().length, names.length);
      for (final t in kToolCatalog) {
        final props = (t.parameters['properties'] as Map).keys.toSet();
        expect(props.containsAll(t.requiredParams), isTrue, reason: t.name);
        expect(t.description, isNotEmpty);
        expect(t.localDescription.length, lessThan(t.description.length + 1));
      }
    });

    test('budgets keep core tools and grow in tier order', () {
      final small = selectToolsForBudget(3).map((t) => t.name).toList();
      final core = kToolCatalog.where((t) => t.tier == ToolTier.core).map((t) => t.name);
      expect(small, containsAll(core), reason: 'core tools are never dropped');
      final ten = selectToolsForBudget(10);
      expect(ten.length, 10);
      expect(ten.take(core.length).every((t) => t.tier == ToolTier.core), isTrue);
      expect(selectToolsForBudget(99).length, kToolCatalog.length);
    });

    test('a 14-tool budget covers messaging and everyday actions', () {
      final names = selectToolsForBudget(14).map((t) => t.name).toSet();
      expect(names, containsAll(['search_contacts', 'send_whatsapp', 'send_sms', 'make_phone_call',
          'set_timer', 'set_alarm', 'play_media', 'search_web']));
      expect(lookupTools().map((t) => t.name), containsAll(['search_web', 'get_weather', 'recall_memory']));
    });
  });

  group('runtime', () {
    test('rejects unknown tools and missing arguments without running anything', () async {
      final unknown = await ToolRuntime.instance.execute('format_disk', {});
      expect(unknown['error'], contains('Unknown tool'));
      final missing = await ToolRuntime.instance.execute('set_alarm', {'hour': 7});
      expect(missing['error'], contains('minute'));
    });

    test('sensitive tools ask first and honour a refusal', () async {
      ToolConfirmation? asked;
      final result = await ToolRuntime.instance.execute(
        'make_phone_call',
        {'phone': '+911234567890'},
        context: ToolContext(confirm: (r) async {
          asked = r;
          return false;
        }),
      );
      expect(asked?.title, 'Call +911234567890?');
      expect(result['cancelled'], isTrue);
      expect(ToolRuntime.formatDirect('make_phone_call', {}, result), "Okay, I didn't do that.");
    });

    test('formatDirect renders plain sentences', () {
      expect(ToolRuntime.formatDirect('toggle_flashlight', {}, {'success': true, 'on': false}), 'Flashlight off.');
      expect(ToolRuntime.formatDirect('set_timer', {}, {'success': true, 'seconds': 5400}), 'Timer set for 1 hour 30 minutes.');
      expect(ToolRuntime.formatDirect('set_alarm', {}, {'success': true, 'hour': 18, 'minute': 5}), 'Alarm set for 6:05 PM.');
      expect(
        ToolRuntime.formatDirect('get_device_info', {}, {
          'batteryPercent': 76,
          'charging': true,
          'storageFreeGB': 20.5,
          'storageTotalGB': 128.0,
          'ramTotalGB': 8.0,
        }),
        startsWith('Battery is at 76% and charging.'),
      );
      expect(
        ToolRuntime.formatDirect('get_weather', {}, {
          'location': 'Pune, India',
          'temperatureC': 29,
          'feelsLikeC': 31,
          'condition': 'Partly cloudy',
          'forecast': [
            {'minC': 22, 'maxC': 31, 'rainChancePercent': 40}
          ],
        }),
        "It's 29°C and partly cloudy in Pune, India (feels like 31°C). Today: 22–31°C, 40% chance of rain.",
      );
      expect(ToolRuntime.formatDirect('search_web', {}, {'results': []}), isNull, reason: 'model summarises');
      expect(ToolRuntime.formatDirect('toggle_flashlight', {}, {'error': 'Camera busy.'}), 'Camera busy.');
      expect(
        ToolRuntime.formatDirect('launch_app_by_name', {'appName': 'Instagarm'},
            {'error': 'x', 'suggestions': ['Instagram']}),
        'I couldn\'t find "Instagarm". Did you mean Instagram?',
      );
    });

    test('fitToBudget trims lists but keeps JSON valid', () {
      final big = {
        'results': List.generate(50, (i) => {'title': 'Result $i', 'snippet': 'x' * 100}),
        'query': 'q',
      };
      final fitted = ToolRuntime.fitToBudget(big, 1500);
      expect(jsonEncode(fitted).length, lessThanOrEqualTo(1500));
      expect(fitted['truncated'], isTrue);
      expect((fitted['results'] as List).length, greaterThan(0));
      final small = {'a': 1};
      expect(identical(ToolRuntime.fitToBudget(small, 100), small), isTrue);
    });

    test('date helpers', () {
      final info = ToolRuntime.dateTimeInfo(DateTime(2026, 9, 24, 0, 7));
      expect(info['date'], 'Thursday, 24 September 2026');
      expect(info['time12'], '12:07 AM');
      expect(ToolRuntime.parseLocalDateTime('2026-09-25 17:00'), DateTime(2026, 9, 25, 17));
      expect(ToolRuntime.parseLocalDateTime('tomorrow'), isNull);
      expect(ToolRuntime.describeDuration(61), '1 minute 1 second');
    });

    test('URL normalisation', () {
      expect(UtilityService.normalizeUrl('github.com')?.toString(), 'https://github.com');
      expect(UtilityService.normalizeUrl('http://x.io/a?b=1')?.host, 'x.io');
      expect(UtilityService.normalizeUrl('javascript:alert(1)'), isNull);
      expect(UtilityService.normalizeUrl('not a url'), isNull);
      expect(UtilityService.normalizeUrl('localhost'), isNull);
    });
  });

  group('app name matching', () {
    const apps = [
      ('WhatsApp', 'com.whatsapp'),
      ('WhatsApp Business', 'com.whatsapp.w4b'),
      ('Chrome', 'com.android.chrome'),
      ('Chrome Beta', 'com.chrome.beta'),
      ('Google Maps', 'com.google.android.apps.maps'),
      ('Instagram', 'com.instagram.android'),
      ('In', 'com.example.in'),
      ('Settings', 'com.android.settings'),
    ];

    test('prefers exact and shorter matches', () {
      expect(AppService.bestMatch('whatsapp', apps)?.$1, 'WhatsApp');
      expect(AppService.bestMatch('whats app', apps)?.$1, 'WhatsApp');
      expect(AppService.bestMatch('chrome', apps)?.$1, 'Chrome');
      expect(AppService.bestMatch('maps', apps)?.$1, 'Google Maps');
      expect(AppService.bestMatch('insta', apps)?.$1, 'Instagram');
      expect(AppService.bestMatch('settings app', apps)?.$1, 'Settings');
    });

    test('does not open random apps for vague queries', () {
      expect(AppService.bestMatch('the door', apps), isNull);
      expect(AppService.bestMatch('instagram reels downloader', apps), isNull);
      expect(AppService.bestMatch('a', apps), isNull);
    });
  });

  group('providers', () {
    test('default model prefers what the key can use', () {
      final gemini = providerById('gemini');
      expect(
        pickDefaultModel(gemini, const [LlmModelInfo(id: 'gemini-3.8-flash'), LlmModelInfo(id: 'gemini-flash-latest')]),
        'gemini-flash-latest',
      );
      expect(pickDefaultModel(gemini, const [LlmModelInfo(id: 'gemini-3.1-pro-preview')]), 'gemini-flash-latest',
          reason: 'aliases are served even when unlisted');
      final openai = providerById('openai');
      expect(pickDefaultModel(openai, const [LlmModelInfo(id: 'gpt-9'), LlmModelInfo(id: 'gpt-4.1-mini')]), 'gpt-4.1-mini');
      expect(pickDefaultModel(openai, const [LlmModelInfo(id: 'gpt-9')]), 'gpt-9');
    });

    test('picker lists preferred models first', () {
      final ordered = orderModelsForPicker(providerById('gemini'), const [
        LlmModelInfo(id: 'gemini-2.5-pro'),
        LlmModelInfo(id: 'gemini-3.8-flash'),
      ]);
      expect(ordered.first.id, 'gemini-flash-latest');
      expect(ordered.map((m) => m.id), containsAllInOrder(['gemini-3.8-flash', 'gemini-2.5-pro']));
    });

    test('config round-trips without secrets', () {
      const c = CloudConfig(providerId: 'custom', model: 'llama3.2', baseUrl: 'http://pc:11434/v1', supportsEffort: false);
      final json = c.toJson();
      expect(json.toString(), isNot(contains('key')));
      final back = CloudConfig.fromJson(json)!;
      expect(back.effectiveBaseUrl, 'http://pc:11434/v1');
      expect(back.label, 'Custom · llama3.2');
      expect(CloudConfig.fromJson({'provider': 'gemini'}), isNull);
    });
  });

  group('model catalog', () {
    test('curated downloads are unique and revision-pinned', () {
      final files = ModelCatalog.curated.map((m) => m.localFileName).toList();
      expect(files.toSet().length, files.length);
      for (final m in ModelCatalog.curated) {
        expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(m.revision), isTrue, reason: m.id);
        expect(m.downloadUrl, contains('/resolve/${m.revision}/'));
        expect(m.sizeBytes, greaterThan(100 * 1024 * 1024));
        expect(m.file, endsWith('.gguf'));
      }
    });

    test('recommendations follow memory and CPU class', () {
      DeviceProfile phone(double gb, Set<String> features, {double ghz = 2.2, int big = 2}) => DeviceProfile(
            totalRamBytes: (gb * 1024 * 1024 * 1024).round(),
            cpuFeatures: features,
            maxGHz: ghz,
            bigCores: big,
          );
      const dotprod = {'asimddp'};
      const i8mm = {'asimddp', 'i8mm'};
      // 3 GB phone: only the tiny model fits.
      expect(ModelCatalog.recommendedFor(phone(2.8, dotprod))?.id, ModelCatalog.qwen35Small.id);
      // 6 GB mid-range: MiniCPM.
      expect(ModelCatalog.recommendedFor(phone(5.6, dotprod))?.id, ModelCatalog.miniCpm.id);
      // 8 GB mid-range (e.g. Dimensity 700): Gemma 4 E2B fits.
      expect(ModelCatalog.recommendedFor(phone(7.4, dotprod))?.id, ModelCatalog.gemma4.id);
      // 12 GB flagship: the larger Gemma.
      expect(ModelCatalog.recommendedFor(phone(11.2, i8mm, ghz: 3.3, big: 4))?.id, ModelCatalog.gemma4Large.id);
      // Old A53-only phone with 8 GB: no dotprod, so not Gemma.
      expect(ModelCatalog.recommendedFor(phone(7.4, {}))?.id, isNot(ModelCatalog.gemma4.id));
      // 2 GB: nothing fits, suggest cloud.
      expect(ModelCatalog.recommendedFor(phone(1.8, dotprod)), isNull);
    });
  });
}
