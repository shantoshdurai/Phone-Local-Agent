import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'design_components.dart';

/// Theme picker: each palette with its colour dots.
Future<void> showAppearanceSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, scroll) => ValueListenableBuilder<AppPalette>(
          valueListenable: ThemeController.instance,
          builder: (context, current, _) {
            final dark = AppPalettes.all.where((p) => p.isDark).toList();
            final light = AppPalettes.all.where((p) => !p.isDark).toList();
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text('Appearance',
                      style: GoogleFonts.interTight(fontSize: 17, fontWeight: FontWeight.w600, color: AppTheme.ink)),
                ),
                const SectionHeader('DARK'),
                for (final p in dark) _row(p, current),
                const SectionHeader('LIGHT'),
                for (final p in light) _row(p, current),
              ],
            );
          },
        ),
      ),
    );

Widget _row(AppPalette p, AppPalette current) {
  final selected = p.id == current.id;
  return Material(
    color: selected ? AppTheme.surface2 : Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => ThemeController.instance.select(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(p.name,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppTheme.primary : AppTheme.ink,
                  )),
            ),
            for (final c in p.swatch)
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
              child: selected ? Icon(Icons.check_circle_rounded, size: 20, color: AppTheme.primary) : null,
            ),
          ],
        ),
      ),
    ),
  );
}
