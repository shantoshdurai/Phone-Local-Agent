import 'dart:async';

import 'package:flutter/services.dart';

/// Why the app was opened.
enum LaunchKind {
  /// The user's assistant gesture (long-press home / squeeze / "Hey Google"
  /// replacement). We answer in voice mode.
  assistant,

  /// Text shared from another app, or selected and sent through the
  /// "Process text" menu.
  share,
}

class LaunchEvent {
  final LaunchKind kind;
  final String? text;

  /// Local file path for a shared image (copied out of the share intent into
  /// the app cache by MainActivity).
  final String? imagePath;

  const LaunchEvent({required this.kind, this.text, this.imagePath});
}

/// Bridge to the small `com.localagent/assistant` MethodChannel in
/// `MainActivity.kt`.
///
/// Responsibilities:
/// - hold a launch intent that arrived before Dart was ready (cold start),
/// - forward intents that arrive while the app is alive,
/// - check/request the Android `ROLE_ASSISTANT`.
///
/// Everything is best-effort: on iOS/desktop, or if the channel is missing,
/// the methods degrade to "not the default assistant" instead of throwing.
class AssistantService {
  AssistantService._();
  static final AssistantService instance = AssistantService._();

  static const MethodChannel _channel = MethodChannel('com.localagent/assistant');

  final StreamController<LaunchEvent> _events =
      StreamController<LaunchEvent>.broadcast();

  /// Runtime events (app already running). Cold-start events come from
  /// [takePending] instead.
  Stream<LaunchEvent> get events => _events.stream;

  LaunchEvent? _pending;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLaunchEvent') {
        final event = _parse(call.arguments);
        if (event != null) _emit(event);
      }
      return null;
    });

    try {
      final raw = await _channel.invokeMethod<dynamic>('consumeLaunchEvent');
      final event = _parse(raw);
      if (event != null) _pending = event;
    } catch (_) {
      // Channel unavailable (unit tests, other platforms) — nothing to do.
    }
  }

  /// The launch event that caused this process to start, if any. Consumed once.
  LaunchEvent? takePending() {
    final event = _pending;
    _pending = null;
    return event;
  }

  /// True when this app is the system's chosen digital assistant.
  Future<bool> isDefaultAssistant() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultAssistant') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "choose your assistant" dialog (Android 10+).
  /// Returns false when the platform has no such role or the call failed.
  Future<bool> requestDefaultAssistant() async {
    try {
      await _channel.invokeMethod<void>('requestDefaultAssistant');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Play one of the bundled soft UI cues ("listen" | "done").
  ///
  /// Rendered by a native MediaPlayer from `res/raw`, so there is no audio
  /// package and no dependency on the OS click sounds.
  Future<void> playCue(String name) async {
    try {
      await _channel.invokeMethod<void>('playCue', {'name': name});
    } catch (_) {
      // Decorative only — never let audio break the voice loop.
    }
  }

  /// If the clipboard holds an image (e.g. a screenshot copied from gallery or
  /// WhatsApp), copy it into the app cache and return the local path.
  Future<String?> getClipboardImage() async {
    try {
      return await _channel.invokeMethod<String>('getClipboardImage');
    } catch (_) {
      return null;
    }
  }

  void _emit(LaunchEvent event) {
    _pending ??= event;
    if (!_events.isClosed) _events.add(event);
  }

  static LaunchEvent? _parse(dynamic raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString();
    final text = raw['text']?.toString();
    final imagePath = raw['imagePath']?.toString();
    if (type == 'assistant') return const LaunchEvent(kind: LaunchKind.assistant);
    if (type == 'share') {
      return LaunchEvent(
        kind: LaunchKind.share,
        text: text,
        imagePath: (imagePath == null || imagePath.isEmpty) ? null : imagePath,
      );
    }
    return null;
  }
}
