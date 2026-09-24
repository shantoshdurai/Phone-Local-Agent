import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'device_profile.dart';
import 'local_model.dart';

/// Per-model generation settings (Settings → Model settings). Defaults come
/// from the model card and the phone; anything the user changes is stored
/// per model, and "Reset to defaults" drops the overrides.
class InferenceSettings {
  final double temperature;
  final int topK;
  final double topP;
  final double minP;
  final double repeatPenalty;
  final double presencePenalty;

  /// Longest reply, in tokens.
  final int maxTokens;

  /// Context window (prompt + history + reply). Bigger costs RAM and makes
  /// every message slower to start on phones.
  final int contextSize;

  /// CPU threads; 0 picks automatically from the phone's cores.
  final int threads;

  /// Offload layers to the GPU (OpenCL on Adreno). Off by default: on most
  /// phone GPUs llama.cpp is slower than the CPU.
  final bool useGpu;

  /// Let reasoning models think before answering. Better answers, much
  /// slower on a phone.
  final bool thinking;

  const InferenceSettings({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.minP,
    required this.repeatPenalty,
    this.presencePenalty = 0,
    required this.maxTokens,
    required this.contextSize,
    this.threads = 0,
    this.useGpu = false,
    this.thinking = false,
  });

  static const int minContext = 1024;
  static const int maxContext = 32768;

  factory InferenceSettings.defaultsFor(LocalModel model, [DeviceProfile? device]) {
    var ctx = model.defaultContext;
    // Low-memory phones get a smaller window so the KV cache fits.
    if (device != null && device.usableForAiGB < model.ramNeededGB(contextTokens: ctx)) {
      ctx = 2048;
    }
    return InferenceSettings(
      temperature: model.sampling.temperature,
      topK: model.sampling.topK,
      topP: model.sampling.topP,
      minP: model.sampling.minP,
      repeatPenalty: model.sampling.repeatPenalty,
      presencePenalty: model.sampling.presencePenalty,
      maxTokens: 1024,
      contextSize: ctx,
    );
  }

  InferenceSettings copyWith({
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? repeatPenalty,
    double? presencePenalty,
    int? maxTokens,
    int? contextSize,
    int? threads,
    bool? useGpu,
    bool? thinking,
  }) =>
      InferenceSettings(
        temperature: temperature ?? this.temperature,
        topK: topK ?? this.topK,
        topP: topP ?? this.topP,
        minP: minP ?? this.minP,
        repeatPenalty: repeatPenalty ?? this.repeatPenalty,
        presencePenalty: presencePenalty ?? this.presencePenalty,
        maxTokens: maxTokens ?? this.maxTokens,
        contextSize: contextSize ?? this.contextSize,
        threads: threads ?? this.threads,
        useGpu: useGpu ?? this.useGpu,
        thinking: thinking ?? this.thinking,
      );

  /// Settings that only take effect after the model is reloaded.
  bool needsReloadComparedTo(InferenceSettings other) =>
      contextSize != other.contextSize || threads != other.threads || useGpu != other.useGpu;

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'topK': topK,
        'topP': topP,
        'minP': minP,
        'repeatPenalty': repeatPenalty,
        'presencePenalty': presencePenalty,
        'maxTokens': maxTokens,
        'contextSize': contextSize,
        'threads': threads,
        'useGpu': useGpu,
        'thinking': thinking,
      };

  /// Applies stored overrides on top of [defaults], clamping anything out of
  /// range (older versions, hand-edited prefs).
  static InferenceSettings fromJson(Map<String, dynamic> json, InferenceSettings defaults) {
    double d(String k, double fallback, double lo, double hi) =>
        ((json[k] as num?)?.toDouble() ?? fallback).clamp(lo, hi).toDouble();
    int i(String k, int fallback, int lo, int hi) =>
        ((json[k] as num?)?.toInt() ?? fallback).clamp(lo, hi).toInt();
    return InferenceSettings(
      temperature: d('temperature', defaults.temperature, 0, 2),
      topK: i('topK', defaults.topK, 0, 200),
      topP: d('topP', defaults.topP, 0, 1),
      minP: d('minP', defaults.minP, 0, 1),
      repeatPenalty: d('repeatPenalty', defaults.repeatPenalty, 0.8, 2),
      presencePenalty: d('presencePenalty', defaults.presencePenalty, 0, 2),
      maxTokens: i('maxTokens', defaults.maxTokens, 64, 8192),
      contextSize: i('contextSize', defaults.contextSize, minContext, maxContext),
      threads: i('threads', defaults.threads, 0, 16),
      useGpu: json['useGpu'] is bool ? json['useGpu'] as bool : defaults.useGpu,
      thinking: json['thinking'] is bool ? json['thinking'] as bool : defaults.thinking,
    );
  }
}

class InferenceSettingsStore {
  InferenceSettingsStore._();

  static String _key(String modelId) => 'inference_v1_$modelId';

  static Future<InferenceSettings> load(LocalModel model, [DeviceProfile? device]) async {
    final defaults = InferenceSettings.defaultsFor(model, device);
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(model.id));
      if (raw == null) return defaults;
      return InferenceSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>, defaults);
    } catch (_) {
      return defaults;
    }
  }

  static Future<void> save(LocalModel model, InferenceSettings settings) async =>
      (await SharedPreferences.getInstance()).setString(_key(model.id), jsonEncode(settings.toJson()));

  static Future<void> reset(LocalModel model) async =>
      (await SharedPreferences.getInstance()).remove(_key(model.id));
}
