import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:device_calendar/device_calendar.dart';
import 'home_screen.dart';

enum PermStatus { pending, granted, denied }

class _PermItem {
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;
  PermStatus status;
  _PermItem({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.status = PermStatus.pending,
  });
}

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinished;
  const OnboardingScreen({super.key, required this.onFinished});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;
  late final List<Animation<double>> _fades;
  late final List<Animation<Offset>> _slides;

  bool _requesting = false;

  final List<_PermItem> _perms = [
    _PermItem(
      key: 'storage',
      icon: Icons.folder_rounded,
      title: 'Storage',
      subtitle: 'Save the model file and access local files for tools.',
    ),
    _PermItem(
      key: 'notification',
      icon: Icons.notifications_active_rounded,
      title: 'Notifications',
      subtitle: 'Keep inference running while the app is in the background.',
    ),
    _PermItem(
      key: 'microphone',
      icon: Icons.mic_rounded,
      title: 'Microphone',
      subtitle: 'Voice input — talk to the agent hands-free.',
    ),
    _PermItem(
      key: 'contacts',
      icon: Icons.contacts_rounded,
      title: 'Contacts',
      subtitle: 'Look up contacts when you ask the agent to find someone.',
    ),
    _PermItem(
      key: 'calendar',
      icon: Icons.event_rounded,
      title: 'Calendar',
      subtitle: 'Create and read events when you ask to schedule things.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    final n = 3 + _perms.length; // badge + header + perm-card + each row
    _fades = List.generate(n, (i) {
      final start = (i * 0.08).clamp(0.0, 1.0);
      final end = (start + 0.4).clamp(0.0, 1.0);
      return Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
        parent: _entrance,
        curve: Interval(start, end, curve: Curves.easeOut),
      ));
    });
    _slides = List.generate(n, (i) {
      final start = (i * 0.08).clamp(0.0, 1.0);
      final end = (start + 0.4).clamp(0.0, 1.0);
      return Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
          .animate(CurvedAnimation(
        parent: _entrance,
        curve: Interval(start, end, curve: Curves.easeOut),
      ));
    });
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Future<void> _requestAll() async {
    if (_requesting) return;
    setState(() => _requesting = true);

    for (final p in _perms) {
      final granted = await _requestOne(p.key);
      if (!mounted) return;
      setState(() {
        p.status = granted ? PermStatus.granted : PermStatus.denied;
      });
    }

    if (mounted) setState(() => _requesting = false);
  }

  Future<bool> _requestOne(String key) async {
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
          final r = await Permission.notification.request();
          return r.isGranted;
        case 'microphone':
          final r = await Permission.microphone.request();
          return r.isGranted;
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
    widget.onFinished();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  // ─── UI ───

  Widget _animated(int i, Widget child) {
    final idx = i.clamp(0, _fades.length - 1);
    return FadeTransition(
      opacity: _fades[idx],
      child: SlideTransition(position: _slides[idx], child: child),
    );
  }

  Widget _buildBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF3B82F6).withValues(alpha: 0.25),
            const Color(0xFF8B5CF6).withValues(alpha: 0.15),
          ],
        ),
        border:
            Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF3B82F6),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'WELCOME',
            style: GoogleFonts.outfit(
              color: const Color(0xFF93C5FD),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            colors: [Colors.white, Color(0xFFD1D5DB)],
          ).createShader(rect),
          child: Text(
            'Your private AI,\nrunning on-device',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Everything runs entirely on your phone — no cloud, no telemetry. '
          'Grant a few permissions so the agent can use the tools that make it useful.',
          style: GoogleFonts.outfit(
            color: Colors.white54,
            fontSize: 14,
            height: 1.6,
          ),
        ),
      ],
    );
  }

  Widget _permRow(_PermItem p) {
    final granted = p.status == PermStatus.granted;
    final denied = p.status == PermStatus.denied;
    final color = granted
        ? const Color(0xFF34D399)
        : denied
            ? const Color(0xFFF87171)
            : Colors.white38;
    final statusIcon = granted
        ? Icons.check_circle_rounded
        : denied
            ? Icons.cancel_rounded
            : Icons.radio_button_unchecked_rounded;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: granted || _requesting
          ? null
          : () async {
              final ok = await _requestOne(p.key);
              if (!mounted) return;
              setState(() {
                p.status = ok ? PermStatus.granted : PermStatus.denied;
              });
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(p.icon, color: Colors.white70, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.title,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    p.subtitle,
                    style: GoogleFonts.outfit(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(statusIcon, color: color, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildPermCard() {
    // Plain gradient — BackdropFilter blur was dropping frames on cold start.
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1A1A22),
            const Color(0xFF14141A),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PERMISSIONS',
                style: GoogleFonts.outfit(
                  color: Colors.white30,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _perms.length; i++)
                _animated(2 + i, _permRow(_perms[i])),
            ],
          ),
        );
  }

  Widget _buildButtons() {
    final allGranted =
        _perms.every((p) => p.status == PermStatus.granted);
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _requesting ? null : _requestAll,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _requesting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    allGranted ? 'Re-request permissions' : 'Grant permissions',
                    style: GoogleFonts.outfit(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: TextButton(
            onPressed: _requesting ? null : _continue,
            style: TextButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              foregroundColor: Colors.white70,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(
              allGranted ? 'Continue' : 'Continue anyway',
              style: GoogleFonts.outfit(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _animated(0, _buildBadge()),
              const SizedBox(height: 20),
              _animated(1, _buildHeader()),
              const SizedBox(height: 28),
              _animated(2, _buildPermCard()),
              const SizedBox(height: 24),
              _buildButtons(),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'You can change these later in system settings.',
                  style: GoogleFonts.outfit(
                    color: Colors.white30,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
