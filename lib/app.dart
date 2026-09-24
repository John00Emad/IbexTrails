import 'package:flutter/material.dart';

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

/// Brand colours: trail orange for routes, forest green for the UI.
abstract final class TrailColors {
  static const forest = Color(0xFF2E6B3F);
  static const route = Color(0xFFE8590C);
  static const routeDone = Color(0xFF8A8F98);
  static const me = Color(0xFF1C6DD0);
  static const danger = Color(0xFFC62828);
  static const warning = Color(0xFFEF8F00);
  static const ok = Color(0xFF2E7D32);
}

class IbexTrailsApp extends StatelessWidget {
  const IbexTrailsApp({
    super.key,
    required this.settings,
    required this.notifier,
  });

  final AppSettings settings;
  final Notifier notifier;

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: TrailColors.forest,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      notifier: notifier,
      child: MaterialApp(
        title: 'IbexTrails',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const HomeScreen(),
      ),
    );
  }
}
