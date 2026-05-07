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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.psychology_rounded, color: Theme.of(context).colorScheme.secondary, size: 48),
              ),
              const SizedBox(height: 24),
              Text(
                'Welcome to\nLocal Agent',
                style: GoogleFonts.outfit(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  height: 1.1,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Your personal, file-aware AI assistant.\nChoose how you want to power your agent.',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  color: Colors.white.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
              const Spacer(),
              _buildChoiceCard(
                context: context,
                title: 'Cloud Agent (Gemini)',
                description: 'Fast, smart, and fully functional. Requires an internet connection and an API key.',
                icon: Icons.cloud_done_rounded,
                isPrimary: true,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ApiSetupScreen()),
                  );
                },
              ),
              const SizedBox(height: 16),
              _buildChoiceCard(
                context: context,
                title: 'Local Agent (Tiny LLM)',
                description: 'Private and offline. Runs completely on your device hardware.',
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
          color: isPrimary ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : const Color(0xFF1E1E24),
          border: Border.all(
            color: isPrimary ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5) : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isPrimary ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: isPrimary ? Theme.of(context).colorScheme.secondary : Colors.white54,
              ),
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
                        style: GoogleFonts.outfit(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.6),
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
