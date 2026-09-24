import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_info_plus/system_info_plus.dart';

import 'local_model.dart';

/// Rough CPU class, used for speed estimates before anything is measured.
enum PerfClass { low, mid, high, flagship }

/// How a model will fit in this phone's memory.
enum ModelFit { good, tight, tooBig }

/// What this phone can do for on-device AI: memory, CPU, GPU, and a speed
/// estimate that switches to real measurements once the user has chatted or
/// run a speed test.
class DeviceProfile {
  final int totalRamBytes;
  final int? availableRamBytes;
  final List<String> abis;
  final String? socName;
  final String? gpuName;
  final int cores;
  final int bigCores;
  final double? maxGHz;
  final Set<String> cpuFeatures;

  /// Effective memory bandwidth (GB/s) measured on real generations, if any.
  final double? measuredBandwidth;

  const DeviceProfile({
    required this.totalRamBytes,
    this.availableRamBytes,
    this.abis = const [],
    this.socName,
    this.gpuName,
    this.cores = 4,
    this.bigCores = 2,
    this.maxGHz,
    this.cpuFeatures = const {},
    this.measuredBandwidth,
  });

  static const double _gb = 1024 * 1024 * 1024;

  double get totalRamGB => totalRamBytes / _gb;
  double? get availableRamGB => availableRamBytes == null ? null : availableRamBytes! / _gb;

  /// Marketing size: an "8 GB" phone reports ~7.4 GB to apps.
  int get marketedRamGB {
    const sizes = [1, 2, 3, 4, 6, 8, 10, 12, 16, 18, 20, 24, 32];
    for (final s in sizes) {
      if (totalRamGB <= s) return s;
    }
    return totalRamGB.ceil();
  }

  /// Memory an app can realistically use for a model before Android starts
  /// killing it: the system, launcher and this app's UI keep about 30% of
  /// RAM (1.5 to 3 GB). Model weights are memory-mapped, so a tight fit
  /// still runs, just slower.
  double get usableForAiGB {
    final reserve = (totalRamGB * 0.3).clamp(1.5, 3.0);
    return math.max(0, totalRamGB - reserve);
  }

  /// Unknown ABIs (desktop, tests) count as capable.
  bool get arm64 => abis.isEmpty || abis.contains('arm64-v8a');
  bool get x86 => abis.any((a) => a.startsWith('x86'));

  bool get hasDotProd => cpuFeatures.contains('asimddp');
  bool get hasI8mm => cpuFeatures.contains('i8mm');

  PerfClass get perfClass => classify(
        features: cpuFeatures,
        bigCores: bigCores,
        maxGHz: maxGHz,
        x86: x86,
      );

  /// CPU threads for generation. Token generation is limited by memory
  /// bandwidth; past ~4 threads, little cores only add contention.
  int get recommendedThreads => math.max(1, math.min(4, cores));

  /// Prompt processing is compute-bound and benefits from more cores.
  int get recommendedBatchThreads => math.max(1, math.min(6, cores));

  String get cpuLabel {
    final parts = <String>['$cores cores'];
    if (maxGHz != null) parts.add('up to ${maxGHz!.toStringAsFixed(1)} GHz');
    if (hasI8mm) {
      parts.add('i8mm');
    } else if (hasDotProd) {
      parts.add('dotprod');
    }
    return parts.join(' · ');
  }

  String get archLabel {
    if (x86) return 'x86_64';
    if (hasI8mm) return 'ARMv8.6+';
    if (hasDotProd) return 'ARMv8.2+';
    return arm64 ? 'ARM64' : (abis.isEmpty ? 'Unknown' : abis.first);
  }

  ModelFit fitOf(LocalModel model, {int? contextTokens, bool withVision = false}) =>
      fitFor(model.ramNeededGB(contextTokens: contextTokens, withVision: withVision));

  ModelFit fitFor(double neededGB) {
    final usable = usableForAiGB;
    if (neededGB <= usable * 0.75) return ModelFit.good;
    if (neededGB <= usable) return ModelFit.tight;
    return ModelFit.tooBig;
  }

  /// Effective bandwidth for token generation (GB/s): measured if we have it,
  /// else a class-based guess from public llama.cpp phone benchmarks.
  double get bandwidthGBs => measuredBandwidth ?? defaultBandwidth(perfClass);

  static double defaultBandwidth(PerfClass c) => switch (c) {
        PerfClass.low => 2.2,
        PerfClass.mid => 5.5,
        PerfClass.high => 13,
        PerfClass.flagship => 22,
      };

