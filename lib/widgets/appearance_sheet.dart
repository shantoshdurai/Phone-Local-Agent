import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';

/// Bottom sheet with the available palettes and their colour dots.
Future<void> showAppearanceSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ValueListenableBuilder<AppPalette>(
          valueListenable: ThemeController.instance,
          builder: (context, current, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.border2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Appearance',
                  style: GoogleFonts.interTight(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                for (final palette in AppPalettes.all)
                  _row(palette, current),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      ),
    );

Widget _row(AppPalette palette, AppPalette current) {
  final selected = palette.id == current.id;
  return Material(
    color: selected ? AppTheme.surface2 : Colors.transparent,
    child: InkWell(
      onTap: () => ThemeController.instance.select(palette),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                palette.name,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.accent : AppTheme.ink,
                ),
              ),
            ),
            for (final c in palette.swatch)
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(left: 6),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.border2),
                ),
              ),
            const SizedBox(width: 12),
            SizedBox(
              width: 22,
              child: selected
                  ? Icon(Icons.check_circle_rounded,
                      size: 20, color: AppTheme.accent)
                  : null,
            ),
          ],
        ),
      ),
    ),
  );
}
