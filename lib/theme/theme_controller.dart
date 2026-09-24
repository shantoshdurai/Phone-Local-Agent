import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// Holds the chosen palette and applies it.
///
/// Screens read colours from [AppTheme] at build time, so after a change the
/// whole widget tree is rebuilt in place (navigation and state are kept).
class ThemeController extends ValueNotifier<AppPalette> {
  ThemeController._() : super(AppPalettes.midnight);
  static final ThemeController instance = ThemeController._();

  static const _kTheme = 'theme_v1';

  Future<void> load() async {
    try {
      final id = (await SharedPreferences.getInstance()).getString(_kTheme);
      _apply(AppPalettes.byId(id));
    } catch (_) {}
  }

  Future<void> select(AppPalette palette) async {
    if (palette.id == value.id) return;
    _apply(palette);
    // Rebuild every element, not just the ones that depend on Theme.of.
    await WidgetsBinding.instance.reassembleApplication();
    try {
      await (await SharedPreferences.getInstance()).setString(_kTheme, palette.id);
    } catch (_) {}
  }

  void _apply(AppPalette palette) {
    AppTheme.palette = palette;
    value = palette;
    SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
  }
}
