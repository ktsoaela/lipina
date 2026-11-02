import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/login_screen.dart';
import 'screens/shell.dart';
import 'services/auth_service.dart';

class LipinaColors {
  static const bg = Color(0xFF0B0B10);
  static const surface = Color(0xFF15151D);
  static const surfaceHi = Color(0xFF1E1E29);
  static const accent = Color(0xFF1ED6A0); // Lipina green
  static const accent2 = Color(0xFFFFB547); // SA gold
  static const muted = Color(0xFF9A9AAE);
}

class LipinaApp extends StatelessWidget {
  const LipinaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: LipinaColors.accent,
      brightness: Brightness.dark,
      surface: LipinaColors.surface,
    ).copyWith(primary: LipinaColors.accent, secondary: LipinaColors.accent2);
    return MaterialApp(
      title: 'Lipina',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: LipinaColors.bg,
        appBarTheme: const AppBarTheme(backgroundColor: LipinaColors.bg, elevation: 0, scrolledUnderElevation: 0),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: LipinaColors.bg,
          indicatorColor: Color(0x331ED6A0),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        ),
        cardTheme: const CardThemeData(color: LipinaColors.surface, elevation: 0),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: LipinaColors.surfaceHi,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
        sliderTheme: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
        listTileTheme: const ListTileThemeData(iconColor: LipinaColors.muted),
      ),
      home: Consumer<AuthService>(
        builder: (_, auth, __) => auth.isLoggedIn ? const Shell() : const LoginScreen(),
      ),
    );
  }
}
