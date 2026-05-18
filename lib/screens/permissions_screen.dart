import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:device_calendar/device_calendar.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_widgets.dart';
import 'mode_selection_screen.dart';

enum PermStatus { pending, granted, denied }

class _PermItem {
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;
  PermStatus status = PermStatus.pending;
  _PermItem({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}

/// One card per permission. The user taps each individually — no bulk
/// "grant everything" button, because Android dialogs are sequential anyway
/// and users feel more comfortable when each ask is its own decision.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final List<_PermItem> _perms = [
    _PermItem(
      key: 'storage',
      icon: Icons.folder_rounded,
      title: 'Storage',
      subtitle: 'Save model files and access local files for tools.',
    ),
    _PermItem(
      key: 'notification',
      icon: Icons.notifications_active_rounded,
      title: 'Notifications',
      subtitle: 'Keep inference running in the background.',
    ),
    _PermItem(
      key: 'microphone',
      icon: Icons.mic_rounded,
      title: 'Microphone',
      subtitle: 'Talk to the agent hands-free in voice mode.',
    ),
    _PermItem(
      key: 'contacts',
      icon: Icons.contacts_rounded,
      title: 'Contacts',
      subtitle: 'Look up people when you ask the agent to message someone.',
    ),
    _PermItem(
      key: 'calendar',
      icon: Icons.event_rounded,
      title: 'Calendar',
      subtitle: 'Create and read events when you schedule things.',
    ),
  ];

  bool _busyKey(String? k) => _activeKey == k;
  String? _activeKey;

  Future<void> _requestOne(_PermItem p) async {
    if (_activeKey != null) return;
    setState(() => _activeKey = p.key);
    try {
      final granted = await _platformRequest(p.key);
      if (!mounted) return;
      setState(() => p.status = granted ? PermStatus.granted : PermStatus.denied);
    } finally {
      if (mounted) setState(() => _activeKey = null);
    }
  }

  Future<bool> _platformRequest(String key) async {
    try {
      switch (key) {
        case 'storage':
          if (Platform.isAndroid) {
            final manage = await Permission.manageExternalStorage.request();
            if (manage.isGranted) return true;
            final basic = await Permission.storage.request();
            return basic.isGranted;
          }
          return true;
        case 'notification':
          return (await Permission.notification.request()).isGranted;
        case 'microphone':
          return (await Permission.microphone.request()).isGranted;
        case 'contacts':
          return await FlutterContacts.requestPermission(readonly: false);
        case 'calendar':
          final plugin = DeviceCalendarPlugin();
          final r = await plugin.requestPermissions();
          return r.isSuccess && (r.data ?? false);
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  void _continue() {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const ModeSelectionScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  int get _grantedCount =>
      _perms.where((p) => p.status == PermStatus.granted).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.glassBg,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: const StepIndicator(step: 1, total: 2)
                        .animate()
                        .fadeIn(duration: 400.ms),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'App permissions',
                    style: AppTextStyles.heading.copyWith(
                      fontSize: 32,
                      color: AppTheme.glassInk,
                      letterSpacing: -1.0,
                    ),
                  ).animate().fadeIn(delay: 100.ms).moveY(begin: 12, end: 0),
                  const SizedBox(height: 10),
                  Text(
                    'Tap each card to grant access. Skip any you don’t need — the agent will simply turn off the matching tools.',
                    style: AppTextStyles.body.copyWith(
                      color: AppTheme.glassInk2.withValues(alpha: 0.8),
                      fontSize: 14,
                    ),
                  ).animate().fadeIn(delay: 200.ms),
                  const SizedBox(height: 28),
                  for (var i = 0; i < _perms.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _permCard(_perms[i])
                          .animate()
                          .fadeIn(delay: (300 + i * 80).ms)
                          .moveY(begin: 14, end: 0),
                    ),
                  const SizedBox(height: 20),
                  GradientButton(
                    onPressed: _continue,
                    label: _grantedCount == _perms.length
                        ? 'CONTINUE'
                        : 'CONTINUE ANYWAY',
                  )
                      .animate()
                      .fadeIn(delay: (300 + _perms.length * 80 + 100).ms)
                      .moveY(begin: 20, end: 0),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      'You can change these later in system settings.',
                      style: AppTextStyles.small.copyWith(
                        color: AppTheme.glassMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permCard(_PermItem p) {
    final granted = p.status == PermStatus.granted;
    final denied = p.status == PermStatus.denied;
    final loading = _busyKey(p.key);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      borderRadius: BorderRadius.circular(20),
      blur: 25,
      opacity: granted ? 0.07 : 0.04,
      border: Border.all(
        color: granted
            ? AppTheme.accentSuccess.withValues(alpha: 0.5)
            : (denied
                ? AppTheme.accentError.withValues(alpha: 0.35)
                : AppTheme.glassBorder),
        width: granted ? 1.4 : 0.9,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: granted
                  ? AppTheme.accentSuccess.withValues(alpha: 0.12)
                  : AppTheme.glassSurface2,
              border: Border.all(
                color: granted
                    ? AppTheme.accentSuccess.withValues(alpha: 0.4)
                    : AppTheme.glassBorder,
                width: 1,
              ),
            ),
            child: Icon(
              p.icon,
              color: granted ? AppTheme.accentSuccess : AppTheme.glassInk2,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.title,
                  style: AppTextStyles.bodyStrong.copyWith(
                    color: AppTheme.glassInk,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  p.subtitle,
                  style: AppTextStyles.small.copyWith(
                    color: AppTheme.glassInk2.withValues(alpha: 0.7),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _trailing(p, granted, denied, loading),
        ],
      ),
    );
  }

  Widget _trailing(_PermItem p, bool granted, bool denied, bool loading) {
    if (granted) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: Icon(
          Icons.check_circle_rounded,
          color: AppTheme.accentSuccess,
          size: 26,
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: loading ? null : () => _requestOne(p),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: denied
                ? AppTheme.accentError.withValues(alpha: 0.12)
                : AppTheme.glassAccent.withValues(alpha: 0.16),
            border: Border.all(
              color: denied
                  ? AppTheme.accentError.withValues(alpha: 0.4)
                  : AppTheme.glassAccent.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: SizedBox(
            width: 56,
            child: loading
                ? const Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: AppTheme.glassAccent,
                      ),
                    ),
                  )
                : Text(
                    denied ? 'Retry' : 'Allow',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyStrong.copyWith(
                      color: denied ? AppTheme.accentError : AppTheme.glassAccent,
                      fontSize: 13,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
