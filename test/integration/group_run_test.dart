// End-to-end test of a group run over a real MQTT broker.
//
// Run with a local broker, e.g.:
//   mosquitto -p 1883 &
//   IBEX_TEST_BROKER=127.0.0.1:1883 flutter test test/integration
//
// Skipped when IBEX_TEST_BROKER is not set.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/course.dart';
import 'package:ibex_trails/core/crypto.dart';
import 'package:ibex_trails/core/event_code.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/group.dart';
import 'package:ibex_trails/core/protocol.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/relay_client.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

final _broker = Platform.environment['IBEX_TEST_BROKER'];

Position fixAt(GeoPoint p, {double accuracy = 5}) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: DateTime.now(),
  accuracy: accuracy,
  altitude: 100,
  altitudeAccuracy: 5,
  heading: 90,
  headingAccuracy: 10,
  speed: 3,
  speedAccuracy: 1,
);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? what,
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A second "phone" in the event, driven directly through the protocol.
class SimulatedDevice {
  SimulatedDevice(this.cipher, String host, int port, String id)
    : topics = EventTopics(cipher.topicId),
      relay = RelayClient(host: host, port: port, tls: false, clientId: id);

  final EventCipher cipher;
  final EventTopics topics;
  final RelayClient relay;
  EventInfo? event;
  final courses = <String, Course>{};
  bool eventCleared = false;
  Announcement? announcement;
  final reports = <String, PositionReport>{};

  Future<void> start() async {
    relay.messages.listen((m) async {
      if (m.topic == topics.event) {
        if (m.payload.isEmpty) {
          eventCleared = true;
        } else {
          event = EventInfo.fromJson(await cipher.open(m.payload));
        }
      } else if (topics.courseOf(m.topic) != null && m.payload.isNotEmpty) {
        final u = CourseUpdate.fromJson(await cipher.open(m.payload));
        if (u != null) courses[u.course.id] = u.course;
      } else if (m.topic == topics.announcement && m.payload.isNotEmpty) {
        announcement = Announcement.fromJson(await cipher.open(m.payload));
      } else if (topics.participantOf(m.topic) != null &&
          m.payload.isNotEmpty) {
        final r = PositionReport.fromJson(await cipher.open(m.payload));
        if (r != null) reports[r.id] = r;
      }
    });
    relay.subscribe(topics.all);
    relay.start();
    await waitFor(() => relay.isOnline, what: 'simulated device online');
  }

