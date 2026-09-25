// Renders the main screens to PNG files for visual review.
//
//   mosquitto -p 1883 &
//   IBEX_TEST_BROKER=127.0.0.1:1883 IBEX_SCREENSHOTS=/tmp/shots \
//     flutter test test/screenshots
//
// Map tiles are not downloaded in tests, so the map background is blank.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/core/course.dart';
import 'package:ibex_trails/core/crypto.dart';
import 'package:ibex_trails/core/fuel.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/core/protocol.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/relay_client.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:ibex_trails/ui/course_editor_screen.dart';
import 'package:ibex_trails/ui/course_picker.dart';
import 'package:ibex_trails/ui/group_sheet.dart';
import 'package:ibex_trails/ui/home_screen.dart';
import 'package:ibex_trails/ui/run_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

final _out = Platform.environment['IBEX_SCREENSHOTS'];
final _broker = Platform.environment['IBEX_TEST_BROKER'];

Future<void> _loadFonts() async {
  final dir =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';
  Future<ByteData> load(String f) async =>
      ByteData.sublistView(await File('$dir/$f').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    roboto.addFont(load(f));
  }
  await roboto.load();
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold', 'Black']) {
    cairo.addFont(
      File('assets/fonts/Cairo-$w.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  }
  await cairo.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(load('MaterialIcons-Regular.otf'))).load();
}

Position _fix(GeoPoint p) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: DateTime.now(),
  accuracy: 8,
  altitude: p.ele ?? 0,
  altitudeAccuracy: 5,
  heading: 80,
  headingAccuracy: 10,
  speed: 2.8,
  speedAccuracy: 1,
);

