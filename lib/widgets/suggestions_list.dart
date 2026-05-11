import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SuggestionsList extends StatelessWidget {
  final List<Map<String, dynamic>> suggestions;
  final Function(String) onSuggestionTap;

  const SuggestionsList({
    super.key,
    required this.suggestions,
    required this.onSuggestionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: suggestions.map((s) {
          return GestureDetector(
            onTap: () => onSuggestionTap(s['text']),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14.0),
              child: Row(
                children: [
                  Icon(s['icon'], color: Colors.white, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      s['text'],
                      style: GoogleFonts.outfit(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
