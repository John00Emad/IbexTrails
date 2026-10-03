// Recording a run from the button on the map, as a runner would.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';
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

/// 1.2 km east, a point every 50 m and 15 s, starting at 18:05.
final _start = DateTime(2026, 10, 3, 18, 5);
final _pts = eastLine(1200);

Position _fix(int i) => Position(
  latitude: _pts[i].lat,
  longitude: _pts[i].lon,
  timestamp: _start.add(Duration(seconds: 15 * i)),
  accuracy: 5,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 90,
  headingAccuracy: 10,
  speed: 3.3,
  speedAccuracy: 1,
);

void main() {
  late Directory dir;
  late AppSettings settings;
  late Notifier notifier;
  late StreamController<Position> gps;
  late RunSession session;
  final nav = GlobalKey<NavigatorState>();

  /// A solo run with no route, its screen opened from a home page.
  Future<void> openSoloRun(WidgetTester tester) async {
    dir = Directory.systemTemp.createTempSync('ibex_runs');
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
    settings = (await tester.runAsync(AppSettings.load))!;
    notifier = Notifier();
    gps = StreamController<Position>();
    session = (await tester.runAsync(
      () =>
          RunSession.solo(settings, notifier, locationSource: () => gps.stream),
    ))!;
    await tester.pumpWidget(
      AppScope(
        settings: settings,
        notifier: notifier,
        child: MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => RunScreen(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Solo run'), findsOneWidget);
  }

  Future<void> run(WidgetTester tester, int from, int to) async {
    for (var i = from; i < to; i++) {
      gps.add(_fix(i));
    }
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.runAsync(gps.close);
  }

  testWidgets('nothing is recorded until Record is tapped', (tester) async {
    await openSoloRun(tester);
    expect(session.isRecording, isFalse);
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);

    await run(tester, 0, _pts.length);
    // The run itself still keeps its trail and distance.
    expect(session.recorded, hasLength(_pts.length));
    expect(session.distanceRun, closeTo(1200, 1));

    await tester.tap(find.byTooltip('Leave'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Stop this run?'), findsOneWidget);
    expect(
      find.text('You didn\'t record this run, so it isn\'t kept in My runs.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Stop'));

    // Back home, with nothing in My runs.
    await _pumpUntil(tester, find.text('Home'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RunScreen), findsNothing);
    expect(await tester.runAsync(RunLibrary.list), isEmpty);
    await close(tester);
  });

  testWidgets('recording from the map, then stopping the run shows its '
      'summary', (tester) async {
    await openSoloRun(tester);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(session.isRecording, isTrue);
    expect(find.byTooltip('Stop recording'), findsOneWidget);
    expect(find.textContaining('REC 0:0'), findsOneWidget);

    await run(tester, 0, _pts.length);
    await tester.tap(find.byTooltip('Leave'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Stop this run?'), findsOneWidget);
    expect(find.text('Your recording is saved to My runs.'), findsOneWidget);
    await tester.tap(find.text('Stop'));

    // The run screen makes way for the recording's summary.
    await _pumpUntil(tester, find.text('Run this route'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RunScreen), findsNothing);
    expect(find.byType(RunDetailScreen), findsOneWidget);
    expect(find.text('Evening run'), findsOneWidget);
    expect(find.text('1.20 km'), findsOneWidget);
    final runs = (await tester.runAsync(RunLibrary.list))!;
    expect(runs.single.name, 'Evening run');
    await close(tester);
  });

  testWidgets('stopping a recording keeps it while the run carries on', (
    tester,
  ) async {
    await openSoloRun(tester);
    // The first 400 m aren't recorded.
    await run(tester, 0, 9);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    await run(tester, 9, _pts.length);
    expect(session.recordingDistance, closeTo(750, 1));

    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Stop recording?'), findsOneWidget);
    expect(find.textContaining('750 m in'), findsOneWidget);
    await tester.tap(find.text('Stop & save'));
    await _pumpUntil(tester, find.text('Saved to My runs: Evening run'));
    // Let the snack bar slide fully in.
    await tester.pump(const Duration(seconds: 1));

    // Still running, ready to record again.
    expect(find.byType(RunScreen), findsOneWidget);
    expect(session.isRecording, isFalse);
    expect(find.byTooltip('Start recording'), findsOneWidget);
    expect(session.distanceRun, closeTo(1200, 1));

    // The file holds only what came after the tap.
    final runs = (await tester.runAsync(RunLibrary.list))!;
    expect(runs.single.distance, closeTo(750, 1));
    final gpx = parseGpx(runs.single.file.readAsStringSync());
    expect(gpx.track, hasLength(_pts.length - 9));
    expect(distanceBetween(gpx.track.first, _pts[9]), lessThan(1));

    // View opens the summary without "Run this route": a run is going.
    await tester.tap(find.text('VIEW'));
    await _pumpUntil(tester, find.byType(RunDetailScreen));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Run this route'), findsNothing);
    await close(tester);
  });
}