  /// Estimated generation speed (tokens/s) for [model] on this phone.
  double estimateTokensPerSecond(LocalModel model) =>
      estimateTps(bandwidthGBs, model.sizeBytes / _gb * model.activeWeightFraction);

  static double estimateTps(double bandwidthGBs, double activeWeightsGB) =>
      activeWeightsGB <= 0 ? 0 : bandwidthGBs / (activeWeightsGB * 1.08);

  bool get speedIsMeasured => measuredBandwidth != null;

  static PerfClass classify({
    required Set<String> features,
    required int bigCores,
    double? maxGHz,
    bool x86 = false,
  }) {
    if (x86) return PerfClass.high; // emulators and Chromebooks on desktop CPUs
    final ghz = maxGHz ?? 2.0;
    if (features.contains('i8mm')) {
      return ghz >= 3.0 ? PerfClass.flagship : PerfClass.high;
    }
    if (features.contains('asimddp')) {
      return (ghz >= 2.8 && bigCores >= 3) ? PerfClass.high : PerfClass.mid;
    }
    return PerfClass.low;
  }

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  static DeviceProfile? _cached;
  static const _kBandwidth = 'measured_bandwidth_gbs_v1';

  /// Reads the profile once per launch; [refresh] re-reads free memory.
  static Future<DeviceProfile> load({bool refresh = false}) async {
    final cached = _cached;
    if (cached != null && !refresh) return cached;
    if (cached != null) {
      final mem = await _readMeminfo();
      return _cached = cached._with(
        availableRamBytes: mem?.available,
        measuredBandwidth: await _measured(),
      );
    }

    final mem = await _readMeminfo();
    var total = mem?.total;
    if (total == null) {
      try {
        final mb = await SystemInfoPlus.physicalMemory;
        if (mb != null) total = mb * 1024 * 1024;
      } catch (_) {}
    }

    var abis = const <String>[];
    try {
      if (Platform.isAndroid) abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    } catch (_) {}

    final cpu = await _readCpu();
    final profile = DeviceProfile(
      totalRamBytes: total ?? 4 * 1024 * 1024 * 1024,
      availableRamBytes: mem?.available,
      abis: abis,
      socName: await _socName(),
      gpuName: await _gpuName(),
      cores: cpu.cores,
      bigCores: cpu.bigCores,
      maxGHz: cpu.maxGHz,
      cpuFeatures: cpu.features,
      measuredBandwidth: await _measured(),
    );
    return _cached = profile;
  }

  DeviceProfile _with({int? availableRamBytes, double? measuredBandwidth}) => DeviceProfile(
        totalRamBytes: totalRamBytes,
        availableRamBytes: availableRamBytes ?? this.availableRamBytes,
        abis: abis,
        socName: socName,
        gpuName: gpuName,
        cores: cores,
        bigCores: bigCores,
        maxGHz: maxGHz,
        cpuFeatures: cpuFeatures,
        measuredBandwidth: measuredBandwidth,
      );

  /// Records a real generation: [tokensPerSecond] on a model whose active
  /// weights are [activeWeightsGB]. Smoothed so one slow run (thermal
  /// throttling, a busy phone) doesn't swing every estimate.
  static Future<void> recordSpeed({
    required double tokensPerSecond,
    required double activeWeightsGB,
    required int generatedTokens,
  }) async {
    if (generatedTokens < 16 || tokensPerSecond <= 0 || activeWeightsGB <= 0) return;
    final sample = tokensPerSecond * activeWeightsGB * 1.08;
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getDouble(_kBandwidth);
    final next = old == null ? sample : old * 0.7 + sample * 0.3;
    await prefs.setDouble(_kBandwidth, next);
    final cached = _cached;
    if (cached != null) _cached = cached._with(measuredBandwidth: next);
  }

  static Future<double?> _measured() async {
    try {
      return (await SharedPreferences.getInstance()).getDouble(_kBandwidth);
    } catch (_) {
      return null;
    }
  }

