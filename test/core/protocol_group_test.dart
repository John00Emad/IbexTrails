import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/course.dart';
import 'package:ibex_trails/core/group.dart';
import 'package:ibex_trails/core/protocol.dart';
import 'package:ibex_trails/core/route.dart';

import '../helpers.dart';

PositionReport report(
  String id,
  DateTime t, {
  double north = 0,
  double east = 0,
  RunnerStatus status = RunnerStatus.ok,
  double? along,
  int? battery,
  List<TrailPoint> trail = const [],
  Role role = Role.runner,
  String? course,
  bool safe = false,
}) {
  final p = offset(north, east);
  return PositionReport(
    id: id,
    name: 'Runner $id',
    role: role,
    time: t,
    lat: p.lat,
    lon: p.lon,
    status: status,
    along: along,
    battery: battery,
    trail: trail,
    course: course,
    safe: safe,
  );
}

void main() {
  final t0 = DateTime(2026, 9, 1, 6);

  test('position report JSON round trip', () {
    final r = PositionReport(
      id: 'abc',
      name: 'Mona',
      role: Role.sweeper,
      time: t0,
      lat: 30.1234567,
      lon: 31.7654321,
      status: RunnerStatus.offRoute,
      accuracy: 7.6,
      elevation: 512.4,
      speed: 2.345,
      along: 4321.5,
      offBy: 88.2,
      battery: 54,
      trail: [TrailPoint(30.1, 31.7, t0.subtract(const Duration(seconds: 30)))],
    );
    final copy = PositionReport.fromJson(r.toJson())!;
    expect(copy.id, 'abc');
    expect(copy.name, 'Mona');
    expect(copy.role, Role.sweeper);
    expect(copy.time, t0);
    expect(copy.lat, closeTo(30.123457, 1e-9));
    expect(copy.status, RunnerStatus.offRoute);
    expect(copy.accuracy, 8);
    expect(copy.speed, 2.3);
    expect(copy.along, 4322);
    expect(copy.battery, 54);
    expect(copy.trail.single.time, t0.subtract(const Duration(seconds: 30)));
    expect(PositionReport.fromJson({'t': 'pos'}), isNull);
    expect(PositionReport.fromJson('junk'), isNull);
  });

  test('event info lists courses; courses travel separately', () {
    final route = TrailRoute.fromPoints('R', eastLine(2000, step: 100));
    final course = Course.fromRoute(route, id: 'c10', name: '10 km');
    final info = EventInfo(
      name: 'Sunday long run',
      organizerId: 'org1',
      organizerName: 'Sam',
      organizerPhone: '+201000000000',
      updated: t0,
      courses: [course.info],
    );
    final copy = EventInfo.fromJson(info.toJson())!;
    expect(copy.name, 'Sunday long run');
    expect(copy.organizerPhone, '+201000000000');
    expect(copy.courses.single.name, '10 km');
    expect(copy.courses.single.length, closeTo(2000, 2));

    final update = CourseUpdate.fromJson(CourseUpdate(course, t0).toJson())!;
    expect(update.updated, t0);
    expect(update.course.route.points, route.points);
  });

  test('old single-route event info still decodes', () {
    final route = TrailRoute.fromPoints('R', eastLine(2000, step: 100));
    final legacy = {
      't': 'event',
      'n': 'Old',
      'oi': 'o',
      'u': t0.millisecondsSinceEpoch,
      'rt': route.toShareJson(),
    };
    final info = EventInfo.fromJson(legacy)!;
    expect(info.courses, isEmpty);
    expect(info.legacyRoute!.points, route.points);
  });

  test('position report carries course and checkpoint timing', () {
    final r = PositionReport(
      id: 'a',
      name: 'A',
      role: Role.runner,
      time: t0,
      lat: 1,
      lon: 2,
      status: RunnerStatus.ok,
      course: 'c25',
      passes: {'cp1': t0.subtract(const Duration(minutes: 30))},
      next: 'cp2',
      eta: t0.add(const Duration(minutes: 40)),
      started: t0.subtract(const Duration(hours: 1)),
    );
    final copy = PositionReport.fromJson(r.toJson())!;
    expect(copy.course, 'c25');
    expect(copy.passes['cp1'], t0.subtract(const Duration(minutes: 30)));
    expect(copy.next, 'cp2');
    expect(copy.eta, t0.add(const Duration(minutes: 40)));
    expect(copy.started, t0.subtract(const Duration(hours: 1)));
  });

  test('topics', () {
    const t = EventTopics('abc123');
    expect(t.position('p1'), 'ibextrails/v1/abc123/pos/p1');
    expect(t.participantOf('ibextrails/v1/abc123/pos/p1'), 'p1');
    expect(t.participantOf('ibextrails/v1/abc123/event'), isNull);
    expect(t.course('c5'), 'ibextrails/v1/abc123/course/c5');
    expect(t.courseOf('ibextrails/v1/abc123/course/c5'), 'c5');
    expect(t.courseOf('ibextrails/v1/abc123/pos/c5'), isNull);
  });

  test('group ordering, stale reports and trail merging', () {
    final g = Group();
    g.apply(report('a', t0, along: 1000), t0);
    g.apply(report('b', t0, along: 3000), t0);
    g.apply(report('c', t0), t0);
    expect(g.byProgress().map((p) => p.id), ['b', 'a', 'c']);
    final (leader, last) = g.spread()!;
    expect(leader.id, 'b');
    expect(last.id, 'a');

    // Older report is ignored.
    expect(
      g.apply(report('a', t0.subtract(const Duration(seconds: 1))), t0),
      isFalse,
    );
    // Trail points are merged in order.
    final t1 = t0.add(const Duration(minutes: 1));
    g.apply(
      report(
        'a',
        t1,
        east: 200,
        trail: [
          TrailPoint(
            offset(0, 100).lat,
            offset(0, 100).lon,
            t0.add(const Duration(seconds: 30)),
          ),
        ],
      ),
      t1,
    );
    expect(g['a']!.track.length, 3);
  });

  test('alerts: SOS, no signal, off route, not moving, low battery', () {
    final g = Group();
    const policy = AlertPolicy();
    g.apply(report('sos', t0, status: RunnerStatus.sos), t0);
    g.apply(report('quiet', t0), t0);
    g.apply(report('lost', t0, status: RunnerStatus.offRoute), t0);
    g.apply(report('flat', t0, battery: 9), t0);
    g.apply(report('done', t0, status: RunnerStatus.finished), t0);

    final now = t0.add(const Duration(minutes: 1));
    // A runner who moved, then stood still for 12 minutes while reporting.
    g.apply(report('still', t0), t0);
    g.apply(
      report('still', t0.add(const Duration(seconds: 30)), east: 100),
      now,
    );
    final later = t0.add(const Duration(minutes: 12, seconds: 30));
    g.apply(report('still', later, east: 105), later);
    g.apply(report('sos', later, status: RunnerStatus.sos), later);
    g.apply(report('lost', later, status: RunnerStatus.offRoute), later);
    g.apply(report('flat', later, battery: 9), later);

    final alerts = g.alerts(later, policy);
    final kinds = {
      for (final a in alerts) '${a.participant.id}:${a.kind.name}',
    };
    expect(kinds, {
      'sos:sos',
      'quiet:noSignal',
      'lost:offRoute',
      'flat:lowBattery',
      'still:stopped',
    });
    expect(alerts.first.kind, AlertKind.sos);

    final latch = AlertLatch();
    expect(latch.newlyRaised(alerts).length, 5);
    expect(latch.newlyRaised(alerts), isEmpty);
    expect(
      latch.newlyRaised(alerts.where((a) => a.kind != AlertKind.sos).toList()),
      isEmpty,
    );
    expect(latch.newlyRaised(alerts).single.kind, AlertKind.sos);
  });

  test('someone waiting at the start is not "not moving"', () {
    final g = Group();
    g.apply(report('w', t0), t0);
    final later = t0.add(const Duration(minutes: 30));
    g.apply(report('w', later, east: 5), later);
    expect(g.alerts(later, const AlertPolicy()), isEmpty);
  });

  test('cut-off alerts and the checkpoint board', () {
    final course = Course(
      id: 'c25',
      name: '25 km',
      route: TrailRoute.fromPoints('R', eastLine(25000, step: 1000)),
      start: t0,
      checkpoints: const [
        Checkpoint(
          id: 'cp1',
          name: 'CP1',
          kind: CheckpointKind.aid,
          along: 10000,
          cutoff: Duration(hours: 2),
        ),
        Checkpoint(
          id: 'cp2',
          name: 'CP2',
          kind: CheckpointKind.aid,
          along: 20000,
          cutoff: Duration(hours: 4),
        ),
      ],
    );
    final now = t0.add(const Duration(hours: 2, minutes: 10));
    PositionReport on(
      String id,
      double along, {
      Map<String, DateTime> passes = const {},
      String? next,
      DateTime? eta,
    }) => PositionReport(
      id: id,
      name: id,
      role: Role.runner,
      time: now,
      lat: 0,
      lon: 0,
      status: RunnerStatus.ok,
      along: along,
      course: 'c25',
      passes: passes,
      next: next,
      eta: eta,
    );
    final g = Group()
      ..apply(
        on(
          'fast',
          15000,
          passes: {'cp1': t0.add(const Duration(hours: 1))},
          next: 'cp2',
          eta: t0.add(const Duration(hours: 3)),
        ),
        now,
      )
      ..apply(
        on(
          'slow',
          16000,
          passes: {'cp1': t0.add(const Duration(minutes: 110))},
          next: 'cp2',
          eta: t0.add(const Duration(hours: 4, minutes: 20)),
        ),
        now,
      )
      ..apply(on('late', 9000, next: 'cp1'), now)
      ..apply(report('other', now, along: 1000), now);

    final alerts = g.alerts(
      now,
      const AlertPolicy(),
      courseOf: (id) => id == 'c25' ? course : null,
    );
    final keys = {for (final a in alerts) a.key};
    expect(keys, {'late/cutoffMissed/cp1', 'slow/cutoffRisk/cp2'});
    expect(alerts.first.detail, 'CP1 closed at 08:00');

    final board = g.checkpointBoard(course, now);
    expect(board[0].passed.map((e) => e.$1.id), ['fast', 'slow']);
    expect(board[0].missed.single.id, 'late');
    expect(board[1].pending.map((p) => p.id).toSet(), {'fast', 'slow', 'late'});
    expect(board[0].cutoff, t0.add(const Duration(hours: 2)));

    expect(g.byProgress(course: 'c25').map((p) => p.id), [
      'slow',
      'fast',
      'late',
    ]);
    expect(g.spread(course: 'c25')!.$1.id, 'slow');
  });

  test('safe flag and roster JSON round trip', () {
    final left = report('a', t0, status: RunnerStatus.left, safe: true);
    expect(PositionReport.fromJson(left.toJson())!.safe, isTrue);
    expect(PositionReport.fromJson(report('b', t0).toJson())!.safe, isFalse);

    final roster = Roster({'c': 'Picked up at CP2'}, t0);
    final copy = Roster.fromJson(roster.toJson())!;
    expect(copy.accountedFor, {'c': 'Picked up at CP2'});
    expect(copy.updated, t0);
    expect(Roster.fromJson({'t': 'pos'}), isNull);
    const t = EventTopics('abc');
    expect(t.roster, 'ibextrails/v1/abc/roster');
  });

  test('headcount sorts everyone into buckets', () {
    final now = t0.add(const Duration(hours: 2));
    final g = Group();
    // Waiting at the start.
    g.apply(report('start', now), now);
    // Out on the course.
    g.apply(report('out', t0, along: 3000), t0);
    g.apply(report('out', now, east: 300, along: 5000), now);
    // Finished.
    g.apply(report('done', now, status: RunnerStatus.finished), now);
    // Dropped out and confirmed safe.
    g.apply(report('safe', now, status: RunnerStatus.left, safe: true), now);
    // Closed the app without confirming.
    g.apply(report('gone', now, status: RunnerStatus.left), now);
    // Silent for 20 minutes.
    final quiet = now.subtract(const Duration(minutes: 20));
    g.apply(report('quiet', quiet, along: 4000), quiet);
    // Silent, but the organizer ticked them off.
    g.apply(report('car', quiet, along: 2000), quiet);
    // The organizer's own phone.
    g.apply(report('org', now), now);

    final hc = g.headcount(now, accountedFor: {'car'}, exclude: 'org');
    List<String> ids(List<Participant> ps) => [for (final p in ps) p.id];
    expect(ids(hc.notStarted), ['start']);
    expect(ids(hc.onCourse), ['out']);
    expect(ids(hc.finished), ['done']);
    expect(ids(hc.safeOut).toSet(), {'safe', 'car'});
    expect(ids(hc.unaccounted).toSet(), {'gone', 'quiet'});
    expect(hc.total, 7);
    expect(hc.accountedFor, 3);
    expect(hc.allIn, isFalse);

    final home = Group()
      ..apply(report('a', now, status: RunnerStatus.finished), now)
      ..apply(report('b', now, status: RunnerStatus.left, safe: true), now);
    expect(home.headcount(now).allIn, isTrue);
    expect(Group().headcount(now).allIn, isFalse);
  });

  test('alerts: left without confirming, and behind the sweeper', () {
    final now = t0.add(const Duration(hours: 1));
    final g = Group()
      ..apply(
        report('sweep', now, role: Role.sweeper, along: 4000, course: 'c1'),
        now,
      )
      ..apply(report('slow', now, along: 3850, course: 'c1'), now)
      ..apply(report('lost', now, along: 3000, course: 'c1'), now)
      ..apply(report('other', now, along: 1000, course: 'c2'), now)
      ..apply(report('gone', now, status: RunnerStatus.left), now)
      ..apply(report('fine', now, status: RunnerStatus.left, safe: true), now);
    final keys = {for (final a in g.alerts(now, const AlertPolicy())) a.key};
    expect(keys, {'lost/behindSweeper/', 'gone/leftUnconfirmed/'});

    // Ticked off by the organizer: no more alerts for them.
    final ticked = {
      for (final a in g.alerts(
        now,
        const AlertPolicy(),
        accountedFor: {'gone', 'lost'},
      ))
        a.key,
    };
    expect(ticked, isEmpty);
  });
}
