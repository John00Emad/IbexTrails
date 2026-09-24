import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/checkpoints.dart';
import 'package:ibex_trails/core/course.dart';
import 'package:ibex_trails/core/effort.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/core/route_matcher.dart';

import '../helpers.dart';

void main() {
  final t0 = DateTime(2026, 10, 2, 6);

  // 3 km out, 3 km back, water point at 1 km (passed at 1 km and 5 km).
  final outBack = TrailRoute.fromPoints(
    'Out and back',
    [...eastLine(3000), ...eastLine(3000).reversed.skip(1)],
    waypoints: [
      GpxWaypoint('Water', offset(10, 1000)),
      GpxWaypoint('Turnaround aid station', offset(0, 3000)),
    ],
  );

  test('waypoints become one checkpoint per pass, with a guessed kind', () {
    final cps = Course.checkpointsFromWaypoints(outBack);
    expect(cps.map((c) => c.name), [
      'Water (pass 1)',
      'Turnaround aid station',
      'Water (pass 2)',
    ]);
    expect(cps.map((c) => c.id), ['cp1', 'cp2', 'cp3']);
    expect(cps[0].kind, CheckpointKind.water);
    expect(cps[1].kind, CheckpointKind.aid);
    expect(cps[0].along, closeTo(1000, 5));
    expect(cps[2].along, closeTo(5000, 5));
  });

  test('course share JSON round trip', () {
    final course = Course.fromRoute(
      outBack,
      id: 'c25',
      name: '25 km',
    ).copyWith(start: t0);
    final withCutoff = course.copyWith(
      checkpoints: [
        course.checkpoints[0],
        course.checkpoints[1].copyWith(cutoff: const Duration(minutes: 90)),
        course.checkpoints[2],
      ],
    );
    final copy = Course.fromShareJson(withCutoff.toShareJson());
    expect(copy.id, 'c25');
    expect(copy.name, '25 km');
    expect(copy.start, t0);
    expect(copy.route.points, outBack.points);
    expect(copy.checkpoints[1].cutoff, const Duration(minutes: 90));
    expect(
      copy.cutoffTime(copy.checkpoints[1]),
      t0.add(const Duration(minutes: 90)),
    );
    expect(copy.checkpoints[0].cutoff, isNull);
    expect(copy.info.length, closeTo(6000, 5));
    expect(Course.defaultName(outBack), '6.0 km');
  });

  test('km-effort counts 100 m of climbing as 1 km', () {
    final hill = TrailRoute.fromPoints('Hill', [
      offset(0, 0, 100),
      offset(0, 2000, 400),
    ]);
    expect(effortKm(hill, 0, hill.length), closeTo(2 + 3, 0.05));
    expect(effortKm(hill, hill.length, 0), closeTo(5, 0.05));
  });

  test('pace estimator projects arrival from recent progress', () {
    final flat = TrailRoute.fromPoints('Flat', eastLine(20000));
    final p = PaceEstimator(flat);
    // No data yet: fallback 8 min/km-effort.
    expect(p.timeBetween(0, 1000), const Duration(minutes: 8));
    // 6 min/km for 20 minutes.
    for (var m = 0; m <= 20; m++) {
      p.add(t0.add(Duration(minutes: m)), m * 1000 / 6);
    }
    expect(p.minPerEffortKm, closeTo(6, 0.01));
    expect(p.arrival(t0, 0, 10000), t0.add(const Duration(minutes: 60)));
  });

  test('checkpoint tracker records passes on the right leg', () {
    final course = Course.fromRoute(outBack).copyWith(start: t0);
    final matcher = RouteMatcher(course.route);
    final tracker = CheckpointTracker(course);
    final passedAt = <String, double>{};
    var t = t0;
    final fixes = [
      for (var e = 0.0; e <= 3000; e += 20) offset(3, e),
      for (var e = 3000.0; e >= 0; e -= 20) offset(3, e),
    ];
    for (final f in fixes) {
      t = t.add(const Duration(seconds: 6));
      final m = matcher.update(f);
      for (final cp in tracker.update(m, f, t)) {
        passedAt[cp.id] = m.along;
      }
    }
    expect(passedAt.keys, ['cp1', 'cp2', 'cp3']);
    expect(passedAt['cp1'], closeTo(1000, 100));
    expect(passedAt['cp3'], closeTo(5000, 100));
    expect(tracker.next, isNull);
  });

  test('a shortcut does not credit the skipped checkpoint', () {
    // U shape; checkpoint in the middle of the far side.
    final u = TrailRoute.fromPoints('U', [
      offset(0, 0),
      offset(0, 2000),
      offset(600, 2000),
      offset(600, 0),
    ]);
    final course = Course(
      id: 'u',
      name: 'U',
      route: u,
      checkpoints: const [
        Checkpoint(
          id: 'far',
          name: 'Far',
          kind: CheckpointKind.checkpoint,
          along: 2300,
        ),
        Checkpoint(
          id: 'end',
          name: 'End',
          kind: CheckpointKind.checkpoint,
          along: 3900,
        ),
      ],
    );
    final matcher = RouteMatcher(u);
    final tracker = CheckpointTracker(course);
    var t = t0;
    final fixes = [
      for (var e = 0.0; e <= 1000; e += 20) offset(0, e),
      for (var n = 20.0; n <= 600; n += 20) offset(n, 1000), // cut across
      for (var e = 980.0; e >= 0; e -= 20) offset(600, e),
    ];
    for (final f in fixes) {
      t = t.add(const Duration(seconds: 6));
      tracker.update(matcher.update(f), f, t);
    }
    expect(tracker.passed.containsKey('far'), isFalse);
    expect(tracker.passed.containsKey('end'), isTrue);
  });

  test('outlook: margin against the cut-off and missed checkpoints', () {
    final flat = TrailRoute.fromPoints('Flat', eastLine(10000));
    final course = Course(
      id: 'c',
      name: '10 km',
      route: flat,
      start: t0,
      checkpoints: const [
        Checkpoint(
          id: 'cp1',
          name: 'CP1',
          kind: CheckpointKind.aid,
          along: 5000,
          cutoff: Duration(minutes: 40),
        ),
      ],
    );
    final matcher = RouteMatcher(flat);
    final tracker = CheckpointTracker(course);
    // 6 min/km for 12 minutes: at 2 km.
    for (var s = 0; s <= 720; s += 6) {
      final f = offset(0, s * 1000 / 360);
      tracker.update(matcher.update(f), f, t0.add(Duration(seconds: s)));
    }
    final now = t0.add(const Duration(minutes: 12));
    final o = tracker.outlook(now)!;
    expect(o.checkpoint.id, 'cp1');
    expect(o.distance, closeTo(3000, 5));
    // 3 km at 6 min/km = 18 min -> 12 + 18 = 30 min; cut-off at 40.
    expect(o.eta.difference(t0).inMinutes, closeTo(30, 1));
    expect(o.margin!.inMinutes, closeTo(10, 1));
    expect(o.atRisk, isFalse);
    expect(tracker.missed(now), isEmpty);
    expect(
      tracker.missed(t0.add(const Duration(minutes: 41))).single.id,
      'cp1',
    );
  });

  test('casual runs: cut-offs count from the runner start', () {
    final course = Course(
      id: 'c',
      name: 'x',
      route: TrailRoute.fromPoints('x', eastLine(1000)),
      checkpoints: const [
        Checkpoint(
          id: 'a',
          name: 'A',
          kind: CheckpointKind.checkpoint,
          along: 500,
          cutoff: Duration(minutes: 10),
        ),
      ],
    );
    expect(course.cutoffTime(course.checkpoints.single), isNull);
    expect(
      course.cutoffTime(course.checkpoints.single, runnerStart: t0),
      t0.add(const Duration(minutes: 10)),
    );
    expect(
      distanceBetween(
        course.pointOf(course.checkpoints.single),
        offset(0, 500),
      ),
      lessThan(2),
    );
  });
}