  static Future<({int total, int? available})?> _readMeminfo() async {
    try {
      final file = File('/proc/meminfo');
      if (!await file.exists()) return null;
      return parseMeminfo(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static ({int total, int? available})? parseMeminfo(String text) {
    int? kb(String key) {
      final m = RegExp('^$key:\\s+(\\d+) kB', multiLine: true).firstMatch(text);
      return m == null ? null : int.parse(m.group(1)!);
    }

    final total = kb('MemTotal');
    if (total == null) return null;
    final available = kb('MemAvailable');
    return (total: total * 1024, available: available == null ? null : available * 1024);
  }

  static Future<({int cores, int bigCores, double? maxGHz, Set<String> features})> _readCpu() async {
    var features = <String>{};
    var cores = Platform.numberOfProcessors;
    try {
      features = parseCpuFeatures(await File('/proc/cpuinfo').readAsString());
    } catch (_) {}

    final freqs = <int>[];
    final capacities = <int>[];
    for (var i = 0; i < cores; i++) {
      final base = '/sys/devices/system/cpu/cpu$i';
      final f = await _readInt('$base/cpufreq/cpuinfo_max_freq');
      if (f != null) freqs.add(f);
      final c = await _readInt('$base/cpu_capacity');
      if (c != null) capacities.add(c);
    }
    final maxGHz = freqs.isEmpty ? null : freqs.reduce(math.max) / 1e6;
    final big = bigCoreCount(capacities: capacities, frequenciesKHz: freqs, cores: cores);
    return (cores: cores, bigCores: big, maxGHz: maxGHz, features: features);
  }

  /// Cores at >= 60% of the fastest core's capacity (or frequency, on
  /// kernels that don't expose capacity).
  @visibleForTesting
  static int bigCoreCount({
    required List<int> capacities,
    required List<int> frequenciesKHz,
    required int cores,
  }) {
    final values = capacities.isNotEmpty ? capacities : frequenciesKHz;
    if (values.isEmpty) return math.min(cores, 4);
    final top = values.reduce(math.max);
    final threshold = capacities.isNotEmpty ? 0.6 : 0.85;
    return values.where((v) => v >= top * threshold).length;
  }

  @visibleForTesting
  static Set<String> parseCpuFeatures(String cpuinfo) {
    final m = RegExp(r'^(?:Features|flags)\s*:\s*(.+)$', multiLine: true).firstMatch(cpuinfo);
    if (m == null) return {};
    final tokens = m.group(1)!.trim().split(RegExp(r'\s+')).toSet();
    // x86 hosts: map AVX-VNNI and friends onto the ARM names we check.
    if (tokens.contains('avx2')) tokens.add('asimddp');
    return tokens;
  }

  static Future<int?> _readInt(String path) async {
    try {
      return int.tryParse((await File(path).readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _getprop(String key) async {
    if (!Platform.isAndroid) return null;
    try {
      final r = await Process.run('getprop', [key]);
      final v = '${r.stdout}'.trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _socName() async {
    final manufacturer = await _getprop('ro.soc.manufacturer');
    final model = await _getprop('ro.soc.model');
    if (model != null) {
      return manufacturer == null ? model : '${_titleCase(manufacturer)} $model';
    }
    final platform = await _getprop('ro.board.platform') ?? await _getprop('ro.hardware');
    return platform?.toUpperCase();
  }

  /// Best effort: Adreno and Mali drivers expose the GPU name in sysfs on
  /// most phones; SELinux hides it on some.
  static Future<String?> _gpuName() async {
    if (!Platform.isAndroid) return null;
    for (final path in const [
      '/sys/class/kgsl/kgsl-3d0/gpu_model',
      '/sys/kernel/gpu/gpu_model',
      '/sys/class/misc/mali0/device/gpuinfo',
    ]) {
      try {
        final v = (await File(path).readAsString()).trim();
        if (v.isNotEmpty) return prettyGpuName(v);
      } catch (_) {}
    }
    return null;
  }

  /// "Adreno740v2" → "Adreno 740"; "Mali-G57 2 cores r0p1 0x9093" → "Mali-G57 MC2".
  @visibleForTesting
  static String prettyGpuName(String raw) {
    final adreno = RegExp(r'Adreno\D*(\d{3})', caseSensitive: false).firstMatch(raw);
    if (adreno != null) return 'Adreno ${adreno.group(1)}';
    final mali = RegExp(r'(Mali-[A-Z]\d+)(?:\s+(\d+)\s+cores?)?', caseSensitive: false).firstMatch(raw);
    if (mali != null) {
      final mc = mali.group(2);
      return mc == null ? mali.group(1)! : '${mali.group(1)} MC$mc';
    }
    return raw.split(RegExp(r'\s+')).take(3).join(' ');
  }

  static String _titleCase(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
}
