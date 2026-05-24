import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// Suggestion rows shown under the greeting on an empty chat. Each row is a
/// horizontal icon + text, ~14px vertical padding, no card chrome — matches
/// `.sug-list / .sug-row` in the design.
class SuggestionsList extends StatelessWidget {
  final List<Map<String, dynamic>> suggestions;
  final void Function(String) onSuggestionTap;

  const SuggestionsList({
    super.key,
    required this.suggestions,
    required this.onSuggestionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: suggestions.map((s) {
          return InkWell(
            onTap: () => onSuggestionTap(s['text'] as String),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Icon(s['icon'] as IconData, color: AppTheme.ink, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      s['text'] as String,
                      style: GoogleFonts.interTight(
                        fontSize: 15,
                        height: 1.45,
                        color: AppTheme.ink,
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
