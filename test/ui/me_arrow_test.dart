// Your arrow on the map, as a runner sees it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:ibex_trails/ui/run_screen.dart';
import 'package:ibex_trails/ui/trail_map.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

void main() {
  testWidgets('your arrow turns with the phone, and runs with you', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ibex_arrow');
    addTearDown(() => dir.deleteSync(recursive: true));
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
    final compass = StreamController<double>.broadcast();
    final session = (await tester.runAsync(
      () =>
          RunSession.solo(settings, notifier, locationSource: () => gps.stream),
    ))!;
    await tester.pumpWidget(
      AppScope(
        settings: settings,
        notifier: notifier,
        compass: () => compass.stream,
        child: MaterialApp(home: RunScreen(session: session)),
      ),
    );
    await tester.pump();

    // One pump hands the reading over, the next draws it.
    Future<void> settle() async {
      await tester.pump();
      await tester.pump();
    }

    var east = 0.0;
    Future<void> move(double speed) async {
      east += speed;
      final p = offset(0, east);
      gps.add(
        Position(
          latitude: p.lat,
          longitude: p.lon,
          timestamp: DateTime.now(),
          accuracy: 5,
          altitude: 100,
          altitudeAccuracy: 5,
          heading: 90,
          headingAccuracy: 10,
          speed: speed,
          speedAccuracy: 1,
        ),
      );
      await settle();
    }

    Future<void> face(double bearing) async {
      compass.add(bearing);
      await settle();
    }

    double? arrow() {
      final f = find.byType(MeArrow);
      return f.evaluate().isEmpty ? null : tester.widget<MeArrow>(f).heading;
    }

    // Standing at the start before the compass says anything: a dot.
    await move(0);
    expect(arrow(), isNull);
    await face(200);
    expect(arrow(), 200);

    // Running east.
    await move(3);
    expect(arrow(), 90);

    // Stopped at a junction: the way the phone faces.
    await move(0);
    expect(arrow(), 200);

    await tester.pumpWidget(const SizedBox());
    expect(compass.hasListener, isFalse);
    session.dispose();
    await tester.runAsync(gps.close);
    await tester.runAsync(compass.close);
  });
}
