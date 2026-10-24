import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:system_info_plus/system_info_plus.dart';

import 'model_registry.dart';

/// How comfortably a given model runs on the current phone.
enum FitLevel {
  /// The model we would pick if the user just taps "Get started".
  best,

  /// Fits and should feel usable.
  good,

  /// Fits, but may be slow or leave little headroom.
  heavy,

  /// Will not load or will thrash: not enough RAM or storage.
  unsupported,
}

/// A cheap, cached snapshot of what the phone can actually do.
///
/// Every field is best-effort: on some OEM builds `SystemInfoPlus` or
/// `DiskSpace` throw or return null, and the recommendation logic has to keep
/// working with partial data rather than pretending it knows.
class DeviceProfile {
  final int? ramGB;
  final int cpuCores;
  final int? freeStorageMB;
  final int? totalStorageMB;
  final int sdkInt;
  final String? brand;
  final String? model;
  final String? soc;
  final List<String> abis;

  const DeviceProfile({
    this.ramGB,
    required this.cpuCores,
    this.freeStorageMB,
    this.totalStorageMB,
    required this.sdkInt,
    this.brand,
    this.model,
    this.soc,
    this.abis = const [],
  });

  static const DeviceProfile unknown = DeviceProfile(cpuCores: 4, sdkInt: 30);

  double? get freeStorageGB =>
      freeStorageMB == null ? null : freeStorageMB! / 1024.0;

  bool get isArm64 => abis.isEmpty || abis.any((a) => a.contains('arm64'));

  /// Human label for the onboarding "we checked your phone" step.
  String get deviceLabel {
    final name = [brand, model]
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    return name.isEmpty ? 'This device' : name;
  }
}

/// A model scored against a [DeviceProfile].
class ModelFit {
  final ModelSpec spec;
  final FitLevel level;

  /// Estimated decode speed in tokens/second. Deliberately conservative and
  /// labelled "estimated" in the UI — it comes from a calibration curve, not
  /// from a benchmark on this exact handset. When [isMeasured] is true the
  /// value came from a real turn on this device instead.
  final double tokensPerSec;

  /// True when [tokensPerSec] is a measured value rather than a prediction.
  final bool isMeasured;

  /// Storage the install needs, including headroom for the temporary `.part`
  /// file while downloading.
  final int requiredStorageMB;

  const ModelFit({
    required this.spec,
    required this.level,
    required this.tokensPerSec,
    required this.requiredStorageMB,
    this.isMeasured = false,
  });

  bool get isUsable => level != FitLevel.unsupported;
  bool get isRecommended => level == FitLevel.best;

  String get speedLabel {
    if (tokensPerSec >= 10) return '~${tokensPerSec.round()} tok/s';
    return '~${tokensPerSec.toStringAsFixed(1)} tok/s';
  }

  /// Whether the number came from this phone or from the calibration curve.
  String get speedSourceLabel => isMeasured ? 'measured here' : 'estimated';

  String get verdictLabel {
    switch (level) {
      case FitLevel.best:
        return 'BEST FOR THIS PHONE';
      case FitLevel.good:
        return 'RUNS WELL';
      case FitLevel.heavy:
        return 'MAY BE SLOW';
      case FitLevel.unsupported:
        return 'WON\'T FIT';
    }
  }

  String get verdictDetail {
    switch (level) {
      case FitLevel.best:
        return 'Fast enough for chat and tool calls, with RAM to spare.';
      case FitLevel.good:
        return 'Runs comfortably on your hardware.';
      case FitLevel.heavy:
        return 'Works, but expect slower replies and heavier battery use.';
      case FitLevel.unsupported:
        return 'Needs more RAM or free storage than this phone has.';
    }
  }
}

/// Scans the device once and caches the result for the process lifetime.
///
/// The old app called `getQuickStats()` on every screen build; on some devices
/// `SystemInfoPlus` crosses a platform channel with a 200 ms+ cost, which
/// showed up as jank on the model picker. One scan, shared everywhere.
class DeviceCapability {
  DeviceCapability._();

  static DeviceProfile? _cached;
  static Future<DeviceProfile>? _inFlight;

  static Future<DeviceProfile> scan({bool force = false}) {
    if (!force && _cached != null) return Future.value(_cached);
    if (!force && _inFlight != null) return _inFlight!;
    final f = _scan().then((p) {
      _cached = p;
      _inFlight = null;
      return p;
    }).catchError((_) {
      _inFlight = null;
      return _cached ?? DeviceProfile.unknown;
    });
    _inFlight = f;
    return f;
  }

  /// Already-known profile, or null if [scan] has not completed yet. UI can
  /// use this to avoid showing a spinner when the data is warm.
  static DeviceProfile? get cached => _cached;

