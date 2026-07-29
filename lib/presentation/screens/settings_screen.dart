import 'package:flutter/material.dart';

import '../../domain/settings/app_settings.dart';

/// Simple settings screen. Exposes the app's user-facing preferences:
/// conflict-resolution behavior (future feature, saved for later) and the
/// theme (system / light / dark).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppSettings _settings = AppSettings.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Appearance',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Match my device'),
            value: ThemeMode.system,
            groupValue: _settings.themeMode,
            onChanged: (mode) => _setTheme(mode),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Light'),
            value: ThemeMode.light,
            groupValue: _settings.themeMode,
            onChanged: (mode) => _setTheme(mode),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Dark'),
            value: ThemeMode.dark,
            groupValue: _settings.themeMode,
            onChanged: (mode) => _setTheme(mode),
          ),
          const Divider(height: 32),
          SwitchListTile(
            title: const Text('Ask me before resolving conflicts'),
            subtitle: const Text(
              'Saved for a future update. For now, merges always keep '
              'whichever record was changed most recently.',
            ),
            value: _settings.askUserOnConflict,
            onChanged: (value) {
              setState(() => _settings.askUserOnConflict = value);
              _settings.save();
            },
          ),
        ],
      ),
    );
  }

  void _setTheme(ThemeMode? mode) {
    if (mode == null) return;
    setState(() {});
    _settings.setThemeMode(mode);
  }
}
