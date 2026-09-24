import 'dart:math' as math;

import 'geo.dart';
import 'gpx.dart';

/// A waypoint placed along the route.
class RouteWaypoint {
  const RouteWaypoint({
    required this.name,
    required this.point,
    required this.passes,
    this.description,
  });

  final String name;
  final GeoPoint point;
  final String? description;

  /// Distances along the route (m) at which the route passes this waypoint.
  /// Out-and-back or loop routes may pass the same point more than once.
  /// Empty if the waypoint is far from the route.
  final List<double> passes;
}

/// The next waypoint ahead of the runner.
class UpcomingWaypoint {
  const UpcomingWaypoint(this.waypoint, this.along, this.distanceAhead);
  final RouteWaypoint waypoint;
  final double along;
  final double distanceAhead;
}

/// A navigable route: a polyline with cumulative distance and climbing
/// profile, plus waypoints.
class TrailRoute {
  TrailRoute._(this.name, this.points, this.waypoints)
    : cumDist = _cumulativeDistance(points),
      hasElevation = points.every((p) => p.ele != null) {
    final (asc, desc) = _cumulativeClimb(points);
    cumAscent = asc;
    cumDescent = desc;
  }

  /// Builds a route from raw points, simplifying away GPS jitter.
  factory TrailRoute.fromPoints(
    String name,
    List<GeoPoint> points, {
    List<GpxWaypoint> waypoints = const [],
    double simplifyTolerance = 2.0,
    int maxPoints = 5000,
  }) {
    if (points.length < 2) {
      throw ArgumentError('A route needs at least two points');
    }
    final filled = _fillElevation(points);
    var tolerance = simplifyTolerance;
    var vertical = 3.0;
    var simplified = simplifyPolyline(
      filled,
      tolerance,
      verticalTolerance: vertical,
    );
    while (simplified.length > maxPoints) {
      tolerance *= 1.5;
      vertical *= 1.5;
      simplified = simplifyPolyline(
        filled,
        tolerance,
        verticalTolerance: vertical,
      );
    }
    // Quantise to ~1 m so a route shared over the network is identical on
    // every device (progress comparisons depend on it).
    final quantised = [
      for (final p in simplified)
        GeoPoint(_q(p.lat), _q(p.lon), p.ele?.roundToDouble()),
    ];
    return TrailRoute._exact(name, quantised, waypoints);
  }

  factory TrailRoute.fromGpx(GpxData gpx, {String fallbackName = 'Route'}) =>
      TrailRoute.fromPoints(
        gpx.name ?? fallbackName,
        gpx.track,
        waypoints: gpx.waypoints,
      );

  /// Builds a route from points that are used exactly as given.
  factory TrailRoute._exact(
    String name,
    List<GeoPoint> points,
    List<GpxWaypoint> wpts,
  ) {
    final route = TrailRoute._(name, List.unmodifiable(points), const []);
    final placed = [
      for (final w in wpts)
        RouteWaypoint(
          name: w.name,
          point: w.point,
          description: w.description,
          passes: route._passesNear(w.point, 60),
        ),
    ];
    return TrailRoute._(name, route.points, List.unmodifiable(placed));
  }

  final String name;
  final List<GeoPoint> points;
  final List<RouteWaypoint> waypoints;

  /// `cumDist[i]` is the distance along the route to `points[i]` in metres.
  final List<double> cumDist;

  /// Cumulative ascent / descent (m) to each point, with noise filtering.
  late final List<double> cumAscent;
  late final List<double> cumDescent;

  final bool hasElevation;

  double get length => cumDist.last;
  double get totalAscent => cumAscent.last;
  double get totalDescent => cumDescent.last;
  GeoPoint get start => points.first;
  GeoPoint get finish => points.last;

  /// True if the finish is close to the start.
  bool get isLoop => distanceBetween(start, finish) < 200;

  /// Southwest and northeast corners of the bounding box.
  (GeoPoint, GeoPoint) get bounds {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    return (GeoPoint(minLat, minLon), GeoPoint(maxLat, maxLon));
  }

  /// Index of the segment containing [along] (segment i spans points i..i+1).
  int segmentIndexAt(double along) {
    if (along <= 0) return 0;
    if (along >= length) return points.length - 2;
    var lo = 0, hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cumDist[mid] <= along) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double _fraction(int seg, double along) {
    final segLen = cumDist[seg + 1] - cumDist[seg];
    return segLen <= 0 ? 0 : ((along - cumDist[seg]) / segLen).clamp(0.0, 1.0);
  }

  /// Interpolated position at [along] metres from the start.
  GeoPoint pointAt(double along) {
    final i = segmentIndexAt(along);
    final t = _fraction(i, along);
    final a = points[i], b = points[i + 1];
    final ele = (a.ele != null && b.ele != null)
        ? a.ele! + (b.ele! - a.ele!) * t
        : null;
    return GeoPoint(
      a.lat + (b.lat - a.lat) * t,
      a.lon + (b.lon - a.lon) * t,
      ele,
    );
  }

  double? elevationAt(double along) => pointAt(along).ele;

  /// Cumulative ascent from the start to [along].
  double ascentAt(double along) {
    final i = segmentIndexAt(along);
    final t = _fraction(i, along);
    return cumAscent[i] + (cumAscent[i + 1] - cumAscent[i]) * t;
  }

  /// Ascent still to climb after [along].
  double ascentRemaining(double along) => totalAscent - ascentAt(along);

