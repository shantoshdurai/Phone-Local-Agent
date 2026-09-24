import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// A colour palette. Every screen reads its colours through [AppTheme], so a
/// palette swap restyles the whole app.
class AppPalette {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg, bg2, surface, surface2, surface3, border, border2;
  final Color ink, ink2, muted, muted2;

  /// Buttons, highlights, selected states.
  final Color primary, onPrimary;
  final Color success, successInk, error;
  final Color userBubble, composerBg;

  const AppPalette({
    required this.id,
    required this.name,
    this.brightness = Brightness.dark,
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
    required this.primary,
    required this.onPrimary,
    this.success = const Color(0xFF4CAF50),
    this.successInk = const Color(0xFF66BB6A),
    this.error = const Color(0xFFE53935),
    required this.userBubble,
    required this.composerBg,
  });

  bool get isDark => brightness == Brightness.dark;

  /// Three dots shown in the theme picker.
  List<Color> get swatch => [bg, surface3, primary];
}

class AppPalettes {
  AppPalettes._();

  /// The original design: black, white, nothing else.
  static const midnight = AppPalette(
    id: 'midnight', name: 'Midnight',
    bg: Color(0xFF000000), bg2: Color(0xFF0A0A0A), surface: Color(0xFF111111),
    surface2: Color(0xFF1A1A1A), surface3: Color(0xFF222222),
    border: Color(0xFF2A2A2A), border2: Color(0xFF333333),
    ink: Color(0xFFECECEC), ink2: Color(0xFFA0A0A0), muted: Color(0xFF707070), muted2: Color(0xFF4A4A4A),
    primary: Color(0xFFECECEC), onPrimary: Color(0xFF000000),
    userBubble: Color(0xFF2F2F2F), composerBg: Color(0xFF242424),
  );

  static const graphite = AppPalette(
    id: 'graphite', name: 'Graphite',
    bg: Color(0xFF16181D), bg2: Color(0xFF1B1E24), surface: Color(0xFF20242B),
    surface2: Color(0xFF272C34), surface3: Color(0xFF2F353F),
    border: Color(0xFF343B46), border2: Color(0xFF3F4754),
    ink: Color(0xFFE6E9EF), ink2: Color(0xFFA8B0BD), muted: Color(0xFF7B8494), muted2: Color(0xFF525B69),
    primary: Color(0xFF4C8DFF), onPrimary: Color(0xFFFFFFFF),
    userBubble: Color(0xFF2B3A55), composerBg: Color(0xFF232830),
  );

  static const emerald = AppPalette(
    id: 'emerald', name: 'Emerald',
    bg: Color(0xFF07110D), bg2: Color(0xFF0B1813), surface: Color(0xFF0F1F18),
    surface2: Color(0xFF14281F), surface3: Color(0xFF1A3227),
    border: Color(0xFF1F3A2E), border2: Color(0xFF28483A),
    ink: Color(0xFFE3F2EA), ink2: Color(0xFF9FC2B1), muted: Color(0xFF6E8F80), muted2: Color(0xFF44604F),
    primary: Color(0xFF2ECC8F), onPrimary: Color(0xFF04140D),
    userBubble: Color(0xFF17392B), composerBg: Color(0xFF12241C),
  );

  static const ocean = AppPalette(
    id: 'ocean', name: 'Ocean',
    bg: Color(0xFF06101C), bg2: Color(0xFF0A1726), surface: Color(0xFF0E1D30),
    surface2: Color(0xFF13263D), surface3: Color(0xFF19304B),
    border: Color(0xFF1E3857), border2: Color(0xFF284669),
    ink: Color(0xFFE2EEF9), ink2: Color(0xFF9DB6CF), muted: Color(0xFF6D86A1), muted2: Color(0xFF435A74),
    primary: Color(0xFF22C3EE), onPrimary: Color(0xFF03121C),
    userBubble: Color(0xFF163452), composerBg: Color(0xFF11223A),
  );

