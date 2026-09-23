import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kThemeModeKey = 'theme.mode';
const _kTextScaleKey = 'theme.textScale';


// Helpers to persist settings
Future<void> persistThemeMode(ThemeMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  final s = mode == ThemeMode.light ? 'light' : mode == ThemeMode.dark ? 'dark' : 'system';
  await prefs.setString(_kThemeModeKey, s);
}

Future<void> persistTextScale(double scale) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble(_kTextScaleKey, scale);
}


ThemeData buildLightTheme() {
  const seed = Color(0xFF1565C0);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
    useMaterial3: true,
  );
}

ThemeData buildDarkTheme() {
  const seed = Color(0xFF1565C0);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
    useMaterial3: true,
  );
}
