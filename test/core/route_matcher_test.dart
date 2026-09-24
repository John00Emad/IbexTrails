import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/core/route_matcher.dart';

import '../helpers.dart';

/// Runs [fixes] through a fresh matcher and returns every result.
List<RouteMatch> run(
  TrailRoute route,
  Iterable<GeoPoint> fixes, {
  double accuracy = 5,
}) {
  final m = RouteMatcher(route);
  return [for (final f in fixes) m.update(f, accuracy: accuracy)];
}

void main() {
  final straight = TrailRoute.fromPoints('Straight', eastLine(5000));

  test('tracks progress along the route', () {
    final results = run(straight, [
      for (var e = 0.0; e <= 5000; e += 20) offset(8, e),
    ]);
    expect(results.every((r) => !r.offRoute && !r.wrongWay), isTrue);
    expect(results[50].along, closeTo(1000, 2));
    expect(results[50].distance, closeTo(8, 0.5));
    expect(results.last.finished, isTrue);
    expect(results[100].finished, isFalse);
  });

  test('off route needs consecutive fixes and clears with hysteresis', () {
    final m = RouteMatcher(straight);
    for (var e = 0.0; e < 1000; e += 20) {
      m.update(offset(0, e));
    }
    // Wander north away from the route.
    expect(m.update(offset(80, 1000)).offRoute, isFalse);
    expect(m.update(offset(90, 1000)).offRoute, isFalse);
    final third = m.update(offset(100, 1000));
    expect(third.offRoute, isTrue);
    expect(third.distance, closeTo(100, 1));
    expect(bearingBetween(offset(100, 1000), third.nearest), closeTo(180, 1));

    // Coming back: 45 m is inside the threshold but not below the 80% band.
    expect(m.update(offset(45, 1000)).offRoute, isTrue);
    expect(m.update(offset(20, 1000)).offRoute, isTrue);
    expect(m.update(offset(10, 1000)).offRoute, isFalse);
  });

  test('a single bad fix does not raise an alarm', () {
    final m = RouteMatcher(straight);
    for (var e = 0.0; e < 500; e += 20) {
      m.update(offset(0, e));
    }
    expect(m.update(offset(150, 500)).offRoute, isFalse);
    expect(m.update(offset(0, 520)).offRoute, isFalse);
    expect(m.update(offset(0, 540)).offRoute, isFalse);
    expect(m.update(offset(0, 560)).offRoute, isFalse);
  });

  test('poor accuracy widens the tolerance', () {
    final m = RouteMatcher(straight);
    m.update(offset(0, 0));
    for (var i = 0; i < 5; i++) {
      expect(m.update(offset(65, 100.0 + i), accuracy: 40).offRoute, isFalse);
    }
    for (var i = 0; i < 3; i++) {
      m.update(offset(65, 100.0 + i), accuracy: 5);
    }
    expect(m.last!.offRoute, isTrue);
  });

  test('out-and-back: progress keeps increasing past the turnaround', () {
    // Return leg runs 6 m north of the outbound leg, like a real recording.
    final pts = [...eastLine(3000), ...eastLine(3000, north: 6).reversed];
    final route = TrailRoute.fromPoints('Out and back', pts);
    final fixes = [
      for (var e = 0.0; e <= 3000; e += 15) offset(4, e), // biased north
      for (var e = 3000.0; e >= 0; e -= 15) offset(2, e), // biased south
    ];
    final results = run(route, fixes);
    for (var i = 1; i < results.length; i++) {
      expect(
        results[i].along,
        greaterThanOrEqualTo(results[i - 1].along - 20),
        reason: 'fix $i went backwards',
      );
      expect(results[i].wrongWay, isFalse, reason: 'fix $i wrong way');
    }
    expect(results.last.along, closeTo(route.length, 10));
    expect(results.last.finished, isTrue);
    // The middle of the return leg is ~4.5 km, not 1.5 km.
    expect(results[fixes.length * 3 ~/ 4].along, closeTo(4500, 50));
  });

  test('loop: first fix at the start matches 0 km, not the finish', () {
    final pts = [
      ...eastLine(1000),
      for (var n = 50.0; n <= 1000; n += 50) offset(n, 1000),
      for (var e = 950.0; e >= 0; e -= 50) offset(1000, e),
      for (var n = 950.0; n >= 0; n -= 50) offset(n, 0),
    ];
    final route = TrailRoute.fromPoints('Square', pts);
    expect(route.isLoop, isTrue);
    final r = RouteMatcher(route).update(offset(5, 5));
    expect(r.along, lessThan(20));
    expect(r.finished, isFalse);
  });

  test('wrong way is flagged and clears after turning around', () {
    final m = RouteMatcher(straight);
    for (var e = 0.0; e <= 2000; e += 20) {
      m.update(offset(0, e));
    }
    RouteMatch r = m.last!;
    for (var e = 1980.0; e >= 1860; e -= 20) {
      r = m.update(offset(0, e));
    }
    expect(r.wrongWay, isFalse, reason: 'only 140 m back');
    for (var e = 1840.0; e >= 1700; e -= 20) {
      r = m.update(offset(0, e));
    }
    expect(r.wrongWay, isTrue);
    // Turn around.
    for (var e = 1720.0; e <= 1760; e += 20) {
      r = m.update(offset(0, e));
    }
    expect(r.wrongWay, isFalse);
  });

  test('continues after a GPS gap without flagging a jump', () {
    final m = RouteMatcher(straight);
    m.update(offset(0, 0));
    m.update(offset(0, 20));
    // No signal for 2.5 km.
    final r = m.update(offset(0, 2600));
    expect(r.along, closeTo(2600, 2));
    expect(r.jump, 0);
    expect(r.offRoute, isFalse);
  });

  test('a shortcut onto a later part of the route is reported as a jump', () {
    // U shape: 2 km east, 300 m north, 2 km back west.
    final route = TrailRoute.fromPoints('U', [
      offset(0, 0),
      offset(0, 2000),
      offset(300, 2000),
      offset(300, 0),
    ]);
    final m = RouteMatcher(route);
    for (var e = 0.0; e <= 1000; e += 20) {
      m.update(offset(0, e));
    }
    RouteMatch r = m.last!;
    for (var n = 20.0; n <= 300; n += 20) {
      r = m.update(offset(n, 1000));
      if (r.jump != 0) break;
    }
    expect(r.jump, greaterThan(1500));
    expect(r.along, closeTo(3300, 30));
    // Back on a trail of the route: the off-route alarm clears after the
    // usual hysteresis, and progress continues from the new section.
    r = m.update(offset(300, 980));
    r = m.update(offset(300, 960));
    expect(r.offRoute, isFalse);
    expect(r.wrongWay, isFalse);
    expect(r.jump, 0);
    expect(r.along, closeTo(3340, 5));
  });

  test('ignores fixes with very poor accuracy once initialised', () {
    final m = RouteMatcher(straight);
    m.update(offset(0, 100));
    final r = m.update(offset(400, 100), accuracy: 500);
    expect(r.distance, closeTo(0, 1));
  });
}
