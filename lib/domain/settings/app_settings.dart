import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global application settings.
///
/// Kept as a simple singleton so both the merge engine and the UI read from
/// one place. Values are persisted to disk via [SharedPreferences] so they
/// survive app restarts - call [load] once during startup (before the first
/// frame) and [save] whenever a value changes.
///
/// Extends [ChangeNotifier] so widgets that need to react live to a setting
/// change (like the app's theme) can listen instead of polling.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const _keyAskUserOnConflict = 'askUserOnConflict';
  static const _keyDeviceName = 'deviceName';
  static const _keyThemeMode = 'themeMode';

  /// When true, a future UI version will pause and ask the user how to
  /// resolve each conflicting record. The engine currently resolves all
  /// conflicts automatically with a "latest timestamp wins" strategy.
  bool askUserOnConflict = false;

  /// Device name written into the manifest of merged backups.
  String deviceName = 'JW Fusion';

  /// System (follow the phone/PC setting), or a manual override.
  ThemeMode themeMode = ThemeMode.system;

  bool _loaded = false;
  SharedPreferences? _prefs;

  /// Loads persisted values from disk. Safe to call multiple times; only
  /// hits disk once. Call this in `main()` before `runApp`.
  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    askUserOnConflict = prefs.getBool(_keyAskUserOnConflict) ?? false;
    deviceName = prefs.getString(_keyDeviceName) ?? 'JW Fusion';
    themeMode = _themeModeFromString(prefs.getString(_keyThemeMode));
    _loaded = true;
  }

  /// Persists the current values. Fire-and-forget is fine - if this hasn't
  /// completed by the time the app closes, the setting simply reverts to
  /// its previous saved value on next launch (never crashes or blocks UI).
  Future<void> save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setBool(_keyAskUserOnConflict, askUserOnConflict);
    await prefs.setString(_keyDeviceName, deviceName);
    await prefs.setString(_keyThemeMode, _themeModeToString(themeMode));
  }

  /// Sets and persists the theme mode, notifying listeners (i.e. rebuilding
  /// the app's `MaterialApp`) immediately.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode == mode) return;
    themeMode = mode;
    notifyListeners();
    await save();
  }

  static ThemeMode _themeModeFromString(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}
