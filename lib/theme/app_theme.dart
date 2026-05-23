import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dark-only minimalist theme, redesigned for luxury typography and flat UI.
class AppTheme {
  AppTheme._();

  // ── Surface tokens ───────────────────────────────────────────────────────
  static const Color glassBg         = Color(0xFF000000); // True black
  static const Color glassBg2        = Color(0xFF111111); // Deep gray
  static const Color glassSurface    = Color(0xFF1A1A1A); // Lighter gray for inputs
  static const Color glassSurface2   = Color(0xFF222222); 
  static const Color glassBorder     = Color(0xFF2A2A2A); // Crisp 1px strokes
  static const Color glassBorder2    = Color(0xFF333333); 

  // ── Ink tokens ───────────────────────────────────────────────────────────
  static const Color glassInk        = Color(0xFFECECEC); // High contrast text
  static const Color glassInk2       = Color(0xFFA0A0A0); // Secondary text
  static const Color glassMuted      = Color(0xFF707070); // Placeholder/subtle

  // ── Accent tokens ────────────────────────────────────────────────────────
  static const Color glassAccent     = Color(0xFFFFFFFF); // White accents
  static const Color glassAccent2    = Color(0xFFDDDDDD);
  static const Color glassAccentGlow = Color(0x00000000); // No glow

  // System accents
  static const Color glassMagenta    = Color(0xFFE2E2E2); // Monochromatic fallback
  static const Color glassCyan       = Color(0xFFD4D4D4); 

  static const Color accentSuccess   = Color(0xFF4CAF50);
  static const Color accentError     = Color(0xFFE53935);

  static TextTheme _textTheme(Color displayColor, Color bodyColor) {
    return TextTheme(
      displayLarge:  GoogleFonts.inter(fontSize: 57, fontWeight: FontWeight.w600, color: displayColor, letterSpacing: -1.5),
      displayMedium: GoogleFonts.inter(fontSize: 45, fontWeight: FontWeight.w600, color: displayColor, letterSpacing: -1.0),
      displaySmall:  GoogleFonts.inter(fontSize: 36, fontWeight: FontWeight.w500, color: displayColor, letterSpacing: -0.5),
      headlineLarge:  GoogleFonts.inter(fontSize: 32, fontWeight: FontWeight.w600, color: displayColor, letterSpacing: -0.5),
      headlineMedium: GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w500, color: displayColor),
      headlineSmall:  GoogleFonts.inter(fontSize: 24, fontWeight: FontWeight.w500, color: displayColor),
      titleLarge:  GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w600, color: bodyColor),
      titleMedium: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w500, letterSpacing: 0.15, color: bodyColor),
      titleSmall:  GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.1, color: bodyColor),
      bodyLarge:   GoogleFonts.inter(fontSize: 16, color: bodyColor, height: 1.6),
      bodyMedium:  GoogleFonts.inter(fontSize: 14, color: bodyColor, height: 1.5),
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
          surface: glassBg,
          surfaceContainerHighest: glassSurface,
          error: accentError,
          onPrimary: Colors.black,
          onSecondary: Colors.black,
          onSurface: glassInk,
          onError: Colors.white,
        ),
        textTheme: _textTheme(glassInk, glassInk),
        appBarTheme: AppBarTheme(
          backgroundColor: glassBg,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(color: glassInk),
          titleTextStyle: GoogleFonts.inter(
            fontSize: 18, fontWeight: FontWeight.w600, color: glassInk, letterSpacing: -0.3
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: glassSurface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: glassInk, width: 1.5),
          ),
          hintStyle: const TextStyle(color: glassMuted),
          labelStyle: const TextStyle(color: glassInk2),
        ),
        dividerColor: glassBorder,
        hintColor: glassMuted,
        useMaterial3: true,
      );
}

/// Typography helpers
class AppTextStyles {
  AppTextStyles._();

  static TextStyle get heading => GoogleFonts.inter(
        fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.8,
      );
  static TextStyle get title => GoogleFonts.inter(
        fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.5,
      );
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 15, fontWeight: FontWeight.w400, height: 1.6,
      );
  static TextStyle get bodyStrong => GoogleFonts.inter(
        fontSize: 15, fontWeight: FontWeight.w600, height: 1.6,
      );
  static TextStyle get small => GoogleFonts.inter(
        fontSize: 13, fontWeight: FontWeight.w400, letterSpacing: 0.1,
      );
  // JetBrains Mono — section labels, model tags, step indicators.
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
        fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 1.0,
      );
  static TextStyle get monoBadge => GoogleFonts.jetBrainsMono(
        fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5,
      );
}
