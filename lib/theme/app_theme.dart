import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens — mirrors `styles.css` from the Phone Local Agent design.
///
/// Token names are kept under their existing `glass*` aliases for backwards
/// compatibility with screens that haven't migrated yet, but the values are
/// the design-system values verbatim.
class AppTheme {
  AppTheme._();

  // ── Surface ─────────────────────────────────────────────────────────────
  static const Color bg          = Color(0xFF000000);
  static const Color bg2         = Color(0xFF0A0A0A);
  static const Color surface     = Color(0xFF111111);
  static const Color surface2    = Color(0xFF1A1A1A);
  static const Color surface3    = Color(0xFF222222);
  static const Color border      = Color(0xFF2A2A2A);
  static const Color border2     = Color(0xFF333333);

  // ── Ink ─────────────────────────────────────────────────────────────────
  static const Color ink         = Color(0xFFECECEC);
  static const Color ink2        = Color(0xFFA0A0A0);
  static const Color muted       = Color(0xFF707070);
  static const Color muted2      = Color(0xFF4A4A4A);

  // ── Accents ─────────────────────────────────────────────────────────────
  static const Color accent      = Color(0xFFFFFFFF);
  static const Color success     = Color(0xFF4CAF50);
  static const Color successInk  = Color(0xFF66BB6A);
  static const Color error       = Color(0xFFE53935);
  static const Color userBubble  = Color(0xFF2F2F2F);
  static const Color composerBg  = Color(0xFF242424);

  // ── Backwards-compat aliases (legacy `glass*` names used across screens)
  static const Color glassBg         = bg;
  static const Color glassBg2        = bg2;
  static const Color glassSurface    = surface;
  static const Color glassSurface2   = surface2;
  static const Color glassSurface3   = surface3;
  static const Color glassBorder     = border;
  static const Color glassBorder2    = border2;
  static const Color glassInk        = ink;
  static const Color glassInk2       = ink2;
  static const Color glassMuted      = muted;
  static const Color glassAccent     = accent;
  static const Color glassAccent2    = Color(0xFFDDDDDD);
  static const Color glassAccentGlow = Color(0x00000000);
  static const Color glassMagenta    = Color(0xFFE2E2E2);
  static const Color glassCyan       = Color(0xFFD4D4D4);
  static const Color accentSuccess   = success;
  static const Color accentError     = error;

  static TextTheme _textTheme(Color color) {
    return TextTheme(
      displayLarge:  GoogleFonts.interTight(fontSize: 42, fontWeight: FontWeight.w600, color: color, letterSpacing: -1.4, height: 1.05),
      displayMedium: GoogleFonts.interTight(fontSize: 32, fontWeight: FontWeight.w600, color: color, letterSpacing: -1.0, height: 1.1),
      displaySmall:  GoogleFonts.interTight(fontSize: 28, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.8, height: 1.1),
      headlineLarge: GoogleFonts.interTight(fontSize: 24, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.5),
      headlineMedium: GoogleFonts.interTight(fontSize: 20, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.4),
      headlineSmall: GoogleFonts.interTight(fontSize: 18, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.3),
      titleLarge:    GoogleFonts.interTight(fontSize: 17, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.3),
      titleMedium:   GoogleFonts.interTight(fontSize: 16, fontWeight: FontWeight.w600, color: color, letterSpacing: -0.2),
      titleSmall:    GoogleFonts.interTight(fontSize: 14, fontWeight: FontWeight.w500, color: color),
      bodyLarge:     GoogleFonts.interTight(fontSize: 15, color: color, height: 1.55),
      bodyMedium:    GoogleFonts.interTight(fontSize: 14, color: color, height: 1.55),
      bodySmall:     GoogleFonts.interTight(fontSize: 12, color: color, height: 1.5),
      labelLarge:    GoogleFonts.interTight(fontSize: 14, fontWeight: FontWeight.w600, color: color),
      labelMedium:   GoogleFonts.interTight(fontSize: 12, fontWeight: FontWeight.w500, color: color),
      labelSmall:    GoogleFonts.interTight(fontSize: 11, fontWeight: FontWeight.w500, color: color),
    );
  }

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        primaryColor: accent,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: Color(0xFFDDDDDD),
          surface: bg,
          surfaceContainerHighest: surface,
          error: error,
          onPrimary: bg,
          onSecondary: bg,
          onSurface: ink,
          onError: Colors.white,
        ),
        textTheme: _textTheme(ink),
        appBarTheme: AppBarTheme(
          backgroundColor: bg,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(color: ink),
          titleTextStyle: GoogleFonts.interTight(
            fontSize: 17, fontWeight: FontWeight.w600, color: ink, letterSpacing: -0.3,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: ink, width: 1.5),
          ),
          hintStyle: const TextStyle(color: muted),
          labelStyle: const TextStyle(color: ink2),
        ),
        dividerColor: border,
        hintColor: muted,
        useMaterial3: true,
      );
}

/// Typography helpers — used by older code; the new design components below
/// also expose semantically named text styles (eyebrow, hDisplay, etc.).
class AppTextStyles {
  AppTextStyles._();

  static TextStyle get hDisplay => GoogleFonts.interTight(
        fontSize: 42, fontWeight: FontWeight.w600, letterSpacing: -1.4, height: 1.05, color: AppTheme.ink,
      );
  static TextStyle get hTitle => GoogleFonts.interTight(
        fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.8, height: 1.1, color: AppTheme.ink,
      );
  static TextStyle get hSection => GoogleFonts.interTight(
        fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.4, color: AppTheme.ink,
      );
  static TextStyle get heading => hTitle;
  static TextStyle get title => GoogleFonts.interTight(
        fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: AppTheme.ink,
      );
  static TextStyle get body => GoogleFonts.interTight(
        fontSize: 14, fontWeight: FontWeight.w400, height: 1.55, color: AppTheme.ink2,
      );
  static TextStyle get bodyStrong => GoogleFonts.interTight(
        fontSize: 14, fontWeight: FontWeight.w600, height: 1.55, color: AppTheme.ink,
      );
  static TextStyle get small => GoogleFonts.interTight(
        fontSize: 12, fontWeight: FontWeight.w400, color: AppTheme.ink2,
      );
  static TextStyle get eyebrow => GoogleFonts.jetBrainsMono(
        fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 1.6, color: AppTheme.muted,
      );
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
        fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 1.0, color: AppTheme.ink2,
      );
  static TextStyle get monoBadge => GoogleFonts.jetBrainsMono(
        fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: AppTheme.ink2,
      );
}
