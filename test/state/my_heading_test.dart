import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/my_heading.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Position> gps;
  late StreamController<double> compass;
  late RunSession session;
  var east = 0.0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gps = StreamController<Position>();
    compass = StreamController<double>.broadcast();
    session = await RunSession.solo(
      await AppSettings.load(),
      Notifier(),
      locationSource: () => gps.stream,
    );
    east = 0;
  });

  tearDown(() async {
    session.dispose();
    await gps.close();
    await compass.close();
  });

  /// A second's GPS fix at [speed] (m/s), going east unless [heading] says
  /// otherwise.
  Future<void> move(double speed, {double heading = 90}) async {
    east += speed;
    final p = offset(0, east);
    gps.add(
      Position(
        latitude: p.lat,
        longitude: p.lon,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 5,
        heading: heading,
        headingAccuracy: 10,
        speed: speed,
        speedAccuracy: 1,
      ),
    );
    await pumpEventQueue();
  }

  /// The phone turned to face [bearing].
  Future<void> face(double bearing) async {
    compass.add(bearing);
    await pumpEventQueue();
  }

  MyHeading track({bool withCompass = true}) {
    final heading = MyHeading(
      session,
      compass: withCompass ? () => compass.stream : null,
    );
    addTearDown(heading.dispose);
    return heading;
  }

  test('the compass while you stand, GPS while you run', () async {
    final heading = track();
    expect(heading.value, isNull);
    await move(0);
    expect(heading.value, isNull, reason: 'nothing says which way yet');
    await face(200);
    expect(heading.value, 200);

    // Running east: GPS, whichever way the phone points.
    await move(3);
    expect(heading.value, 90);
    await face(150);
    expect(heading.value, 90);

    // Slowing to a walk keeps GPS; stopping hands back to the compass.
    await move(1);
    expect(heading.value, 90);
    await move(0.3);
    expect(heading.value, 150);
  });

  test('walking slowly from a stop stays on the compass', () async {
    final heading = track();
    await move(0);
    await face(200);
    await move(1);
    expect(heading.value, 200);
    await move(1.5);
    expect(heading.value, 90);
  });

  test('without a compass it keeps the last way you moved', () async {
    final heading = track(withCompass: false);
    await move(0);
    expect(heading.value, isNull);
    await move(1, heading: 45);
    expect(heading.value, 45);
    await move(0);
    expect(heading.value, 45);
    // iPhones give a negative heading when they don't know it.
    await move(3, heading: -1);
    expect(heading.value, 45);
  });

  test('wobbles under a degree leave the arrow alone', () async {
    final heading = track();
    var turns = 0;
    heading.addListener(() => turns++);
    await face(100);
    await face(100.5);
    expect((turns, heading.value), (1, 100));
    await face(101.2);
    expect((turns, heading.value), (2, 101.2));
    // Across north.
    await face(0.6);
    await face(359.9);
    expect((turns, heading.value), (3, 0.6));
  });

  test('the compass rests while the app is out of sight', () async {
    final heading = MyHeading(session, compass: () => compass.stream);
    expect(compass.hasListener, isTrue);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
    expect(compass.hasListener, isFalse);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
    expect(compass.hasListener, isTrue);
    heading.dispose();
    expect(compass.hasListener, isFalse);
  });
}
