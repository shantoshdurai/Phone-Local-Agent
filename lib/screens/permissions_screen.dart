import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/launch.dart';
import '../services/utility_service.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'mode_selection_screen.dart';

class _PermItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final Future<Permission?> Function() permission;
  bool granted = false;

  _PermItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.permission,
  });
}

/// 02 · Permissions — step 1 of 2. Shows the real grant state of each
/// runtime permission; everything is optional and can be changed later.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  static Future<Permission?> _photos() async {
    if (!Platform.isAndroid) return Permission.photos;
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    return sdk >= 33 ? Permission.photos : Permission.storage;
  }

  late final List<_PermItem> _items = [
    _PermItem(
      icon: Icons.mic_none_rounded,
      title: 'Microphone',
      subtitle: 'Talk to the agent and use voice mode.',
      permission: () async => Permission.microphone,
    ),
    _PermItem(
      icon: Icons.image_outlined,
      title: 'Photos & media',
      subtitle: 'Find screenshots and send images to the agent.',
      permission: _photos,
    ),
    _PermItem(
      icon: Icons.contacts_outlined,
      title: 'Contacts',
      subtitle: 'Call or message people by name.',
      permission: () async => Permission.contacts,
    ),
    _PermItem(
      icon: Icons.event_outlined,
      title: 'Calendar',
      subtitle: 'Add events when you ask.',
      permission: () async => Permission.calendarFullAccess,
    ),
    _PermItem(
      icon: Icons.notifications_none_rounded,
      title: 'Notification access',
      subtitle: 'Read your notifications out when you ask. Opens a system screen.',
      permission: () async => null, // special access, not a runtime permission
    ),
  ];

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final item in _items) {
      final permission = await item.permission();
      item.granted = permission == null
          ? await UtilityService().hasNotificationAccess()
          : (await permission.status).isGranted || (await permission.status).isLimited;
    }
    if (mounted) setState(() {});
  }

  Future<void> _request(_PermItem item) async {
    final permission = await item.permission();
    if (permission == null) {
      await UtilityService().requestNotificationAccess();
    } else {
      final status = await permission.request();
      if (status.isPermanentlyDenied && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${item.title} is blocked. Enable it in the app\'s system settings.'),
          action: SnackBarAction(label: 'Open', onPressed: openAppSettings),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
    await _refresh();
  }

  Future<void> _allowAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    for (final item in _items) {
      if (item.granted) continue;
      final permission = await item.permission();
      if (permission != null) await permission.request();
    }
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    _continue();
  }

  void _continue() {
    Navigator.of(context).pushReplacement(fadeRoute(const ModeSelectionScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Eyebrow('STEP 1 OF 2'),
              const SizedBox(height: 14),
              Text('A few permissions',
                  style: GoogleFonts.interTight(
                      fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.8, color: AppTheme.ink)),
              const SizedBox(height: 6),
              Text(
                'All optional — each unlocks a feature. You can change them any time in Android settings.',
                style: GoogleFonts.interTight(fontSize: 14, height: 1.55, color: AppTheme.ink2),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: ListView.separated(
                  physics: const BouncingScrollPhysics(),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _row(_items[i]),
                ),
              ),
              const SizedBox(height: 18),
              PrimaryButton(onPressed: _busy ? null : _allowAll, label: 'Allow & continue', isLoading: _busy),
              const SizedBox(height: 10),
              SecondaryButton(onPressed: _busy ? null : _continue, label: 'Skip for now'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(_PermItem item) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: item.granted ? null : () => _request(item),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            Icon(item.icon, color: AppTheme.ink, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      style: GoogleFonts.interTight(fontSize: 14, color: AppTheme.ink, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(item.subtitle,
                      style: GoogleFonts.interTight(fontSize: 12, color: AppTheme.ink2, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            item.granted
                ? const Pill('ALLOWED', style: PillStyle.success)
                : const Pill('ALLOW', style: PillStyle.outline),
          ],
        ),
      ),
    );
  }
}
