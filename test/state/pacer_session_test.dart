// The virtual pacer in a run: it comes and goes with the setting, its cues
// reach the runner, and it keeps quiet when something else matters more.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/pacer.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

/// Keeps the pacer's notifications, and which ones were taken away. Tests
/// run with the app not in the foreground, so cues show as notifications.
class _Notes extends Notifier {
  final shown = <String>[];
  final cancelled = <int>[];

  @override
  Future<void> info(int id, String title, String body) async {
    if (id == NoteId.pacer) shown.add('$title · $body');
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

/// 6:00–7:00 /km.
const _plan = PacerPlan(enabled: true, fastest: 360, slowest: 420);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppSettings settings;
  late _Notes notes;
  late StreamController<Position> gps;
  late DateTime time;
  late double along;
  TrailRoute? route;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    notes = _Notes();
    gps = StreamController<Position>();
    addTearDown(gps.close);
    time = DateTime.now();
    along = 0;
    route = null;
  });

  Future<RunSession> start({TrailRoute? on}) async {
    route = on;
    final s = await RunSession.solo(
      settings,
      notes,
      route: on,
      locationSource: () => gps.stream,
    );
    addTearDown(s.dispose);
    return s;
  }

  /// Runs at [pace] (s/km) for [seconds], with a fix every 2 s: along the
  /// route, or east without one. [north] of it, if given.
  Future<void> run(double pace, int seconds, {double north = 0}) async {
    final speed = 1000 / pace;
    for (var i = 0; i < seconds; i += 2) {
      time = time.add(const Duration(seconds: 2));
      along += speed * 2;
      final on = route?.pointAt(along) ?? offset(0, along);
      gps.add(
        Position(
          latitude: on.lat + north / 111195,
          longitude: on.lon,
          timestamp: time,
          accuracy: 5,
          altitude: 100,
          altitudeAccuracy: 5,
          heading: 90,
          headingAccuracy: 10,
          speed: speed,
          speedAccuracy: 1,
        ),
      );
    }
    await pumpEventQueue();
  }

  test(
    'off until turned on; on, off and changed in the middle of a run',
    () async {
      final s = await start();
      expect(s.pacer, isNull);
      await run(390, 60);

      settings.pacerPlan = _plan;
      expect(s.pacer, isNotNull);
      // It starts afresh: a moment of running before it has a pace.
      await run(390, 10);
      expect(s.pacer!.pace, isNull);
      await run(390, 20);
      expect(s.pacer!.pace, closeTo(390, 1));

      settings.pacerPlan = _plan.copyWith(
        fastest: 300,
        slowest: 330,
        averageSeconds: 30,
      );
      expect(s.pacer!.range, (300, 330));
      expect(s.pacer!.window, const Duration(seconds: 30));

      settings.pacerPlan = _plan.copyWith(enabled: false);
      expect(s.pacer, isNull);
      expect(notes.cancelled, contains(NoteId.pacer));
    },
  );

  test('tells the runner when the pace leaves the range and is back', () async {
    settings.pacerPlan = _plan;
    final s = await start();
    await run(390, 60);
    expect(notes.shown, isEmpty);

    await run(480, 90);
    expect(notes.shown, hasLength(1));
    expect(notes.shown.single, startsWith('Too slow · '));
    expect(notes.shown.single, endsWith(' /km · range 6:00–7:00'));

    await run(390, 60);
    expect(s.pacer!.zone, PaceZone.onPace);
    // Back on pace takes the notification away rather than adding one.
    expect(notes.shown, hasLength(1));
    expect(notes.cancelled, contains(NoteId.pacer));
  });

  test('quiet while off route: the off-route alarm comes first', () async {
    settings.pacerPlan = _plan;
    final s = await start(on: TrailRoute.fromPoints('Wadi', eastLine(3000)));
    await run(390, 60);
    await run(480, 120, north: 150);
    expect(s.match!.offRoute, isTrue);
    expect(s.pacer!.zone, PaceZone.tooSlow);
    expect(notes.shown, isEmpty);

    await run(480, 10);
    expect(s.match!.offRoute, isFalse);
    expect(notes.shown.single, startsWith('Too slow'));
  });

  test('never talks over a turn warning', () async {
    settings.pacerPlan = _plan;
    // A corner after 300 m.
    final s = await start(
      on: TrailRoute.fromPoints('Corner', [
        ...eastLine(300),
        for (var n = 50.0; n <= 2000; n += 50) offset(n, 300),
      ]),
    );
    await run(390, 60);
    await run(480, 60);
    // Too slow for long enough, but the corner is coming up.
    expect(s.pacer!.zone, PaceZone.tooSlow);
    expect(s.nextTurn!.distance, lessThan(100));
    expect(notes.shown, isEmpty);

    await run(480, 20);
    expect(s.nextTurn, isNull, reason: 'round the corner');
    expect(notes.shown.single, startsWith('Too slow'));
  });

  test('restart sets the pacer off again from here', () async {
    settings.pacerPlan = _plan;
    final s = await start();
    await run(450, 300);
    expect(s.pacer!.gap!.inSeconds, closeTo(-40, 2));

    s.restartPacer();
    expect(s.pacer!.gap, Duration.zero);
    await run(390, 60);
    expect(s.pacer!.gap!.inSeconds.abs(), lessThanOrEqualTo(1));
  });
}
