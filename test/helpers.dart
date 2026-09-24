import 'dart:math' as math;

import 'package:ibex_trails/core/geo.dart';

const originLat = 30.0;
const originLon = 31.0;

/// Point [north] / [east] metres from a fixed origin.
GeoPoint offset(double north, double east, [double? ele]) {
  const mPerDegLat = earthRadiusM * math.pi / 180;
  final mPerDegLon = mPerDegLat * math.cos(originLat * math.pi / 180);
  return GeoPoint(
    originLat + north / mPerDegLat,
    originLon + east / mPerDegLon,
    ele,
  );
}

/// A straight line east from the origin, one point every [step] metres.
List<GeoPoint> eastLine(double length, {double step = 50, double north = 0}) =>
    [for (var e = 0.0; e <= length + 1e-9; e += step) offset(north, e)];
