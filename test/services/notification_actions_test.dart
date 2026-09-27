import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ate = jsonEncode({
  's': [
    ['gel', 1],
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IsolateNameServer.removePortNameMapping(actionPortName);
  });
  tearDown(() => IsolateNameServer.removePortNameMapping(actionPortName));

  test('a button tap goes straight to the running app', () async {
    final notifier = Notifier();
    final got = Completer<(String?, String?, DateTime)>();
    notifier.onAction = (a, p, t) => got.complete((a, p, t));
    notifier.listenForActions();

    final at = DateTime(2026, 9, 27, 7, 30);
    await deliverNotificationAction(NoteAction.fuelAte, _ate, at);

    final (action, payload, time) = await got.future.timeout(
      const Duration(seconds: 2),
    );
    expect(action, NoteAction.fuelAte);
    expect(payload, _ate);
    expect(time, at);
    final settings = await AppSettings.load();
    expect(await settings.takePendingActions(), isEmpty);
  });

  test('with the app not running, the tap is queued for later', () async {
    final at = DateTime(2026, 9, 27, 7, 30);
    await deliverNotificationAction(NoteAction.fuelSnooze, null, at);

    final settings = await AppSettings.load();
    final queued = await settings.takePendingActions();
    expect(queued.single['a'], NoteAction.fuelSnooze);
    expect(queued.single['t'], at.millisecondsSinceEpoch);
    expect(await settings.takePendingActions(), isEmpty, reason: 'cleared');
  });

  test('the run logs "Ate it", snoozes, and ignores stale taps', () async {
    final settings = await AppSettings.load();
    final gps = StreamController<Position>();
    final session = await RunSession.solo(
      settings,
      Notifier(),
      locationSource: () => gps.stream,
    );
    addTearDown(() {
      session.dispose();
      gps.close();
    });
    final coach = session.fuel!;
    final now = DateTime.now();

    // Via the notifier callback the session registered, as a real tap would.
    session.notifier.onAction!(NoteAction.fuelAte, _ate, now);
    expect(coach.log.carbs, 25);
    expect(coach.log.entries.single.time, now);

    session.handleNotificationAction(NoteAction.fuelSnooze, null, now);
    expect(coach.nextAt, now.add(const Duration(minutes: 5)));

    // A tap from before this run started (queued while the app was closed).
    session.handleNotificationAction(
      NoteAction.fuelAte,
      _ate,
      coach.start.subtract(const Duration(hours: 3)),
    );
    expect(coach.log.carbs, 25);
  });

  test('Android manifest declares the action receiver', () {
    // Without it Android silently drops notification button taps.
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(
      manifest,
      contains(
        'com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver',
      ),
    );
  });

  test('iOS registers plugins for the action isolate', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(delegate, contains('setPluginRegistrantCallback'));
  });
}
