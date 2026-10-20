// Setting up the virtual pacer, and using it on the run screen.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/core/pacer.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:ibex_trails/ui/home_screen.dart';
import 'package:ibex_trails/ui/pacer_plan_screen.dart';
import 'package:ibex_trails/ui/run_screen.dart';
import 'package:ibex_trails/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  late AppSettings settings;

  Future<void> show(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      AppScope(
        settings: settings,
        notifier: Notifier(),
        child: MaterialApp(home: home),
      ),
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('set up from the home screen: on, and the pace range', (
    tester,
  ) async {
    settings = (await tester.runAsync(AppSettings.load))!;
    await show(tester, const HomeScreen());
    await tester.scrollUntilVisible(
      find.text('Virtual pacer'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Virtual pacer'));
    await tester.pump();
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.text('Virtual pacer'));
    await tester.pumpAndSettle();
    expect(find.byType(PacerPlanScreen), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Virtual pacer'));
    await tester.pump();
    expect(settings.pacerPlan.enabled, isTrue);
    expect(find.text('Pace range: 6:00–7:00 per km'), findsOneWidget);
    expect(find.textContaining('runs at 6:30 per km'), findsOneWidget);

    // Fine-tune each end in 5 s steps.
    for (final button in [
      'Fastest: slower',
      'Slowest: faster',
      'Slowest: faster',
    ]) {
      await tester.tap(find.byTooltip(button));
      await tester.pump();
    }
    expect(settings.pacerPlan.fastest, 365);
    expect(settings.pacerPlan.slowest, 410);
    expect(find.text('Pace range: 6:05–6:50 per km'), findsOneWidget);

    final voice = find.widgetWithText(SwitchListTile, 'Say it out loud');
    await tester.ensureVisible(voice);
    await tester.pump();
    await tester.tap(voice);
    await tester.pump();
    expect(settings.pacerPlan.voice, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('6:05–6:50 per km'), findsOneWidget);
  });

  testWidgets('the ends of the range cannot cross', (tester) async {
    settings = (await tester.runAsync(AppSettings.load))!
      ..pacerPlan = const PacerPlan(enabled: true, fastest: 400, slowest: 405);
    await show(tester, const PacerPlanScreen());
    await tester.tap(find.byTooltip('Fastest: slower'));
    await tester.pump();
    expect(settings.pacerPlan.fastest, 405);
    final slower = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add).first,
    );
    expect(slower.onPressed, isNull, reason: 'fastest is at slowest');
  });

  testWidgets('choose how long the pace is averaged over', (tester) async {
    settings = (await tester.runAsync(AppSettings.load))!
      ..pacerPlan = const PacerPlan(enabled: true);
    await show(tester, const PacerPlanScreen());
    // "How it works" says how long, at the bottom of the screen.
    final howItWorks = find.textContaining('averaged over the last');
    Future<void> readHowItWorks() => tester.scrollUntilVisible(
      howItWorks,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await readHowItWorks();
    expect(
      find.textContaining('averaged over the last minute'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('1 min'));
    await tester.pump();
    await tester.tap(find.text('1 min'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 s').last);
    await tester.pumpAndSettle();
    expect(settings.pacerPlan.averageSeconds, 30);
    await readHowItWorks();
    expect(
      find.textContaining('averaged over the last 30 seconds'),
      findsOneWidget,
    );
  });

  testWidgets('settings shows it under Pacing', (tester) async {
    settings = (await tester.runAsync(AppSettings.load))!
      ..pacerPlan = const PacerPlan(enabled: true, fastest: 330, slowest: 345);
    await show(tester, const SettingsScreen());
    await tester.scrollUntilVisible(
      find.text('5:30–5:45 per km · voice cues'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Pacing'), findsOneWidget);
  });

  group('on the run screen', () {
    late StreamController<Position> gps;
    late RunSession session;
    late DateTime time;
    var along = 0.0;
    final route = TrailRoute.fromPoints('Wadi', eastLine(5000));

    Future<void> open(WidgetTester tester) async {
      final dir = Directory.systemTemp.createTempSync('ibex_pacer');
      addTearDown(() => dir.deleteSync(recursive: true));
      // For the map's tile cache.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
      // The run screen releases the wake lock when it closes.
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]),
      );
      settings = (await tester.runAsync(AppSettings.load))!
        ..pacerPlan = const PacerPlan(enabled: true);
      gps = StreamController<Position>();
      session = (await tester.runAsync(
        () => RunSession.solo(
          settings,
          Notifier(),
          route: route,
          locationSource: () => gps.stream,
        ),
      ))!;
      time = DateTime.now();
      along = 0;
      await show(tester, RunScreen(session: session));
      await tester.pump(const Duration(seconds: 1));
    }

    /// Runs along the route at [pace] (s/km) for [seconds].
    Future<void> run(WidgetTester tester, double pace, int seconds) async {
      for (var i = 0; i < seconds; i += 2) {
        time = time.add(const Duration(seconds: 2));
        along += 1000 / pace * 2;
        final p = route.pointAt(along);
        gps.add(
          Position(
            latitude: p.lat,
            longitude: p.lon,
            timestamp: time,
            accuracy: 5,
            altitude: 100,
            altitudeAccuracy: 5,
            heading: 90,
            headingAccuracy: 10,
            speed: 1000 / pace,
            speedAccuracy: 1,
          ),
        );
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.runAsync(gps.close);
    }

    testWidgets('the pacer line: waiting, on pace, too slow', (tester) async {
      await open(tester);
      expect(find.textContaining('Pacer ready · 6:00–7:00'), findsOneWidget);
      await run(tester, 390, 60);
      expect(find.textContaining('6:30 /km · On pace · 6:00–7:00'), findsOne);
      // The pacer runs alongside: on the map too.
      expect(find.byTooltip('Virtual pacer'), findsOneWidget);
      expect(find.byTooltip('Ahead of the pacer'), findsOneWidget);
      await run(tester, 480, 120);
      expect(find.textContaining('Too slow · 6:00–7:00'), findsOneWidget);
      expect(find.byTooltip('Behind the pacer'), findsOneWidget);
      await close(tester);
    });

    testWidgets('tap it for the details and to restart the pacer', (
      tester,
    ) async {
      await open(tester);
      await run(tester, 450, 300);
      await tester.tap(find.textContaining('Too slow'));
      await tester.pumpAndSettle();
      expect(find.text('Restart pacer here'), findsOneWidget);
      expect(find.textContaining('behind the pacer'), findsOneWidget);
      expect(find.text('Slower'), findsOneWidget);

      await tester.tap(find.text('Restart pacer here'));
      await tester.pump();
      expect(find.text('Level with the pacer'), findsOneWidget);
      expect(session.pacer!.gap, Duration.zero);

      // The range is a tap away.
      await tester.tap(find.text('6:00–7:00 /km'));
      await tester.pumpAndSettle();
      expect(find.byType(PacerPlanScreen), findsOneWidget);
      await close(tester);
    });

    testWidgets('turned on from the run menu', (tester) async {
      await open(tester);
      settings.pacerPlan = const PacerPlan();
      await tester.pump();
      expect(find.textContaining('Pacer ready'), findsNothing);

      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Virtual pacer'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Virtual pacer'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('Pacer ready'), findsOneWidget);
      await close(tester);
    });
  });
}