/// A hilly lollipop-shaped trail with two waypoints.
TrailRoute _demoRoute() {
  final pts = <GeoPoint>[];
  for (var e = 0.0; e <= 3000; e += 50) {
    pts.add(offset(e * 0.3, e, 300 + e * 0.12));
  }
  for (var a = 0.0; a <= 360; a += 6) {
    final r = a * math.pi / 180;
    pts.add(
      offset(
        900 + 900 * (1 - math.cos(r)),
        3000 + 900 * math.sin(r),
        660 + 180 * math.sin(r / 2),
      ),
    );
  }
  for (var e = 3000.0; e >= 0; e -= 50) {
    pts.add(offset(e * 0.3 + 15, e, 300 + e * 0.12));
  }
  return TrailRoute.fromPoints(
    'Wadi loop',
    pts,
    waypoints: [
      GpxWaypoint('Water', offset(900, 3000)),
      GpxWaypoint('Summit', offset(1800, 3000)),
    ],
  );
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.5);
    return image.toByteData(format: ui.ImageByteFormat.png);
  });
  File('$_out/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  if (_out == null || _broker == null) {
    test(
      'screenshots (set IBEX_SCREENSHOTS and IBEX_TEST_BROKER)',
      () {},
      skip: 'not requested',
    );
    return;
  }

  testWidgets('render screens', (tester) async {
    await tester.runAsync(_loadFonts);
    debugDisableShadows = false;
    final tmp = Directory.systemTemp.createTempSync('ibex_shots');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    tester.view.physicalSize = const Size(393 * 2.5, 852 * 2.5);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final settings = (await tester.runAsync(AppSettings.load))!;
    final parts = _broker!.split(':');
    settings
      ..displayName = 'Olga'
      ..relayHost = parts[0]
      ..relayPort = int.parse(parts[1])
      ..relayTls = false;
    final notifier = Notifier();
    final key = GlobalKey();

    Widget app(Widget home) => RepaintBoundary(
      key: key,
      child: AppScope(
        settings: settings,
        notifier: notifier,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: IbexTrailsApp.theme(Brightness.light),
          home: home,
        ),
      ),
    );

    await tester.pumpWidget(app(const HomeScreen()));
    await _shot(tester, key, '1_home');

    // Organizer view with a group spread along the route.
    final route = _demoRoute();
    final main = Course.fromRoute(route, id: 'c1', name: '12 km');
    final started = DateTime.now().subtract(const Duration(minutes: 25));
    final withCutoffs = main.copyWith(
      start: started,
      checkpoints: [
        for (final cp in main.checkpoints)
          cp.copyWith(cutoff: Duration(minutes: cp.along < 4000 ? 60 : 150)),
      ],
    );
    final short = Course.fromRoute(
      TrailRoute.fromPoints('Stem', [
        for (var e = 0.0; e <= 3000; e += 50)
          offset(e * 0.3, e, 300 + e * 0.12),
      ]),
      id: 'c2',
      name: '3 km',
    );
    final gps = StreamController<Position>();
    final session = (await tester.runAsync(
      () => RunSession.organize(
        settings,
        notifier,
        eventName: 'Sunday long run',
        courses: [withCutoffs, short],
        locationSource: () => gps.stream,
      ),
    ))!;
    final shared = session.route!;
    await tester.runAsync(() async {
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!session.relay!.isOnline && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      for (var a = 0.0; a <= 2400; a += 40) {
        gps.add(_fix(shared.pointAt(a)));
      }
      final cipher = await EventCipher.forCode(session.code!);
      final topics = EventTopics(cipher.topicId);
      final sim = RelayClient(
        host: parts[0],
        port: int.parse(parts[1]),
        tls: false,
        clientId: 'shot',
      );
      sim.start();
      while (!sim.isOnline) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      Future<void> report(
        String id,
        String name,
        double along, {
        RunnerStatus status = RunnerStatus.ok,
        double north = 0,
        Role role = Role.runner,
        Map<String, DateTime> passes = const {},
      }) async {
        final p = shared.pointAt(along);
        final lat = p.lat + north / 111195;
        sim.publish(
          topics.position(id),
          await cipher.seal(
            PositionReport(
              id: id,
              name: name,
              role: role,
              time: DateTime.now(),
              lat: lat,
              lon: p.lon,
              status: status,
              along: along,
              offBy: north == 0 ? 5 : north.abs(),
              battery: 64,
              course: 'c1',
              passes: passes,
              started: started,
            ).toJson(),
          ),
          retain: true,
        );
      }

      final early = started.add(const Duration(minutes: 20));
      await report('a', 'Rami Adel', 4100, passes: {'cp1': early});
      await report(
        'b',
        'Mona Samir',
        3350,
        passes: {'cp1': early.add(const Duration(minutes: 3))},
      );
      await report(
        'c',
        'Karim',
        2900,
        status: RunnerStatus.offRoute,
        north: -160,
      );
      await report('d', 'Laila', 1500, role: Role.sweeper);
      await report('e', 'Hany', 900, status: RunnerStatus.left);
      await Future<void>.delayed(const Duration(seconds: 2));
      await sim.dispose();
    });

    await tester.pumpWidget(app(RunScreen(session: session)));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '2_run_organizer');

    // Group list.
    await tester.tap(find.byTooltip('Group'));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '3_group');
    await tester.tapAt(const Offset(200, 60));
    await tester.pump(const Duration(seconds: 1));

    // SOS sheet.
    await tester.tap(find.byTooltip('Emergency'));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '4_sos');
    await tester.tapAt(const Offset(200, 60));
    await tester.pump(const Duration(seconds: 1));

    // Off route yourself.
    await tester.runAsync(() async {
      final base = shared.pointAt(2400);
      for (var n = 30.0; n <= 150; n += 30) {
        gps.add(_fix(GeoPoint(base.lat + n / 111195, base.lon, base.ele)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '5_off_route');

    // Fuel: one gel logged, a reminder showing, then the fuel sheet.
    await tester.runAsync(() async {
      final base = shared.pointAt(2440);
      gps.add(_fix(base));
      gps.add(_fix(shared.pointAt(2460)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final plan = settings.fuelPlan;
    session.logFuel(plan.item('gel')!);
    session.fuelReminder = FuelReminder(
      carbs: 25,
      fluidMl: 0,
      suggestion: [(plan.item('gel')!, 1)],
    );
    session.notifyListeners();
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '6_run_checkpoint_fuel');
    await tester.tap(find.byTooltip('Fuel'));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '7_fuel_sheet');
    await tester.tapAt(const Offset(200, 60));
    await tester.pump(const Duration(seconds: 1));

    // Course picker and course editor.
    final ctx = tester.element(find.byType(RunScreen));
    unawaited(pickCourse(ctx, session.courseList, current: 'c1'));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '8_course_picker');
    await tester.tapAt(const Offset(200, 60));
    await tester.pump(const Duration(seconds: 1));
    unawaited(
      Navigator.of(ctx).push(
        MaterialPageRoute<void>(
          builder: (_) => CourseEditorScreen(course: session.course!),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '9_course_editor');
    Navigator.of(ctx).pop();
    await tester.pump(const Duration(seconds: 1));

    // Headcount, opened from the app bar.
    unawaited(showGroupSheet(ctx, session, view: GroupView.headcount));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '10_headcount');
    await tester.tapAt(const Offset(200, 60));
    await tester.pump(const Duration(seconds: 1));

    // Event code with QR.
    await tester.tap(find.byTooltip('Share event code'));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '11_qr');
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(seconds: 1));

    // Run on round the loop to just before its first real turn.
    final turn = session.course!.turns.firstWhere((t) => t.along > 2500);
    await tester.runAsync(() async {
      for (var a = 2480.0; a <= turn.along - 50; a += 40) {
        gps.add(_fix(shared.pointAt(a)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    session.fuelReminder = null;
    session.notifyListeners();
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, key, '12_turn_warning');

    await tester.pumpWidget(const SizedBox());
    debugDisableShadows = true;
    await tester.runAsync(() async {
      session.dispose();
      await gps.close();
    });
  });
}
