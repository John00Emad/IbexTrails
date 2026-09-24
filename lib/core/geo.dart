import 'dart:math' as math;

/// Mean Earth radius in metres (IUGG).
const double earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

/// A WGS84 coordinate with optional elevation.
class GeoPoint {
  const GeoPoint(this.lat, this.lon, [this.ele]);

  final double lat;
  final double lon;

  /// Elevation in metres, if known.
  final double? ele;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.lat == lat &&
      other.lon == lon &&
      other.ele == ele;

  @override
  int get hashCode => Object.hash(lat, lon, ele);

  @override
  String toString() =>
      'GeoPoint(${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}'
      '${ele == null ? '' : ', ${ele!.toStringAsFixed(1)}'})';
}

/// Great-circle distance between two coordinates in metres.
double haversine(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

double distanceBetween(GeoPoint a, GeoPoint b) =>
    haversine(a.lat, a.lon, b.lat, b.lon);

/// Initial bearing from [a] to [b] in degrees, 0..360 (0 = north).
double bearingBetween(GeoPoint a, GeoPoint b) {
  final phi1 = _rad(a.lat);
  final phi2 = _rad(b.lat);
  final dLon = _rad(b.lon - a.lon);
  final y = math.sin(dLon) * math.cos(phi2);
  final x =
      math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// 16-wind compass name for a bearing, e.g. `NNE`.
String compassName(double bearing) {
  const names = [
    'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
  ];
  final idx = ((bearing % 360) / 22.5 + 0.5).floor() % 16;
  return names[idx];
}

/// Result of projecting a point onto a segment.
class SegmentProjection {
  const SegmentProjection(this.distance, this.t, this.point);

  /// Distance from the query point to the closest point of the segment (m).
  final double distance;

  /// Position of the closest point along the segment, 0..1.
  final double t;

  /// The closest point on the segment.
  final GeoPoint point;
}

/// Projects [p] onto segment [a]-[b] using a local equirectangular
/// approximation centred on [p]. Accurate to well under a metre for the
/// segment lengths found in GPS tracks.
SegmentProjection projectOntoSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
  final cosLat = math.cos(_rad(p.lat));
  final ax = _rad(a.lon - p.lon) * cosLat * earthRadiusM;
  final ay = _rad(a.lat - p.lat) * earthRadiusM;
  final bx = _rad(b.lon - p.lon) * cosLat * earthRadiusM;
  final by = _rad(b.lat - p.lat) * earthRadiusM;
  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx;
  final cy = ay + t * dy;
  final dist = math.sqrt(cx * cx + cy * cy);
  final ele = (a.ele != null && b.ele != null)
      ? a.ele! + (b.ele! - a.ele!) * t
      : (a.ele ?? b.ele);
  return SegmentProjection(
    dist,
    t,
    GeoPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t, ele),
  );
}

/// Simplifies a polyline with the Douglas-Peucker algorithm.
///
/// [tolerance] is the horizontal tolerance in metres. If
/// [verticalTolerance] is given, points whose elevation deviates from the
/// simplified line by more than that are kept too, so climbs survive on
/// straight sections. The first and last points are always kept.
List<GeoPoint> simplifyPolyline(
  List<GeoPoint> points,
  double tolerance, {
  double? verticalTolerance,
}) {
  if (points.length < 3) return List.of(points);
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  // Iterative to avoid deep recursion on long tracks.
  final stack = <(int, int)>[(0, points.length - 1)];
  while (stack.isNotEmpty) {
    final (first, last) = stack.removeLast();
    var maxScore = 0.0;
    var index = -1;
    for (var i = first + 1; i < last; i++) {
      final proj = projectOntoSegment(points[i], points[first], points[last]);
      var score = proj.distance / tolerance;
      final ele = points[i].ele;
      if (verticalTolerance != null && ele != null && proj.point.ele != null) {
        score = math.max(
          score,
          (ele - proj.point.ele!).abs() / verticalTolerance,
        );
      }
      if (score > maxScore) {
        maxScore = score;
        index = i;
      }
    }
    if (index != -1 && maxScore > 1) {
      keep[index] = true;
      stack
        ..add((first, index))
        ..add((index, last));
    }
  }
  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

/// Formats a distance for display: `850 m`, `4.25 km`, `12.3 km`.
String formatDistance(double metres) {
  if (metres.isNaN || metres.isInfinite) return '–';
  final m = metres.abs();
  if (m < 1000) return '${metres.round()} m';
  if (m < 10000) return '${(metres / 1000).toStringAsFixed(2)} km';
  return '${(metres / 1000).toStringAsFixed(1)} km';
}

/// Formats a duration as `h:mm:ss` or `m:ss`.
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '${d.inMinutes}:$s';
}

/// Formats how long ago [time] was relative to [now]: `12 s`, `4 min`, `2 h`.
String formatAgo(DateTime time, DateTime now) {
  final d = now.difference(time);
  if (d.inSeconds < 60) return '${math.max(0, d.inSeconds)} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  return '${d.inHours} h';
}
