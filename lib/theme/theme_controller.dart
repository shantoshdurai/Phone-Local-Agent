import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';

/// Holds the chosen palette and applies it.
///
/// Screens read colours from [AppTheme] at build time, so after a change the
/// app rebuilds through the [ValueListenable] in `main.dart`.
class ThemeController extends ValueNotifier<AppPalette> {
  ThemeController._() : super(AppPalettes.obsidian);
  static final ThemeController instance = ThemeController._();

  static const _kTheme = 'appearance_v1';

  Future<void> load() async {
    try {
      final id = (await SharedPreferences.getInstance()).getString(_kTheme);
      _apply(AppPalettes.byId(id), persist: false);
    } catch (_) {}
  }

  Future<void> select(AppPalette palette) async {
    if (palette.id == value.id) return;
    _apply(palette, persist: true);
  }

  void _apply(AppPalette palette, {required bool persist}) {
    AppTheme.palette = palette;
    value = palette;
    SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
    if (persist) {
      // ignore: discarded_futures
      SharedPreferences.getInstance()
          .then((p) => p.setString(_kTheme, palette.id));
    }
  }
}
