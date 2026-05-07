import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'api_setup_screen.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  void _showComingSoon(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Coming Soon', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Running a local LLM natively on Android is highly experimental and currently in development. Please use the Cloud Agent (Gemini API) for now.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it', style: TextStyle(color: Color(0xFF00FFCC))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 60),
              const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 48),
              const SizedBox(height: 32),
              Text(
                'Welcome to\nLocal Agent',
                style: GoogleFonts.inter(
                  fontSize: 42,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  color: Colors.white,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Your personal, file-aware assistant.\nPrivate, local, and powerful.',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  color: Colors.white60,
                  height: 1.5,
                ),
              ),
              const Spacer(),
              _buildChoiceCard(
                context: context,
                title: 'Cloud Agent',
                description: 'Enable full autonomy with Groq or Gemini API.',
                icon: Icons.cloud_queue_rounded,
                isPrimary: true,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ApiSetupScreen()),
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildChoiceCard(
                context: context,
                title: 'Local Engine',
                description: 'Offline inference natively on your hardware.',
                icon: Icons.memory_rounded,
                isPrimary: false,
                badge: 'WIP',
                onTap: () => _showComingSoon(context),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChoiceCard({
    required BuildContext context,
    required String title,
    required String description,
    required IconData icon,
    required bool isPrimary,
    required VoidCallback onTap,
    String? badge,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          border: Border.all(
            color: isPrimary ? Colors.white24 : Colors.transparent,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.white38,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
