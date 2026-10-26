import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// A named colour scheme. Screens read colours through [AppTheme], which
/// resolves them from [AppTheme.palette] at build time — switching palette only
/// rebuilds the tree, it doesn't change every call site.
class AppPalette {
  final String id;
  final String name;
  final bool isDark;

  final Color bg;
  final Color bg2;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color border;
  final Color border2;

  final Color ink;
  final Color ink2;
  final Color muted;
  final Color muted2;

  final Color accent;
  final Color success;
  final Color successInk;
  final Color error;
  final Color userBubble;
  final Color composerBg;

  const AppPalette({
    required this.id,
    required this.name,
    required this.isDark,
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.border2,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.muted2,
    required this.accent,
    required this.success,
    required this.successInk,
    required this.error,
    required this.userBubble,
    required this.composerBg,
  });

  List<Color> get swatch => [bg, accent, ink];
}

class AppPalettes {
  AppPalettes._();

  static const obsidian = AppPalette(
    id: 'obsidian',
    name: 'Obsidian',
    isDark: true,
    bg: Color(0xFF000000),
    bg2: Color(0xFF0A0A0A),
    surface: Color(0xFF111111),
    surface2: Color(0xFF1A1A1A),
    surface3: Color(0xFF222222),
    border: Color(0xFF2A2A2A),
    border2: Color(0xFF333333),
    ink: Color(0xFFECECEC),
    ink2: Color(0xFFA0A0A0),
    muted: Color(0xFF707070),
    muted2: Color(0xFF4A4A4A),
    accent: Color(0xFFFFFFFF),
    success: Color(0xFF4CAF50),
    successInk: Color(0xFF66BB6A),
    error: Color(0xFFE53935),
    userBubble: Color(0xFF2F2F2F),
    composerBg: Color(0xFF242424),
  );

  static const slate = AppPalette(
    id: 'slate',
    name: 'Slate',
    isDark: true,
    bg: Color(0xFF0B0F14),
    bg2: Color(0xFF0F141A),
    surface: Color(0xFF141B23),
    surface2: Color(0xFF1B242E),
    surface3: Color(0xFF243040),
    border: Color(0xFF24303D),
    border2: Color(0xFF31404F),
    ink: Color(0xFFE6EDF3),
    ink2: Color(0xFF9FB0C0),
    muted: Color(0xFF6E8092),
    muted2: Color(0xFF48586A),
    accent: Color(0xFF8CC2FF),
    success: Color(0xFF43C08A),
    successInk: Color(0xFF6FE0AE),
    error: Color(0xFFFF6B6B),
    userBubble: Color(0xFF22303F),
    composerBg: Color(0xFF1B2632),
  );

  static const forest = AppPalette(
    id: 'forest',
    name: 'Forest',
    isDark: true,
    bg: Color(0xFF07100B),
    bg2: Color(0xFF0A150F),
    surface: Color(0xFF0F1B14),
    surface2: Color(0xFF16261C),
    surface3: Color(0xFF1E3326),
    border: Color(0xFF1E3326),
    border2: Color(0xFF2A4433),
    ink: Color(0xFFE8F1EA),
    ink2: Color(0xFFA6BCAA),
    muted: Color(0xFF6F8A74),
    muted2: Color(0xFF476050),
    accent: Color(0xFF7BE0A3),
    success: Color(0xFF4CAF50),
    successInk: Color(0xFF7BE0A3),
    error: Color(0xFFE5645C),
    userBubble: Color(0xFF1B2F22),
    composerBg: Color(0xFF16261C),
  );

  static const ember = AppPalette(
    id: 'ember',
    name: 'Ember',
    isDark: true,
    bg: Color(0xFF0F0A08),
    bg2: Color(0xFF150D0A),
    surface: Color(0xFF1B120E),
    surface2: Color(0xFF251812),
    surface3: Color(0xFF33221A),
    border: Color(0xFF33221A),
    border2: Color(0xFF4A3125),
    ink: Color(0xFFF3E9E2),
    ink2: Color(0xFFC4AFA2),
    muted: Color(0xFF8E7466),
    muted2: Color(0xFF5F4B40),
    accent: Color(0xFFFF9E6D),
    success: Color(0xFF58B88A),
    successInk: Color(0xFF7CD9A8),
    error: Color(0xFFFF6B5E),
    userBubble: Color(0xFF2A1B14),
    composerBg: Color(0xFF251812),
  );

  static const violet = AppPalette(
    id: 'violet',
    name: 'Violet',
    isDark: true,
    bg: Color(0xFF0A0810),
    bg2: Color(0xFF0E0B16),
    surface: Color(0xFF14101F),
    surface2: Color(0xFF1C1629),
    surface3: Color(0xFF271F38),
    border: Color(0xFF271F38),
    border2: Color(0xFF3A2F52),
    ink: Color(0xFFEFEAF7),
    ink2: Color(0xFFB7AECB),
    muted: Color(0xFF807596),
    muted2: Color(0xFF504866),
    accent: Color(0xFFB79CFF),
    success: Color(0xFF52C39A),
    successInk: Color(0xFF77E2B9),
    error: Color(0xFFFF6F8A),
    userBubble: Color(0xFF221A33),
    composerBg: Color(0xFF1C1629),
  );

  static const List<AppPalette> all = [obsidian, slate, forest, ember, violet];

  static AppPalette byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => obsidian);
}