  static Future<DeviceProfile> _scan() async {
    int? ramGB;
    int? freeMB;
    int? totalMB;
    int sdkInt = 0;
    String? brand;
    String? model;
    String? soc;
    List<String> abis = const [];

    try {
      final mb = await SystemInfoPlus.physicalMemory;
      if (mb != null && mb > 0) ramGB = (mb / 1024).ceil();
    } catch (_) {
      // Not fatal — recommendation falls back to core count.
    }

    try {
      final free = await DiskSpace.getFreeDiskSpace;
      final total = await DiskSpace.getTotalDiskSpace;
      freeMB = free?.round();
      totalMB = total?.round();
    } catch (_) {
      // Not fatal.
    }

    if (Platform.isAndroid) {
      try {
        final ai = await DeviceInfoPlugin().androidInfo;
        sdkInt = ai.version.sdkInt;
        brand = ai.brand;
        model = ai.model;
        abis = ai.supportedAbis;
        // `hardware` is often "unknown" on newer builds, which the UI treats
        // as "no SoC label" rather than printing it.
        soc = ai.hardware;
      } catch (_) {}
    }

    return DeviceProfile(
      ramGB: ramGB,
      cpuCores: Platform.numberOfProcessors.clamp(1, 16),
      freeStorageMB: freeMB,
      totalStorageMB: totalMB,
      sdkInt: sdkInt,
      brand: brand,
      model: model,
      soc: soc,
      abis: abis,
    );
  }

  /// Score [spec] against [profile].
  ///
  /// Speed model: decode tok/s scales roughly with cores and inversely with
  /// model file size (memory bandwidth bound at these quantisations). The
  /// per-spec `baselineTps` is a measured value on an 8-core reference phone,
  /// so this stays honest for new models added to the registry instead of
  /// hard-coding a number per device.
  ///
  /// [measuredTps] (from [ModelBenchmarks]) wins over the prediction when
  /// present: it is the only number that accounts for this phone's governor,
  /// thermals and background load.
  static ModelFit fitFor(
    ModelSpec spec,
    DeviceProfile profile, {
    double? measuredTps,
  }) {
    final requiredMB = (spec.sizeMB * 1.12).round();
    final freeMB = profile.freeStorageMB;
    final ram = profile.ramGB;

    // Speed: core scaling with diminishing returns, plus a small penalty when
    // the model is close to the device's RAM ceiling (less page-cache room
    // for the mmapped weights).
    final coreFactor =
        math.pow(profile.cpuCores / 8.0, 0.7).toDouble().clamp(0.35, 1.35);
    var predicted = spec.baselineTps * coreFactor;
    if (ram != null && ram <= spec.minRamGB) predicted *= 0.75;
    if (!profile.isArm64) predicted *= 0.6;

    final measured = (measuredTps != null && measuredTps > 0) ? measuredTps : null;
    final tps = measured ?? predicted;

    FitLevel level;
    if (freeMB != null && freeMB < requiredMB) {
      level = FitLevel.unsupported;
    } else if (ram != null && ram < spec.minRamGB) {
      level = FitLevel.unsupported;
    } else if (ram != null && ram <= spec.minRamGB + 1) {
      level = FitLevel.heavy;
    } else if (tps < 3.5) {
      level = FitLevel.heavy;
    } else {
      level = FitLevel.good;
    }

    return ModelFit(
      spec: spec,
      level: level,
      tokensPerSec: double.parse(tps.clamp(0.3, 40.0).toStringAsFixed(1)),
      requiredStorageMB: requiredMB,
      isMeasured: measured != null,
    );
  }

  /// Every model, best-first. The first usable entry is marked [FitLevel.best].
  static List<ModelFit> rank(
    DeviceProfile profile, {
    Map<String, double> measured = const {},
  }) {
    final fits = ModelRegistry.all
        .map((s) => fitFor(s, profile, measuredTps: measured[s.fileName]))
        .toList();

    // Prefer faster, then smaller, among usable models.
    fits.sort((a, b) {
      final aU = a.isUsable ? 0 : 1;
      final bU = b.isUsable ? 0 : 1;
      if (aU != bU) return aU - bU;
      if (a.isUsable && b.isUsable) {
        final byQuality = b.spec.supportsTools == a.spec.supportsTools
            ? 0
            : (b.spec.supportsTools ? 1 : -1);
        if (byQuality != 0) return byQuality;
        return b.tokensPerSec.compareTo(a.tokensPerSec);
      }
      return 0;
    });

    if (fits.isEmpty) return fits;
    final bestIndex = fits.indexWhere((f) => f.isUsable);
    if (bestIndex <= 0) {
      if (bestIndex == 0) {
        fits[0] = ModelFit(
          spec: fits[0].spec,
          level: FitLevel.best,
          tokensPerSec: fits[0].tokensPerSec,
          requiredStorageMB: fits[0].requiredStorageMB,
          isMeasured: fits[0].isMeasured,
        );
      }
      return fits;
    }
    final best = fits.removeAt(bestIndex);
    return [
      ModelFit(
        spec: best.spec,
        level: FitLevel.best,
        tokensPerSec: best.tokensPerSec,
        requiredStorageMB: best.requiredStorageMB,
        isMeasured: best.isMeasured,
      ),
      ...fits,
    ];
  }

  /// The single model to preselect for a fresh install, or null when nothing
  /// fits (tiny storage / very old device).
  static ModelSpec? recommendedSpec(DeviceProfile profile) {
    final ranked = rank(profile);
    for (final f in ranked) {
      if (f.isUsable) return f.spec;
    }
    return null;
  }
}
