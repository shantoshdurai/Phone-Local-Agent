import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dark-only Glass theme, ported from ClassNow. Local Agent doesn't ship a
/// light mode — the chat surface relies on the aurora background for depth,
/// which only works on the dark canvas.
class AppTheme {
  AppTheme._();

  // ── Surface tokens ───────────────────────────────────────────────────────
  static const Color glassBg         = Color(0xFF07080B);
  static const Color glassBg2        = Color(0xFF0C0E14);
  static const Color glassSurface    = Color(0x0DFFFFFF); // ~5%
  static const Color glassSurface2   = Color(0x14FFFFFF); // ~8%
  static const Color glassBorder     = Color(0x1AFFFFFF); // ~10%
  static const Color glassBorder2    = Color(0x2BFFFFFF); // ~17%

  // ── Ink tokens ───────────────────────────────────────────────────────────
  static const Color glassInk        = Color(0xFFF8F9FB);
  static const Color glassInk2       = Color(0xFFC5C7D0);
  static const Color glassMuted      = Color(0xFF7A7D8A);

  // ── Accent tokens ────────────────────────────────────────────────────────
  static const Color glassAccent     = Color(0xFF4DB6FF);
  static const Color glassAccent2    = Color(0xFF63D9FF);
  static const Color glassAccentGlow = Color(0x664DB6FF);

  // Magenta + cyan companion blobs used by the aurora background.
  static const Color glassMagenta    = Color(0xFFB066FF);
  static const Color glassCyan       = Color(0xFF00F0FF);

  static const Color accentSuccess   = Color(0xFF34D399);
  static const Color accentError     = Color(0xFFF87171);

  static TextTheme _textTheme(Color displayColor, Color bodyColor) {
    return TextTheme(
      displayLarge:  GoogleFonts.fraunces(fontSize: 57, fontWeight: FontWeight.w600, color: displayColor),
      displayMedium: GoogleFonts.fraunces(fontSize: 45, fontWeight: FontWeight.w600, color: displayColor),
      displaySmall:  GoogleFonts.fraunces(fontSize: 36, fontWeight: FontWeight.w500, color: displayColor),
      headlineLarge:  GoogleFonts.fraunces(fontSize: 32, fontWeight: FontWeight.w600, color: displayColor),
      headlineMedium: GoogleFonts.fraunces(fontSize: 28, fontWeight: FontWeight.w500, color: displayColor),
      headlineSmall:  GoogleFonts.fraunces(fontSize: 24, fontWeight: FontWeight.w500, color: displayColor),
      titleLarge:  GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w600, color: bodyColor),
      titleMedium: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: 0.15, color: bodyColor),
      titleSmall:  GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.1, color: bodyColor),
      bodyLarge:   GoogleFonts.inter(fontSize: 16, color: bodyColor),
      bodyMedium:  GoogleFonts.inter(fontSize: 14, color: bodyColor),
      bodySmall:   GoogleFonts.inter(fontSize: 12, color: bodyColor),
      labelLarge:  GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: bodyColor),
      labelMedium: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: bodyColor),
      labelSmall:  GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: bodyColor),
    );
  }

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        primaryColor: glassAccent,
        scaffoldBackgroundColor: glassBg,
        colorScheme: const ColorScheme.dark(
          primary: glassAccent,
          secondary: glassAccent2,
          surface: glassBg2,
          surfaceContainerHighest: glassSurface2,
          error: accentError,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: glassInk,
          onError: Colors.white,
        ),
        textTheme: _textTheme(glassInk, glassInk),
        appBarTheme: AppBarTheme(
          backgroundColor: glassBg,
          elevation: 0,
          iconTheme: const IconThemeData(color: glassAccent),
          titleTextStyle: GoogleFonts.fraunces(
            fontSize: 22, fontWeight: FontWeight.w500, color: glassInk,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: glassSurface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: glassAccent, width: 2),
          ),
          hintStyle: const TextStyle(color: glassMuted),
          labelStyle: const TextStyle(color: glassInk2),
        ),
        dividerColor: glassBorder,
        hintColor: glassMuted,
        useMaterial3: true,
      );
}

/// Typography helpers — used directly where Theme.textTheme doesn't fit
/// the design intent (e.g. mono badges, all-caps section labels).
class AppTextStyles {
  AppTextStyles._();

  static TextStyle get heading => GoogleFonts.fraunces(
        fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.6,
      );
  static TextStyle get title => GoogleFonts.fraunces(
        fontSize: 22, fontWeight: FontWeight.w500, letterSpacing: -0.3,
      );
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 14, fontWeight: FontWeight.w400, height: 1.5,
      );
  static TextStyle get bodyStrong => GoogleFonts.inter(
        fontSize: 14, fontWeight: FontWeight.w600,
      );
  static TextStyle get small => GoogleFonts.inter(
        fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0.1,
      );
  // JetBrains Mono — section labels, model tags, step indicators.
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
        fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 1.4,
      );
  static TextStyle get monoBadge => GoogleFonts.jetBrainsMono(
        fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6,
      );
}
