import 'package:flutter_test/flutter_test.dart';
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
}) {
  final p = offset(north, east);
  return PositionReport(
    id: id,
    name: 'Runner $id',
    role: Role.runner,
    time: t,
    lat: p.lat,
    lon: p.lon,
    status: status,
    along: along,
    battery: battery,
    trail: trail,
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

  test('event info carries the route', () {
    final route = TrailRoute.fromPoints('R', eastLine(2000, step: 100));
    final info = EventInfo(
      name: 'Sunday long run',
      organizerId: 'org1',
      organizerName: 'Sam',
      organizerPhone: '+201000000000',
      updated: t0,
      route: route,
    );
    final copy = EventInfo.fromJson(info.toJson())!;
    expect(copy.name, 'Sunday long run');
    expect(copy.organizerPhone, '+201000000000');
    expect(copy.route!.points, route.points);
  });

  test('topics', () {
    const t = EventTopics('abc123');
    expect(t.position('p1'), 'ibextrails/v1/abc123/pos/p1');
    expect(t.participantOf('ibextrails/v1/abc123/pos/p1'), 'p1');
    expect(t.participantOf('ibextrails/v1/abc123/event'), isNull);
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
}
