import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Feature-level permission topics.
///
/// The old onboarding screen asked for six things at once — including
/// "all files access", which Play restricts — before the user had seen a single
/// feature. That is both bad conversion and a policy risk. Permissions are now
/// grouped by *what the user is trying to do*, and asked for at the moment the
/// feature is used. Onboarding only offers the microphone, optionally.
enum PermTopic {
  microphone,
  notifications,
  photos,
  contacts,
  calendar,
  media,
}

class PermTopicInfo {
  final PermTopic topic;
  final IconData icon;
  final String title;
  final String reason;

  /// Shown in onboarding as a one-tap opt-in.
  final bool offeredInOnboarding;

  const PermTopicInfo({
    required this.topic,
    required this.icon,
    required this.title,
    required this.reason,
    this.offeredInOnboarding = false,
  });
}

const Map<PermTopic, PermTopicInfo> kPermTopics = {
  PermTopic.microphone: PermTopicInfo(
    topic: PermTopic.microphone,
    icon: Icons.mic_none_rounded,
    title: 'Microphone',
    reason: 'Talk to the agent instead of typing. Audio is transcribed '
        'on-device and never uploaded.',
    offeredInOnboarding: true,
  ),
  PermTopic.notifications: PermTopicInfo(
    topic: PermTopic.notifications,
    icon: Icons.notifications_none_rounded,
    title: 'Notifications',
    reason: 'Show progress while a long answer is generating in the '
        'background.',
  ),
  PermTopic.photos: PermTopicInfo(
    topic: PermTopic.photos,
    icon: Icons.image_outlined,
    title: 'Photos',
    reason: 'Attach an image so a vision model can look at it.',
  ),
  PermTopic.contacts: PermTopicInfo(
    topic: PermTopic.contacts,
    icon: Icons.contacts_outlined,
    title: 'Contacts',
    reason: 'Look up a phone number when you ask the agent to call or '
        'message someone.',
  ),
  PermTopic.calendar: PermTopicInfo(
    topic: PermTopic.calendar,
    icon: Icons.calendar_month_outlined,
    title: 'Calendar',
    reason: 'Create events you ask the agent to schedule.',
  ),
  PermTopic.media: PermTopicInfo(
    topic: PermTopic.media,
    icon: Icons.photo_library_outlined,
    title: 'Photos & media',
    reason: 'List and search the images, videos and audio on your phone.',
  ),
};

/// Thin, testable wrapper around `permission_handler`.
///
/// Every method is safe to call on a platform where the permission does not
/// exist (returns [PermissionStatus.granted] for non-Android) and never throws.
class PermissionFlow {
  PermissionFlow._();

  /// Android SDK level, set once at boot so the media permission mapping is
  /// correct without crossing a platform channel on every request.
  static int? _sdkOverride;
  static void configure({required int sdkInt}) => _sdkOverride = sdkInt;

  static int get sdkInt => _sdkOverride ?? 33;

  /// Platform permissions behind a topic on the current OS version.
  static List<Permission> permissionsFor(PermTopic topic) {
    switch (topic) {
      case PermTopic.microphone:
        return [Permission.microphone];
      case PermTopic.notifications:
        return [Permission.notification];
      case PermTopic.photos:
        if (sdkInt >= 33) return [Permission.photos];
        return [Permission.storage];
      case PermTopic.contacts:
        return [Permission.contacts];
      case PermTopic.calendar:
        return [Permission.calendarFullAccess];
      case PermTopic.media:
        if (sdkInt >= 33) {
          return [Permission.photos, Permission.videos, Permission.audio];
        }
        return [Permission.storage];
    }
  }

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Current state without prompting.
  static Future<bool> isGranted(PermTopic topic) async {
    if (!isSupported) return true;
    try {
      for (final p in permissionsFor(topic)) {
        if (!await p.isGranted) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ask for (only) what the topic needs. Returns true when fully granted.
  ///
  /// [onPermanentlyDenied] is invoked when the OS will no longer show a
  /// dialog, so the caller can route the user to app settings instead of
  /// appearing to do nothing.
  static Future<bool> request(
    PermTopic topic, {
    VoidCallback? onPermanentlyDenied,
  }) async {
    if (!isSupported) return true;
    try {
      final perms = permissionsFor(topic);
      if (perms.isEmpty) return true;

      final before = <Permission, PermissionStatus>{};
      for (final p in perms) {
        before[p] = await p.status;
      }

      final result = await perms.request();
      var allGranted = true;
      var anyPermanent = false;
      for (final p in perms) {
        final s = result[p] ?? PermissionStatus.denied;
        if (!s.isGranted && !s.isLimited) allGranted = false;
        if (s.isPermanentlyDenied ||
            (s.isDenied && (before[p]?.isPermanentlyDenied ?? false))) {
          anyPermanent = true;
        }
      }
      if (!allGranted && anyPermanent) onPermanentlyDenied?.call();
      return allGranted;
    } catch (_) {
      return false;
    }
  }

  /// Open the system settings page for this app (used after a permanent deny).
  static Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