  static const sunset = AppPalette(
    id: 'sunset', name: 'Sunset',
    bg: Color(0xFF150D0B), bg2: Color(0xFF1C120F), surface: Color(0xFF241713),
    surface2: Color(0xFF2D1D18), surface3: Color(0xFF37241E),
    border: Color(0xFF3F2A22), border2: Color(0xFF4C342B),
    ink: Color(0xFFF6E9E2), ink2: Color(0xFFCDB2A6), muted: Color(0xFF9B7F73), muted2: Color(0xFF6A5147),
    primary: Color(0xFFFF7A45), onPrimary: Color(0xFF1A0B05),
    userBubble: Color(0xFF4A2A1E), composerBg: Color(0xFF2A1B16),
  );

  static const monokai = AppPalette(
    id: 'monokai', name: 'Monokai',
    bg: Color(0xFF1E1F1C), bg2: Color(0xFF232420), surface: Color(0xFF272822),
    surface2: Color(0xFF2F302A), surface3: Color(0xFF3A3B33),
    border: Color(0xFF3E3D32), border2: Color(0xFF49483E),
    ink: Color(0xFFF8F8F2), ink2: Color(0xFFCFCFC2), muted: Color(0xFF90908A), muted2: Color(0xFF75715E),
    primary: Color(0xFFFD971F), onPrimary: Color(0xFF1E1F1C),
    success: Color(0xFFA6E22E), successInk: Color(0xFFA6E22E), error: Color(0xFFF92672),
    userBubble: Color(0xFF3E3D32), composerBg: Color(0xFF2D2E27),
  );

  static const violet = AppPalette(
    id: 'violet', name: 'Violet',
    bg: Color(0xFF0F0B16), bg2: Color(0xFF140F1D), surface: Color(0xFF1A1426),
    surface2: Color(0xFF221A31), surface3: Color(0xFF2A213C),
    border: Color(0xFF30264A), border2: Color(0xFF3B2F59),
    ink: Color(0xFFEFE9FA), ink2: Color(0xFFB9ADD1), muted: Color(0xFF857A9E), muted2: Color(0xFF574C6F),
    primary: Color(0xFFA78BFA), onPrimary: Color(0xFF120A20),
    userBubble: Color(0xFF32265A), composerBg: Color(0xFF1E1830),
  );

  static const light = AppPalette(
    id: 'light', name: 'Light', brightness: Brightness.light,
    bg: Color(0xFFFFFFFF), bg2: Color(0xFFF6F7F9), surface: Color(0xFFF3F4F6),
    surface2: Color(0xFFECEEF1), surface3: Color(0xFFE3E6EA),
    border: Color(0xFFE2E5E9), border2: Color(0xFFD3D8DE),
    ink: Color(0xFF16181D), ink2: Color(0xFF4A5160), muted: Color(0xFF7A8292), muted2: Color(0xFFA9B0BC),
    primary: Color(0xFF2563EB), onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF16A34A), successInk: Color(0xFF15803D), error: Color(0xFFDC2626),
    userBubble: Color(0xFFE8EEFC), composerBg: Color(0xFFF1F3F6),
  );

  static const paper = AppPalette(
    id: 'paper', name: 'Paper', brightness: Brightness.light,
    bg: Color(0xFFFBF7EF), bg2: Color(0xFFF5EFE3), surface: Color(0xFFF2EADB),
    surface2: Color(0xFFEBE1CF), surface3: Color(0xFFE3D7C2),
    border: Color(0xFFE0D4BE), border2: Color(0xFFD2C3A9),
    ink: Color(0xFF2B2520), ink2: Color(0xFF5E544A), muted: Color(0xFF8C8173), muted2: Color(0xFFB3A796),
    primary: Color(0xFF8B5E34), onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF3F7D3A), successInk: Color(0xFF3F7D3A), error: Color(0xFFB3261E),
    userBubble: Color(0xFFEADFC9), composerBg: Color(0xFFF2EADB),
  );

  static const mist = AppPalette(
    id: 'mist', name: 'Mist', brightness: Brightness.light,
    bg: Color(0xFFEEF2F7), bg2: Color(0xFFE6ECF3), surface: Color(0xFFF7F9FC),
    surface2: Color(0xFFE1E8F1), surface3: Color(0xFFD7E0EC),
    border: Color(0xFFD3DCE8), border2: Color(0xFFC2CEDD),
    ink: Color(0xFF1B2533), ink2: Color(0xFF4B5A70), muted: Color(0xFF7988A0), muted2: Color(0xFFA5B1C3),
    primary: Color(0xFF3B6FE0), onPrimary: Color(0xFFFFFFFF),
    success: Color(0xFF16A34A), successInk: Color(0xFF15803D), error: Color(0xFFDC2626),
    userBubble: Color(0xFFDCE6F7), composerBg: Color(0xFFF7F9FC),
  );

  /// High contrast, and no red/green pairs: blue for success, orange for
  /// errors, amber for actions.
  static const colorblind = AppPalette(
    id: 'colorblind', name: 'Colorblind',
    bg: Color(0xFF000000), bg2: Color(0xFF0A0A0A), surface: Color(0xFF141414),
    surface2: Color(0xFF1E1E1E), surface3: Color(0xFF282828),
    border: Color(0xFF3A3A3A), border2: Color(0xFF4A4A4A),
    ink: Color(0xFFFFFFFF), ink2: Color(0xFFD0D0D0), muted: Color(0xFFA0A0A0), muted2: Color(0xFF6A6A6A),
    primary: Color(0xFFFFB000), onPrimary: Color(0xFF000000),
    success: Color(0xFF3AA0FF), successInk: Color(0xFF3AA0FF), error: Color(0xFFFF6A00),
    userBubble: Color(0xFF2A2A2A), composerBg: Color(0xFF1E1E1E),
  );

  static const List<AppPalette> all = [
    midnight, graphite, emerald, ocean, sunset, monokai, violet,
    light, paper, mist, colorblind,
  ];

  static AppPalette byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => midnight);
}