  Future<void> send(String topic, Object json, {bool retain = true}) async {
    expect(
      relay.publish(topic, await cipher.seal(json), retain: retain),
      isTrue,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (_broker == null) {
    test(
      'group run over MQTT (set IBEX_TEST_BROKER to run)',
      () {},
      skip: 'IBEX_TEST_BROKER not set',
    );
    return;
  }

  late String host;
  late int port;
  late AppSettings settings;

  setUp(() async {
    final parts = _broker!.split(':');
    host = parts[0];
    port = int.parse(parts[1]);
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load()
      ..relayHost = host
      ..relayPort = port
      ..relayTls = false
      ..reportSeconds = 10;
  });

  final route = TrailRoute.fromPoints('River trail', [
    for (var e = 0.0; e <= 4000; e += 100) offset(0, e, 100 + e / 20),
  ]);

  test(
    'organizer shares the route and sees runners, SOS and messages',
    () async {
      settings.displayName = 'Olga';
      final gps = StreamController<Position>();
      // Started 2 h ago; checkpoint at 3 km closed after 1 h.
      final course = Course.fromRoute(route, id: 'c1', name: '4 km').copyWith(
        start: DateTime.now().subtract(const Duration(hours: 2)),
        checkpoints: const [
          Checkpoint(
            id: 'cp1',
            name: 'Bridge',
            kind: CheckpointKind.aid,
            along: 3000,
            cutoff: Duration(hours: 1),
          ),
        ],
      );
      final org = await RunSession.organize(
        settings,
        Notifier(),
        eventName: 'Sunday long run',
        courses: [course],
        locationSource: () => gps.stream,
      );
      addTearDown(org.dispose);
      await waitFor(() => org.relay!.isOnline, what: 'organizer online');
      gps.add(fixAt(offset(0, 10)));

      final cipher = await EventCipher.forCode(org.code!);
      final runner = SimulatedDevice(cipher, host, port, 'sim-runner');
      addTearDown(runner.relay.dispose);
      await runner.start();

      // Event info and the course arrive (retained), identical geometry.
      await waitFor(() => runner.event != null, what: 'event info');
      expect(runner.event!.name, 'Sunday long run');
      expect(runner.event!.organizerName, 'Olga');
      expect(runner.event!.courses.single.name, '4 km');
      await waitFor(() => runner.courses.containsKey('c1'), what: 'course');
      expect(runner.courses['c1']!.route.points, org.route!.points);
      expect(runner.courses['c1']!.checkpoints.single.name, 'Bridge');

      // Two runners report in; one presses SOS.
      final now = DateTime.now();
      final p1 = offset(0, 2500);
      await runner.send(
        runner.topics.position('r1'),
        PositionReport(
          id: 'r1',
          name: 'Rami',
          role: Role.runner,
          time: now,
          lat: p1.lat,
          lon: p1.lon,
          status: RunnerStatus.ok,
          along: 2500,
          battery: 80,
          course: 'c1',
        ).toJson(),
      );
      final p2 = offset(120, 900);
      await runner.send(
        runner.topics.position('r2'),
        PositionReport(
          id: 'r2',
          name: 'Sara',
          role: Role.runner,
          time: now,
          lat: p2.lat,
          lon: p2.lon,
          status: RunnerStatus.sos,
          along: 900,
          offBy: 120,
        ).toJson(),
      );

      await waitFor(() => org.group.length == 3, what: 'three participants');
      expect(org.group.byProgress().map((p) => p.name).take(2), [
        'Rami',
        'Sara',
      ]);
      await waitFor(() => org.alerts.isNotEmpty, what: 'SOS alert');
      expect(org.alerts.first.participant.name, 'Sara');
      // Rami has not reached the bridge, whose cut-off has passed.
      await waitFor(
        () => org.alerts.any((a) => a.kind == AlertKind.cutoffMissed),
        what: 'missed cut-off alert',
      );
      final missed = org.alerts.firstWhere(
        (a) => a.kind == AlertKind.cutoffMissed,
      );
      expect(missed.participant.name, 'Rami');
      expect(missed.detail, startsWith('Bridge closed at'));

      // The organizer's own report reaches the others.
      await waitFor(
        () => runner.reports.containsKey(settings.participantId),
        what: 'organizer report',
      );
      expect(runner.reports[settings.participantId]!.role, Role.organizer);
      expect(runner.reports[settings.participantId]!.along, closeTo(10, 2));

      expect(await org.announce('Regroup at the bridge'), isTrue);
      await waitFor(() => runner.announcement != null, what: 'announcement');
      expect(runner.announcement!.text, 'Regroup at the bridge');

      // Ending the event clears it from the relay.
      await org.leave(endEvent: true);
      await waitFor(() => runner.eventCleared, what: 'event cleared');
      expect(settings.activeEvent, isNull);
      await gps.close();
    },
  );

  test(
    'runner picks a distance, passes a checkpoint, goes off route',
    () async {
      settings.displayName = 'Rami';
      final code = generateEventCode();
      final cipher = await EventCipher.forCode(normalizeEventCode(code)!);
      final organizer = SimulatedDevice(cipher, host, port, 'sim-org');
      addTearDown(organizer.relay.dispose);
      await organizer.start();
      final short = Course(
        id: 'c4',
        name: '4 km',
        route: TrailRoute.fromShareJson(route.toShareJson()),
        checkpoints: const [
          Checkpoint(
            id: 'cp1',
            name: 'Water',
            kind: CheckpointKind.water,
            along: 500,
          ),
        ],
      );
      final long = Course.fromRoute(
        TrailRoute.fromPoints('Long', [
          for (var e = 0.0; e <= 10000; e += 500) offset(-5000, e),
        ]),
        id: 'c10',
        name: '10 km',
      );
      final now = DateTime.now();
      await organizer.send(
        organizer.topics.event,
        EventInfo(
          name: 'Hill repeats',
          organizerId: 'org',
          organizerName: 'Olga',
          organizerPhone: '+201234567',
          updated: now,
          courses: [long.info, short.info],
        ).toJson(),
      );
      for (final c in [short, long]) {
        await organizer.send(
          organizer.topics.course(c.id),
          CourseUpdate(c, now).toJson(),
        );
      }

      final gps = StreamController<Position>();
      final me = await RunSession.join(
        settings,
        Notifier(),
        code: code.toLowerCase(),
        role: Role.runner,
        locationSource: () => gps.stream,
      );
      addTearDown(me.dispose);
      await waitFor(() => me.courses.length == 2, what: 'both courses');
      expect(me.needsCourseChoice, isTrue);
      expect(me.courseList.map((c) => c.name), ['10 km', '4 km']);
      me.selectCourse('c4');
      expect(me.route!.points, short.route.points);
      expect(settings.courseFor(normalizeEventCode(code)!), 'c4');
      expect(me.event!.organizerPhone, '+201234567');
      expect(settings.activeEvent!.code, normalizeEventCode(code));

      for (var e = 0.0; e <= 1000; e += 20) {
        gps.add(fixAt(offset(3, e)));
      }
      await waitFor(() => (me.match?.along ?? 0) > 990, what: 'progress');
      expect(me.status, RunnerStatus.ok);
      expect(me.distanceRun, closeTo(1000, 5));
      expect(me.checkpoints!.passed.keys, ['cp1']);

      // The organizer sees which distance and when the checkpoint was passed.
      await waitFor(
        () => organizer.reports[settings.participantId]?.passes['cp1'] != null,
        what: 'checkpoint pass report',
      );
      expect(organizer.reports[settings.participantId]!.course, 'c4');

      // Wrong turn: 100+ m north of the trail.
      for (var n = 40.0; n <= 160; n += 30) {
        gps.add(fixAt(offset(n, 1000)));
      }
      await waitFor(
        () => me.status == RunnerStatus.offRoute,
        what: 'off route',
      );

      // The organizer gets the off-route status straight away, with the
      // breadcrumb trail of where the runner went.
      await waitFor(
        () =>
            organizer.reports[settings.participantId]?.status ==
            RunnerStatus.offRoute,
        what: 'off-route report',
      );
      final report = organizer.reports[settings.participantId]!;
      expect(report.name, 'Rami');
      expect(report.along, closeTo(1000, 5));
      expect(report.offBy, greaterThan(100));

      await organizer.send(
        organizer.topics.announcement,
        Announcement(
          id: 'm1',
          from: 'Olga',
          text: 'Wait at the hut',
          time: DateTime.now(),
        ).toJson(),
      );
      await waitFor(
        () => me.announcement?.text == 'Wait at the hut',
        what: 'announcement',
      );

      await me.leave();
      await waitFor(
        () =>
            organizer.reports[settings.participantId]?.status ==
            RunnerStatus.left,
        what: 'left status',
      );
      await gps.close();
    },
  );
}
