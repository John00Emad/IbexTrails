import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/core/route.dart';

import '../helpers.dart';

void main() {
  test('length, climbing and interpolation', () {
    final pts = [
      offset(0, 0, 100),
      offset(0, 500, 150),
      offset(0, 1000, 120),
      offset(0, 1500, 200),
    ];
    final route = TrailRoute.fromPoints('Hill', pts);
    expect(route.length, closeTo(1500, 3));
    expect(route.totalAscent, closeTo(130, 0.001));
    expect(route.totalDescent, closeTo(30, 0.001));
    expect(route.ascentAt(250), closeTo(25, 1));
    expect(route.ascentRemaining(750), closeTo(80, 0.5));
    expect(route.elevationAt(250), closeTo(125, 1));
    expect(route.pointAt(750).lon, closeTo(offset(0, 750).lon, 1e-5));
    expect(route.isLoop, isFalse);
  });

  test('elevation noise below threshold does not add up', () {
    final pts = [
      for (var i = 0; i < 100; i++)
        offset(0, i * 20.0, 100.0 + (i.isEven ? 0 : 2)),
    ];
    final route = TrailRoute.fromPoints('Flat', pts, simplifyTolerance: 0.1);
    expect(route.totalAscent, 0);
  });

  test('simplification removes redundant points', () {
    final route = TrailRoute.fromPoints('Line', eastLine(5000, step: 5));
    expect(route.points.length, 2);
    expect(route.length, closeTo(5000, 3));
  });

  test('out-and-back waypoints are passed twice', () {
    final pts = [...eastLine(3000), ...eastLine(3000).reversed.skip(1)];
    final route = TrailRoute.fromPoints(
      'Out and back',
      pts,
      waypoints: [GpxWaypoint('Water', offset(10, 1000))],
    );
    expect(route.isLoop, isTrue);
    final passes = route.waypoints.single.passes;
    expect(passes.length, 2);
    expect(passes[0], closeTo(1000, 5));
    expect(passes[1], closeTo(5000, 5));

    final next = route.nextWaypoint(2000)!;
    expect(next.along, closeTo(5000, 5));
    expect(next.distanceAhead, closeTo(3000, 5));
    expect(route.nextWaypoint(5100), isNull);
  });

  test('share encoding round-trips exactly', () {
    final pts = [
      for (var i = 0; i <= 40; i++)
        offset(i * 37.0, (i % 7) * 55.0, 300 + i * 3.3),
    ];
    final route = TrailRoute.fromPoints(
      'Zig zag',
      pts,
      waypoints: [GpxWaypoint('Hut', offset(200, 100), description: 'Cafe')],
    );
    final copy = TrailRoute.fromShareJson(route.toShareJson());
    expect(copy.name, route.name);
    expect(copy.points, route.points);
    expect(copy.length, route.length);
    expect(copy.totalAscent, route.totalAscent);
    expect(copy.waypoints.single.name, 'Hut');
    expect(copy.waypoints.single.description, 'Cafe');
  });

  test('share encoding without elevation', () {
    final route = TrailRoute.fromPoints('2D', [offset(0, 0), offset(500, 500)]);
    expect(route.hasElevation, isFalse);
    final copy = TrailRoute.fromShareJson(route.toShareJson());
    expect(copy.points, route.points);
    expect(copy.hasElevation, isFalse);
  });
}
