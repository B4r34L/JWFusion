import 'package:flutter/material.dart';

import 'domain/settings/app_settings.dart';
import 'presentation/screens/dashboard_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  runApp(const JwFusionApp());
}

class JwFusionApp extends StatelessWidget {
  const JwFusionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'JW Fusion',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF4A6DA7),
            brightness: Brightness.light,
            useMaterial3: true,
            visualDensity: VisualDensity.comfortable,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF4A6DA7),
            brightness: Brightness.dark,
            useMaterial3: true,
            visualDensity: VisualDensity.comfortable,
          ),
          themeMode: AppSettings.instance.themeMode,
          home: const DashboardScreen(),
        );
      },
    );
  }
}