/// Design tokens: the active palette's colours.
///
/// These are getters, not constants, so a theme change takes effect on the
/// next build everywhere (see ThemeController).
class AppTheme {
  AppTheme._();

  /// The active palette; set through ThemeController.
  static AppPalette palette = AppPalettes.midnight;

  // ── Surface ─────────────────────────────────────────────────────────────
  static Color get bg => palette.bg;
  static Color get bg2 => palette.bg2;
  static Color get surface => palette.surface;
  static Color get surface2 => palette.surface2;
  static Color get surface3 => palette.surface3;
  static Color get border => palette.border;
  static Color get border2 => palette.border2;

  // ── Ink ─────────────────────────────────────────────────────────────────
  static Color get ink => palette.ink;
  static Color get ink2 => palette.ink2;
  static Color get muted => palette.muted;
  static Color get muted2 => palette.muted2;

  // ── Accents ─────────────────────────────────────────────────────────────
  static Color get primary => palette.primary;
  static Color get onPrimary => palette.onPrimary;
  static Color get accent => palette.primary;
  static Color get success => palette.success;
  static Color get successInk => palette.successInk;
  static Color get error => palette.error;
  static Color get userBubble => palette.userBubble;
  static Color get composerBg => palette.composerBg;

  // ── Backwards-compat aliases (legacy `glass*` names used across screens)
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
  static Color get accentSuccess => success;
  static Color get accentError => error;

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

  /// Material theme for the active palette.
  static ThemeData get theme {
    final p = palette;
    return ThemeData(
      brightness: p.brightness,
      primaryColor: p.primary,
      scaffoldBackgroundColor: p.bg,
      colorScheme: ColorScheme(
        brightness: p.brightness,
        primary: p.primary,
        onPrimary: p.onPrimary,
        secondary: p.ink2,
        onSecondary: p.bg,
        surface: p.bg,
        onSurface: p.ink,
        surfaceContainerHighest: p.surface,
        error: p.error,
        onError: Colors.white,
      ),
      textTheme: _textTheme(p.ink),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: p.ink),
        titleTextStyle: GoogleFonts.interTight(
          fontSize: 17, fontWeight: FontWeight.w600, color: p.ink, letterSpacing: -0.3,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.primary, width: 1.5),
        ),
        hintStyle: TextStyle(color: p.muted),
        labelStyle: TextStyle(color: p.ink2),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.surface3,
        thumbColor: p.primary,
        overlayColor: p.primary.withValues(alpha: 0.12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.onPrimary : p.muted),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.primary : p.surface3),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: p.primary),
      dividerColor: p.border,
      hintColor: p.muted,
      useMaterial3: true,
    );
  }

  /// Kept for older call sites.
  static ThemeData get darkTheme => theme;

  static SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: palette.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: palette.bg,
        systemNavigationBarIconBrightness: palette.isDark ? Brightness.light : Brightness.dark,
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
