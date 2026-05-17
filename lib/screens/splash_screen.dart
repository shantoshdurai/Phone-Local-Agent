import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/agent_service.dart';
import 'chat_screen.dart';
import 'home_screen.dart';

/// Dedicated splash route. Owns the heavy model-load step so that ChatScreen
/// only mounts after FlutterGemma has finished initialising — that way the
/// chat UI doesn't have to compete with the platform thread for the first
/// few seconds of render time.
class SplashScreen extends StatefulWidget {
  final String modelFileName;
  const SplashScreen({super.key, required this.modelFileName});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    // Defer one frame so the spinner paints before native init starts.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadModel());
  }

  Future<void> _loadModel() async {
    try {
      await AgentService().initialize(widget.modelFileName);
      if (!mounted) return;
      // Cross-fade into chat so the transition feels seamless.
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, __, ___) =>
              ChatScreen(modelFileName: widget.modelFileName),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null) ...[
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Loading model…',
                  style: GoogleFonts.outfit(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'First open can take a few seconds',
                  style: GoogleFonts.outfit(
                    color: Colors.white.withValues(alpha: 0.32),
                    fontSize: 11,
                  ),
                ),
              ] else
                _buildError(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded,
              color: Colors.white.withValues(alpha: 0.5), size: 32),
          const SizedBox(height: 14),
          Text(
            'Couldn\'t load the model',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              color: Colors.white54,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: () {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
                (route) => false,
              );
            },
            child: Text(
              'Back to home',
              style: GoogleFonts.outfit(
                color: const Color(0xFF93C5FD),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