  /// The first waypoint pass strictly ahead of [along].
  UpcomingWaypoint? nextWaypoint(double along) {
    UpcomingWaypoint? best;
    for (final w in waypoints) {
      for (final pass in w.passes) {
        if (pass <= along + 15) continue;
        if (best == null || pass < best.along) {
          best = UpcomingWaypoint(w, pass, pass - along);
        }
      }
    }
    return best;
  }

  /// Distances along the route where it passes within [radius] metres of [p]
  /// (one value per separate pass, at the closest point of that pass).
  List<double> _passesNear(GeoPoint p, double radius) {
    // Closest point of every nearby segment, in route order.
    final near = <(double along, double dist)>[];
    for (var i = 0; i < points.length - 1; i++) {
      final proj = projectOntoSegment(p, points[i], points[i + 1]);
      if (proj.distance <= radius) {
        near.add((
          cumDist[i] + proj.t * (cumDist[i + 1] - cumDist[i]),
          proj.distance,
        ));
      }
    }
    // Candidates within 200 m of each other along the route belong to the
    // same pass; keep the closest of each.
    final passes = <(double, double)>[];
    for (final c in near) {
      if (passes.isNotEmpty && c.$1 - passes.last.$1 <= 200) {
        if (c.$2 < passes.last.$2) passes.last = c;
      } else {
        passes.add(c);
      }
    }
    return [for (final pass in passes) pass.$1];
  }

  // ---------------------------------------------------------------------
  // Compact encoding for sharing over the network.
  // ---------------------------------------------------------------------

  /// Encodes the route as compact JSON: coordinates are delta-encoded
  /// integers at 1e-5 degree (~1 m) precision.
  Map<String, Object?> toShareJson() {
    final coords = <int>[];
    var pLat = 0, pLon = 0, pEle = 0;
    for (final p in points) {
      final lat = (p.lat * 1e5).round();
      final lon = (p.lon * 1e5).round();
      coords
        ..add(lat - pLat)
        ..add(lon - pLon);
      pLat = lat;
      pLon = lon;
      if (hasElevation) {
        final ele = p.ele!.round();
        coords.add(ele - pEle);
        pEle = ele;
      }
    }
    return {
      'n': name,
      'e': hasElevation,
      'c': coords,
      'w': [
        for (final w in waypoints)
          {
            'n': w.name,
            'la': w.point.lat,
            'lo': w.point.lon,
            if (w.description != null) 'd': w.description,
          },
      ],
    };
  }

  factory TrailRoute.fromShareJson(Map<String, Object?> json) {
    final hasEle = json['e'] == true;
    final coords = (json['c'] as List).cast<num>();
    final stride = hasEle ? 3 : 2;
    if (coords.length % stride != 0 || coords.length < stride * 2) {
      throw const FormatException('Malformed route coordinates');
    }
    final pts = <GeoPoint>[];
    var lat = 0, lon = 0, ele = 0;
    for (var i = 0; i < coords.length; i += stride) {
      lat += coords[i].toInt();
      lon += coords[i + 1].toInt();
      if (hasEle) ele += coords[i + 2].toInt();
      pts.add(GeoPoint(lat / 1e5, lon / 1e5, hasEle ? ele.toDouble() : null));
    }
    final wpts = [
      for (final w in (json['w'] as List? ?? const []).cast<Map>())
        GpxWaypoint(
          w['n'] as String,
          GeoPoint((w['la'] as num).toDouble(), (w['lo'] as num).toDouble()),
          description: w['d'] as String?,
        ),
    ];
    return TrailRoute._exact(json['n'] as String? ?? 'Route', pts, wpts);
  }
}

double _q(double deg) => (deg * 1e5).round() / 1e5;

List<double> _cumulativeDistance(List<GeoPoint> pts) {
  final out = List<double>.filled(pts.length, 0);
  for (var i = 1; i < pts.length; i++) {
    out[i] = out[i - 1] + distanceBetween(pts[i - 1], pts[i]);
  }
  return out;
}

/// Ascent/descent with a hysteresis threshold so GPS elevation noise does not
/// add up to phantom climbing.
(List<double>, List<double>) _cumulativeClimb(
  List<GeoPoint> pts, {
  double threshold = 4,
}) {
  final asc = List<double>.filled(pts.length, 0);
  final desc = List<double>.filled(pts.length, 0);
  double? ref;
  var up = 0.0, down = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final e = pts[i].ele;
    if (e != null) {
      if (ref == null) {
        ref = e;
      } else if (e - ref >= threshold) {
        up += e - ref;
        ref = e;
      } else if (ref - e >= threshold) {
        down += ref - e;
        ref = e;
      }
    }
    asc[i] = up;
    desc[i] = down;
  }
  return (asc, desc);
}

/// If only some points have elevation, fills the gaps from the nearest known
/// value so the route is consistently 3D. If none do, returns [pts] as is.
List<GeoPoint> _fillElevation(List<GeoPoint> pts) {
  final known = pts.where((p) => p.ele != null).length;
  if (known == 0 || known == pts.length) return pts;
  final out = List<GeoPoint>.of(pts);
  double? last;
  for (var i = 0; i < out.length; i++) {
    if (out[i].ele != null) {
      last = out[i].ele;
    } else if (last != null) {
      out[i] = GeoPoint(out[i].lat, out[i].lon, last);
    }
  }
  // Leading gap: fill backwards from the first known value.
  final firstKnown = out.indexWhere((p) => p.ele != null);
  for (var i = 0; i < firstKnown; i++) {
    out[i] = GeoPoint(out[i].lat, out[i].lon, out[firstKnown].ele);
  }
  return out;
}
