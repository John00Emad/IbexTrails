// A solo run's checkpoints: every route starts with none passed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

Position _fix(GeoPoint p) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 90,
  headingAccuracy: 10,
  speed: 3,
  speedAccuracy: 1,
);

/// 2 km east with a water stop half way.
TrailRoute _wadiLoop() => TrailRoute.fromPoints(
  'Wadi loop',
  eastLine(2000),
  waypoints: [GpxWaypoint('Water', offset(0, 1000))],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A solo run on [route], run 1.2 km east, past its first checkpoint.
  Future<RunSession> runPastWater(TrailRoute route) async {
    final gps = StreamController<Position>();
    addTearDown(gps.close);
    final s = await RunSession.solo(
      await AppSettings.load(),
      Notifier(),
      route: route,
      locationSource: () => gps.stream,
    );
    for (var e = 0.0; e <= 1200; e += 20) {
      gps.add(_fix(offset(0, e)));
    }
    await pumpEventQueue();
    expect(s.checkpoints!.passed.keys, ['cp1']);
    return s;
  }

  test('a new solo run on the same route has no checkpoint passed', () async {
    final first = await runPastWater(_wadiLoop());
    await first.leave();

    final again = await RunSession.solo(
      await AppSettings.load(),
      Notifier(),
      route: _wadiLoop(),
      locationSource: () => const Stream.empty(),
    );
    addTearDown(again.dispose);
    expect(again.checkpoints!.passed, isEmpty);
  });

  test('a route loaded mid-run has no checkpoint passed', () async {
    final s = await runPastWater(_wadiLoop());
    addTearDown(s.dispose);

    s.useRoute(
      TrailRoute.fromPoints(
        'Summit trail',
        eastLine(3000),
        waypoints: [GpxWaypoint('Summit', offset(0, 2500))],
      ),
    );
    expect(s.route!.name, 'Summit trail');
    expect(s.checkpoints!.passed, isEmpty);
  });
}