/// Design tokens, resolved from the active palette.
class AppTheme {
  AppTheme._();

  static AppPalette palette = AppPalettes.obsidian;

  static Color get bg => palette.bg;
  static Color get bg2 => palette.bg2;
  static Color get surface => palette.surface;
  static Color get surface2 => palette.surface2;
  static Color get surface3 => palette.surface3;
  static Color get border => palette.border;
  static Color get border2 => palette.border2;

  static Color get ink => palette.ink;
  static Color get ink2 => palette.ink2;
  static Color get muted => palette.muted;
  static Color get muted2 => palette.muted2;

  static Color get accent => palette.accent;
  static Color get primary => palette.accent;
  static Color get success => palette.success;
  static Color get successInk => palette.successInk;
  static Color get error => palette.error;
  static Color get userBubble => palette.userBubble;
  static Color get composerBg => palette.composerBg;

  // Legacy aliases.
  static Color get glassBg => bg;
  static Color get glassBg2 => bg2;
  static Color get glassSurface => surface;
  static Color get glassSurface2 => surface2;
  static Color get glassSurface3 => surface3;
  static Color get glassBorder => border;
  static Color get glassBorder2 => border2;
  static Color get glassInk => ink;
  static Color get glassInk2 => ink2;
  static Color get glassMuted => muted;
  static Color get glassAccent => accent;
  static Color get glassAccent2 => ink2;
  static Color get glassAccentGlow => Colors.transparent;
  static Color get glassMagenta => ink;
  static Color get glassCyan => ink2;
  static Color get accentSuccess => success;
  static Color get accentError => error;

  static SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            palette.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness:
            palette.isDark ? Brightness.light : Brightness.dark,
      );

  static TextTheme _textTheme(Color color) => TextTheme(
        displayLarge: GoogleFonts.interTight(
            fontSize: 42,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -1.4,
            height: 1.05),
        displayMedium: GoogleFonts.interTight(
            fontSize: 32,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -1.0,
            height: 1.1),
        displaySmall: GoogleFonts.interTight(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.8,
            height: 1.1),
        headlineLarge: GoogleFonts.interTight(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.5),
        headlineMedium: GoogleFonts.interTight(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.4),
        headlineSmall: GoogleFonts.interTight(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.3),
        titleLarge: GoogleFonts.interTight(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.3),
        titleMedium: GoogleFonts.interTight(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: -0.2),
        titleSmall: GoogleFonts.interTight(
            fontSize: 14, fontWeight: FontWeight.w500, color: color),
        bodyLarge:
            GoogleFonts.interTight(fontSize: 15, color: color, height: 1.55),
        bodyMedium:
            GoogleFonts.interTight(fontSize: 14, color: color, height: 1.55),
        bodySmall:
            GoogleFonts.interTight(fontSize: 12, color: color, height: 1.5),
        labelLarge: GoogleFonts.interTight(
            fontSize: 14, fontWeight: FontWeight.w600, color: color),
        labelMedium: GoogleFonts.interTight(
            fontSize: 12, fontWeight: FontWeight.w500, color: color),
        labelSmall: GoogleFonts.interTight(
            fontSize: 11, fontWeight: FontWeight.w500, color: color),
      );

  static ThemeData get darkTheme => ThemeData(
        brightness: palette.isDark ? Brightness.dark : Brightness.light,
        primaryColor: accent,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme(
          brightness: palette.isDark ? Brightness.dark : Brightness.light,
          primary: accent,
          onPrimary: bg,
          secondary: ink2,
          onSecondary: bg,
          surface: bg,
          onSurface: ink,
          error: error,
          onError: Colors.white,
        ),
        textTheme: _textTheme(ink),
        appBarTheme: AppBarTheme(
          backgroundColor: bg,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: ink),
          titleTextStyle: GoogleFonts.interTight(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: ink,
            letterSpacing: -0.3,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: ink, width: 1.5),
          ),
          hintStyle: TextStyle(color: muted),
          labelStyle: TextStyle(color: ink2),
        ),
        dividerColor: border,
        hintColor: muted,
        useMaterial3: true,
      );
}

class AppTextStyles {
  AppTextStyles._();

  static TextStyle get hDisplay => GoogleFonts.interTight(
      fontSize: 42,
      fontWeight: FontWeight.w600,
      letterSpacing: -1.4,
      height: 1.05,
      color: AppTheme.ink);
  static TextStyle get hTitle => GoogleFonts.interTight(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.8,
      height: 1.1,
      color: AppTheme.ink);
  static TextStyle get hSection => GoogleFonts.interTight(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.4,
      color: AppTheme.ink);
  static TextStyle get heading => hTitle;
  static TextStyle get title => GoogleFonts.interTight(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: AppTheme.ink);
  static TextStyle get body => GoogleFonts.interTight(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: AppTheme.ink2);
  static TextStyle get bodyStrong => GoogleFonts.interTight(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.55,
      color: AppTheme.ink);
  static TextStyle get small => GoogleFonts.interTight(
      fontSize: 12, fontWeight: FontWeight.w400, color: AppTheme.ink2);
  static TextStyle get eyebrow => GoogleFonts.jetBrainsMono(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.6,
      color: AppTheme.muted);
  static TextStyle get mono => GoogleFonts.jetBrainsMono(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.0,
      color: AppTheme.ink2);
  static TextStyle get monoBadge => GoogleFonts.jetBrainsMono(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: AppTheme.ink2);
}
