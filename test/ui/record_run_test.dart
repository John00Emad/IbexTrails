// Recording a run from the run screen to its summary, as a runner would.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/run_library.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:ibex_trails/ui/run_detail_screen.dart';
import 'package:ibex_trails/ui/run_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// Pumps until [finder] shows up, letting real file and isolate work run
/// in between (widget tests otherwise run on fake time).
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

void main() {
  testWidgets('stopping a recorded run shows its summary', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ibex_runs');
    RunLibrary.debugDirectory = dir;
    addTearDown(() {
      RunLibrary.debugDirectory = null;
      dir.deleteSync(recursive: true);
    });
    // For the map's tile cache.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    // The run screen releases the wake lock when it closes.
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
    );
    SharedPreferences.setMockInitialValues({});
    final settings = (await tester.runAsync(AppSettings.load))!;
    final notifier = Notifier();
    final gps = StreamController<Position>();
    final session = (await tester.runAsync(
      () =>
          RunSession.solo(settings, notifier, locationSource: () => gps.stream),
    ))!;

    await tester.pumpWidget(
      AppScope(
        settings: settings,
        notifier: notifier,
        child: MaterialApp(home: RunScreen(session: session)),
      ),
    );
    expect(find.text('Solo run'), findsOneWidget);
    expect(find.text('Recording'), findsOneWidget);

    // 1.2 km east, a point every 50 m and 15 s, starting at 18:05.
    final start = DateTime(2026, 10, 3, 18, 5);
    final pts = eastLine(1200);
    for (var i = 0; i < pts.length; i++) {
      gps.add(
        Position(
          latitude: pts[i].lat,
          longitude: pts[i].lon,
          timestamp: start.add(Duration(seconds: 15 * i)),
          accuracy: 5,
          altitude: 100,
          altitudeAccuracy: 5,
          heading: 90,
          headingAccuracy: 10,
          speed: 3.3,
          speedAccuracy: 1,
        ),
      );
    }
    await tester.pump();
    expect(session.recorded, hasLength(pts.length));

    await tester.tap(find.byTooltip('Leave'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Stop this run?'), findsOneWidget);
    expect(find.text('Your run is saved to My runs.'), findsOneWidget);
    await tester.tap(find.text('Stop'));

    // The run screen makes way for the run's summary.
    await _pumpUntil(tester, find.text('Run this route'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RunScreen), findsNothing);
    expect(find.byType(RunDetailScreen), findsOneWidget);
    expect(find.text('Evening run'), findsOneWidget);
    expect(find.text('1.20 km'), findsOneWidget);
    final runs = (await tester.runAsync(RunLibrary.list))!;
    expect(runs.single.name, 'Evening run');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(gps.close);
  });
}
