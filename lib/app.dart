import 'package:flutter/material.dart';

import 'brand.dart';
import 'services/notifications.dart';
import 'services/settings.dart';
import 'ui/home_screen.dart';

/// App-wide services, available to every screen via [AppScope.of].
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.notifier,
    required super.child,
  });

  final AppSettings settings;
  final Notifier notifier;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      settings != oldWidget.settings || notifier != oldWidget.notifier;
}

/// Map and status colours. Status colours stay conventional (green ok,
/// amber warning, red danger) so they read instantly in the sun.
abstract final class TrailColors {
  static const primary = Brand.canyon;
  static const route = Brand.ember;
  static const routeCasing = Brand.night;
  static const routeDone = Color(0xFF8A8F98);
  static const me = Color(0xFF1C6DD0);
  static const danger = Color(0xFFD62839);
  static const warning = Color(0xFFE89B00);
  static const ok = Color(0xFF2E8B57);
}

class IbexTrailsApp extends StatelessWidget {
  const IbexTrailsApp({
    super.key,
    required this.settings,
    required this.notifier,
  });

  final AppSettings settings;
  final Notifier notifier;

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.canyon,
      brightness: brightness,
      primary: dark ? const Color(0xFFFFB590) : Brand.canyon,
      secondary: dark ? const Color(0xFF7FD3CB) : Brand.oasis,
      surface: dark ? const Color(0xFF151B24) : Brand.limestone,
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: Brand.fontFamily,
      scaffoldBackgroundColor: scheme.surface,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Brand.night,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: Brand.fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1F2733) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: dark ? Colors.white10 : Brand.sand.withValues(alpha: 0.9),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1F2733) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: dark ? Colors.white24 : Brand.sandDeep),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontFamily: Brand.fontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontFamily: Brand.fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primaryContainer,
          textStyle: const TextStyle(
            fontFamily: Brand.fontFamily,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Brand.night,
        foregroundColor: Colors.white,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        showDragHandle: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      notifier: notifier,
      child: MaterialApp(
        title: Brand.appName,
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const HomeScreen(),
      ),
    );
  }
}
