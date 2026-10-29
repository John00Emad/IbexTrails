// Turn warnings in a run come early enough to reach the runner before the
// turn, whatever the pace.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// Keeps the turn warnings. Tests run with the app not in the foreground,
/// so each warning also shows as a notification.
class _Notes extends Notifier {
  final turns = <String>[];

  @override
  Future<void> info(int id, String title, String body) async {
    if (id == NoteId.turn) turns.add('$title · $body');
  }
}

/// 1 km east, then a right turn to the south.
final _corner = TrailRoute.fromPoints('Corner', [
  ...eastLine(1000),
  for (var n = 50.0; n <= 1000; n += 50) offset(-n, 1000),
]);

Position _fix(GeoPoint p, DateTime at, double speed) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: at,
  accuracy: 5,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 90,
  headingAccuracy: 10,
  speed: speed,
  speedAccuracy: 1,
);

/// The distance in a warning like "Turn right · In 58 m".
double _said(String warning) =>
    double.parse(RegExp(r'In (\d+) m$').firstMatch(warning)!.group(1)!);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Runs up to the corner at [speed] (m/s) with a fix every second, the GPS
  /// reporting [reported] as the speed. Returns how far before the turn the
  /// runner was when warned, and the warning.
  Future<(double, String)> approach(double speed, {double? reported}) async {
    final notes = _Notes();
    final gps = StreamController<Position>();
    addTearDown(gps.close);
    final s = await RunSession.solo(
      await AppSettings.load(),
      notes,
      route: _corner,
      locationSource: () => gps.stream,
    );
    addTearDown(s.dispose);
    final turn = s.course!.turns.single;
    double? warnedAt;
    var time = DateTime.now();
    for (var along = 0.0; along < turn.along; along += speed) {
      time = time.add(const Duration(seconds: 1));
      gps.add(_fix(_corner.pointAt(along), time, reported ?? speed));
      await pumpEventQueue();
      if (warnedAt == null && notes.turns.isNotEmpty) {
        warnedAt = turn.along - along;
      }
    }
    expect(notes.turns, hasLength(1), reason: 'one warning per turn');
    return (warnedAt!, notes.turns.single);
  }

  test('at 4 m/s the warning comes 6 m early, to be heard at 60 m', () async {
    final (before, warning) = await approach(4);
    // The first fix inside 66 m of the turn.
    expect(before, inInclusiveRange(61.5, 66.5));
    expect(warning, startsWith('Turn right · '));
    expect(_said(warning), closeTo(before - 6, 1));
  });

  test('with the speed unknown it comes at 60 m, as set', () async {
    final (before, warning) = await approach(4, reported: 0);
    expect(before, inInclusiveRange(55.5, 60.5));
    expect(_said(warning), closeTo(before, 1));
  });
}
