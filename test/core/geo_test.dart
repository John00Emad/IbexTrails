import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/geo.dart';

import '../helpers.dart';

void main() {
  test('haversine matches known distances', () {
    // One degree of latitude is ~111.2 km.
    expect(haversine(0, 0, 1, 0), closeTo(111195, 5));
    expect(distanceBetween(offset(0, 0), offset(0, 1000)), closeTo(1000, 1));
  });

  test('bearing and compass names', () {
    expect(bearingBetween(offset(0, 0), offset(1000, 0)), closeTo(0, 0.5));
    expect(bearingBetween(offset(0, 0), offset(0, 1000)), closeTo(90, 0.5));
    expect(compassName(0), 'N');
    expect(compassName(44), 'NE');
    expect(compassName(359), 'N');
    expect(compassName(200), 'SSW');
  });

  test('projection onto segment', () {
    final p = projectOntoSegment(
      offset(30, 500),
      offset(0, 0),
      offset(0, 1000),
    );
    expect(p.distance, closeTo(30, 0.5));
    expect(p.t, closeTo(0.5, 0.001));
    final beyond = projectOntoSegment(
      offset(0, 1100),
      offset(0, 0),
      offset(0, 1000),
    );
    expect(beyond.t, 1);
    expect(beyond.distance, closeTo(100, 0.5));
  });

  test('Douglas-Peucker keeps corners and drops collinear points', () {
    final pts = [
      ...eastLine(1000, step: 10),
      for (var n = 10.0; n <= 1000; n += 10) offset(n, 1000),
    ];
    final s = simplifyPolyline(pts, 2);
    expect(s.length, 3);
    expect(s.first, pts.first);
    expect(s.last, pts.last);
  });

  test('formatting', () {
    expect(formatDistance(850.4), '850 m');
    expect(formatDistance(4250), '4.25 km');
    expect(formatDistance(12345), '12.3 km');
    expect(formatDuration(const Duration(minutes: 5, seconds: 7)), '5:07');
    expect(
      formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
