import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/app_theme.dart';
import '../widgets/design_components.dart';
import 'mode_selection_screen.dart';

enum _PermState { granted, optional, ask }

class _PermItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final String permKey; // logical key for _platformRequest
  _PermState state;
  _PermItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.permKey,
    this.state = _PermState.ask,
  });
}

/// 02 · Permissions — STEP 01/02 of onboarding.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final List<_PermItem> _perms = [
    _PermItem(
      icon: Icons.folder_outlined,
      title: 'Files & storage',
      subtitle: 'Read, organize, and search documents.',
      permKey: 'storage',
    ),
    _PermItem(
      icon: Icons.grid_view_rounded,
      title: 'Installed apps',
      subtitle: 'List, open, and manage applications.',
      permKey: 'apps',
    ),
    _PermItem(
      icon: Icons.image_outlined,
      title: 'Photos & screenshots',
      subtitle: 'Analyze images with on-device vision.',
      permKey: 'photos',
    ),
    _PermItem(
      icon: Icons.mic_none_rounded,
      title: 'Microphone',
      subtitle: 'Voice input and speech-to-text.',
      permKey: 'microphone',
    ),
    _PermItem(
      icon: Icons.public_rounded,
      title: 'Network',
      subtitle: 'Required for downloading tools and packages.',
      permKey: 'network',
      state: _PermState.optional,
    ),
    _PermItem(
      icon: Icons.bolt_rounded,
      title: 'Device settings',
      subtitle: 'Flashlight, vibration, volume, brightness.',
      permKey: 'device',
    ),
  ];

  bool _busy = false;

  Future<bool> _platformRequest(String key) async {
    try {
      switch (key) {
        case 'storage':
          if (Platform.isAndroid) {
            final m = await Permission.manageExternalStorage.request();
            if (m.isGranted) return true;
            return (await Permission.storage.request()).isGranted;
          }
          return true;
        case 'photos':
          if (Platform.isAndroid) {
            final p = await Permission.photos.request();
            return p.isGranted || (await Permission.storage.request()).isGranted;
          }
          return (await Permission.photos.request()).isGranted;
        case 'microphone':
          return (await Permission.microphone.request()).isGranted;
        case 'apps':
        case 'network':
        case 'device':
          // Not real Android permissions — installed_apps queryable apps,
          // INTERNET (auto-granted), and settings actions don't need runtime
          // grants. Treat as ok.
          return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _grantAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    for (final p in _perms) {
      if (p.state == _PermState.granted) continue;
      final ok = await _platformRequest(p.permKey);
      if (!mounted) return;
      setState(() => p.state = ok ? _PermState.granted : _PermState.ask);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _continue();
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
              const Eyebrow('STEP 01 / 02'),
              const SizedBox(height: 14),
              Text(
                'A few permissions.',
                style: GoogleFonts.interTight(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.8,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Local Agent needs these to act on your phone. Everything happens on-device.',
                style: GoogleFonts.interTight(
                  fontSize: 14,
                  height: 1.55,
                  color: AppTheme.ink2,
                ),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: ListView.separated(
                  physics: const BouncingScrollPhysics(),
                  itemCount: _perms.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _permRow(_perms[i]),
                ),
              ),
              const SizedBox(height: 18),
              PrimaryButton(
                onPressed: _busy ? null : _grantAll,
                label: 'Grant All & Continue',
                isLoading: _busy,
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                onPressed: _busy ? null : _continue,
                label: 'Decide Later',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _permRow(_PermItem p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(p.icon, color: AppTheme.ink, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.title,
                  style: GoogleFonts.interTight(
                    fontSize: 14,
                    color: AppTheme.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  p.subtitle,
                  style: GoogleFonts.interTight(
                    fontSize: 12,
                    color: AppTheme.ink2,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Pill(
            p.state == _PermState.granted
                ? 'GRANTED'
                : (p.state == _PermState.optional ? 'OPTIONAL' : 'ASK'),
            style: p.state == _PermState.granted
                ? PillStyle.success
                : PillStyle.surface,
          ),
        ],
      ),
    );
  }
}
