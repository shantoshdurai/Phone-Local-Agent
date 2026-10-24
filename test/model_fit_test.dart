import 'package:flutter_test/flutter_test.dart';
import 'package:local_agent/services/device_capability.dart';
import 'package:local_agent/services/model_registry.dart';
import 'package:local_agent/services/tool_tiers.dart';

/// Pure-logic tests for the model-fit engine and tool tiering.
///
/// These are the two places where a wrong number silently misleads the user
/// (badge says "runs well", download then fails) or breaks the agent (a core
/// tool missing from the declared set), so they are worth pinning down without
/// a device or a platform channel.
DeviceProfile _profile({
  int? ramGB = 8,
  int cores = 8,
  int? freeMB = 12000,
  List<String> abis = const ['arm64-v8a'],
}) {
  return DeviceProfile(
    ramGB: ramGB,
    cpuCores: cores,
    freeStorageMB: freeMB,
    sdkInt: 34,
    abis: abis,
  );
}

void main() {
  group('DeviceCapability.fitFor', () {
    test('rejects a model that does not fit in free storage', () {
      final fit = DeviceCapability.fitFor(
        ModelRegistry.phi4Mini,
        _profile(freeMB: 500),
      );
      expect(fit.level, FitLevel.unsupported);
      expect(fit.isUsable, isFalse);
      expect(fit.requiredStorageMB, greaterThan(ModelRegistry.phi4Mini.sizeMB));
    });

    test('rejects a model whose RAM floor exceeds the device', () {
      final fit = DeviceCapability.fitFor(
        ModelRegistry.phi4Mini,
        _profile(ramGB: 4),
      );
      expect(fit.level, FitLevel.unsupported);
    });

    test('a small model fits happily on a modern 8-core phone', () {
      final fit = DeviceCapability.fitFor(
        ModelRegistry.qwen2_5_1_5b,
        _profile(),
      );
      expect(fit.isUsable, isTrue);
      expect(fit.level, isNot(FitLevel.unsupported));
      expect(fit.tokensPerSec, greaterThan(0));
      expect(fit.isMeasured, isFalse);
    });

    test('more cores never predict a slower model', () {
      final slow = DeviceCapability.fitFor(
        ModelRegistry.qwen2_5_1_5b,
        _profile(cores: 4),
      );
      final fast = DeviceCapability.fitFor(
        ModelRegistry.qwen2_5_1_5b,
        _profile(cores: 8),
      );
      expect(fast.tokensPerSec, greaterThanOrEqualTo(slow.tokensPerSec));
    });

    test('measured throughput overrides the prediction and is flagged', () {
      final measured = DeviceCapability.fitFor(
        ModelRegistry.qwen2_5_1_5b,
        _profile(),
        measuredTps: 3.0,
      );
      expect(measured.isMeasured, isTrue);
      expect(measured.tokensPerSec, 3.0);
      expect(measured.speedSourceLabel, 'measured here');
      // Under the 3.5 tok/s comfort floor, so it must downgrade the verdict.
      expect(measured.level, FitLevel.heavy);
    });

    test('unknown hardware degrades gracefully instead of throwing', () {
      final fit = DeviceCapability.fitFor(
        ModelRegistry.qwen2_5_1_5b,
        const DeviceProfile(cpuCores: 4, sdkInt: 0),
      );
      expect(fit.tokensPerSec, greaterThan(0));
      expect(fit.level, isNot(FitLevel.best));
    });
  });

  group('DeviceCapability.rank', () {
    test('exactly one usable model is marked best, and it is first', () {
      final ranked = DeviceCapability.rank(_profile());
      expect(ranked, isNotEmpty);
      final best = ranked.where((f) => f.level == FitLevel.best).toList();
      expect(best.length, 1);
      expect(ranked.first.level, FitLevel.best);
      expect(ranked.first.isUsable, isTrue);
    });

    test('usable models sort before unsupported ones', () {
      // Enough for Qwen (~1.9 GB) but not Phi (~4.3 GB).
      final ranked = DeviceCapability.rank(_profile(freeMB: 2500));
      final firstUnsupported =
          ranked.indexWhere((f) => f.level == FitLevel.unsupported);
      if (firstUnsupported != -1) {
        for (var i = firstUnsupported; i < ranked.length; i++) {
          expect(ranked[i].level, FitLevel.unsupported);
        }
      }
      expect(ranked.first.isUsable, isTrue);
    });

    test('returns no recommendation when nothing fits', () {
      final ranked = DeviceCapability.rank(_profile(freeMB: 100));
      expect(ranked.every((f) => !f.isUsable), isTrue);
      expect(DeviceCapability.recommendedSpec(_profile(freeMB: 100)), isNull);
    });
  });

  group('selectForBudget', () {
    final names = ['get_device_info', 'toggle_flashlight', 'send_whatsapp'];

    test('core tools are kept even when the budget is smaller than core', () {
      final selected = selectForBudget(names, 1);
      expect(selected, contains('get_device_info'));
      expect(selected, isNot(contains('send_whatsapp')));
    });

    test('never exceeds the budget once core is satisfied', () {
      final many = [
        'get_device_info',
        'get_date_time',
        'check_connectivity',
        'launch_app_by_name',
        'search_web',
        'toggle_flashlight',
        'set_volume',
      ];
      final selected = selectForBudget(many, 7);
      expect(selected.length, lessThanOrEqualTo(7));
    });

    test('unknown tools fall back to the niche tier (and are included last)', () {
      final selected = selectForBudget(['get_device_info', 'not_a_real_tool'], 5);
      expect(selected.first, 'get_device_info');
      expect(selected, contains('not_a_real_tool'));
    });
  });
}
