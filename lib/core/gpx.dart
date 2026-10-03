import 'package:xml/xml.dart';

import 'geo.dart';

/// A named point of interest from a GPX file (`<wpt>`).
class GpxWaypoint {
  const GpxWaypoint(this.name, this.point, {this.description});

  final String name;
  final GeoPoint point;
  final String? description;
}

/// The parts of a GPX document IbexTrails cares about.
class GpxData {
  const GpxData({
    required this.name,
    required this.track,
    required this.times,
    required this.waypoints,
  });

  /// Best available name: metadata, then track, then route name.
  final String? name;

  /// All track segments (or, if the file has no track, route points)
  /// joined into one continuous line in file order.
  final List<GeoPoint> track;

  /// When each [track] point was recorded, null where the file doesn't say.
  final List<DateTime?> times;

  final List<GpxWaypoint> waypoints;
}

class GpxFormatException implements Exception {
  GpxFormatException(this.message);
  final String message;
  @override
  String toString() => 'GpxFormatException: $message';
}

/// Parses GPX 1.0 / 1.1 text.
///
/// Elements are matched by local name so files with or without the GPX
/// namespace, and with vendor extensions (Garmin, Strava, Komoot...), work.
GpxData parseGpx(String source) {
  if (source.startsWith('\uFEFF')) source = source.substring(1); // BOM
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(source);
  } on XmlException catch (e) {
    throw GpxFormatException('Not a valid XML/GPX file (${e.message})');
  }
  final root = doc.rootElement;
  if (root.localName != 'gpx') {
    throw GpxFormatException('Root element is <${root.localName}>, not <gpx>');
  }

  final track = <GeoPoint>[];
  final times = <DateTime?>[];
  void add(XmlElement pt) {
    final p = _point(pt);
    if (p == null) return;
    track.add(p);
    times.add(DateTime.tryParse(_text(pt, 'time') ?? ''));
  }

  String? trackName;
  for (final trk in _children(root, 'trk')) {
    trackName ??= _text(trk, 'name');
    for (final seg in _children(trk, 'trkseg')) {
      _children(seg, 'trkpt').forEach(add);
    }
  }

  String? routeName;
  if (track.isEmpty) {
    for (final rte in _children(root, 'rte')) {
      routeName ??= _text(rte, 'name');
      _children(rte, 'rtept').forEach(add);
    }
  }

  final waypoints = <GpxWaypoint>[];
  var unnamed = 0;
  for (final wpt in _children(root, 'wpt')) {
    final p = _point(wpt);
    if (p == null) continue;
    final name = _text(wpt, 'name') ?? 'Waypoint ${++unnamed}';
    waypoints.add(
      GpxWaypoint(
        name,
        p,
        description: _text(wpt, 'desc') ?? _text(wpt, 'cmt'),
      ),
    );
  }

  final metadata = _children(root, 'metadata').firstOrNull;
  final metaName = metadata == null ? null : _text(metadata, 'name');

  if (track.length < 2) {
    throw GpxFormatException(
      'The file has no track or route with at least two points',
    );
  }

  final (points, pointTimes) = _dropDuplicates(track, times);
  return GpxData(
    name: metaName ?? trackName ?? routeName ?? _text(root, 'name'),
    track: points,
    times: pointTimes,
    waypoints: waypoints,
  );
}

Iterable<XmlElement> _children(XmlElement parent, String localName) =>
    parent.childElements.where((e) => e.localName == localName);

String? _text(XmlElement parent, String localName) {
  final value = _children(parent, localName).firstOrNull?.innerText.trim();
  return (value == null || value.isEmpty) ? null : value;
}

GeoPoint? _point(XmlElement e) {
  final lat = double.tryParse(e.getAttribute('lat') ?? '');
  final lon = double.tryParse(e.getAttribute('lon') ?? '');
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  final ele = double.tryParse(_text(e, 'ele') ?? '');
  return GeoPoint(lat, lon, ele);
}

/// Removes consecutive points at the exact same position (common when
/// devices log while standing still), keeping the first one and its time.
(List<GeoPoint>, List<DateTime?>) _dropDuplicates(
  List<GeoPoint> pts,
  List<DateTime?> times,
) {
  final out = <GeoPoint>[];
  final outTimes = <DateTime?>[];
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i];
    if (out.isNotEmpty && out.last.lat == p.lat && out.last.lon == p.lon) {
      continue;
    }
    out.add(p);
    outTimes.add(times[i]);
  }
  return (out, outTimes);
}

// A recorded track is written as gpxHeader + gpxTrackPoints + gpxFooter.
// Keeping the pieces separate lets a recording grow on disk: new points go
// in just before the footer, and the file is a whole GPX document after
// every write.

/// Start of a GPX 1.1 document with one track, up to its open `<trkseg>`.
String gpxHeader(String name, {DateTime? time}) {
  final n = _escape(name);
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="IbexTrails" '
      'xmlns="http://www.topografix.com/GPX/1/1">\n'
      '  <metadata>\n'
      '    <name>$n</name>\n'
      '${time == null ? '' : '    <time>${_utc(time)}</time>\n'}'
      '  </metadata>\n'
      '  <trk>\n'
      '    <name>$n</name>\n'
      '    <trkseg>\n';
}

/// One `<trkpt>` line per point, with its time when [times] has one.
String gpxTrackPoints(List<GeoPoint> points, [List<DateTime?>? times]) {
  final b = StringBuffer();
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final t = times != null && i < times.length ? times[i] : null;
    b
      ..write('      <trkpt lat="${p.lat.toStringAsFixed(7)}" ')
      ..write('lon="${p.lon.toStringAsFixed(7)}">')
      ..write(p.ele == null ? '' : '<ele>${p.ele!.toStringAsFixed(1)}</ele>')
      ..write(t == null ? '' : '<time>${_utc(t)}</time>')
      ..write('</trkpt>\n');
  }
  return b.toString();
}

/// Closes a document started by [gpxHeader].
const gpxFooter = '    </trkseg>\n  </trk>\n</gpx>\n';

/// Writes a minimal GPX 1.1 document for a recorded track.
String writeGpx({
  required String name,
  required List<GeoPoint> points,
  List<DateTime?>? times,
}) {
  final start = times?.nonNulls.firstOrNull;
  return gpxHeader(name, time: start) +
      gpxTrackPoints(points, times) +
      gpxFooter;
}

/// Closes a GPX file that was cut off while being written (the app was
/// killed mid-write), keeping every complete track point. Returns null if
/// [source] has no track to keep.
String? repairGpx(String source) {
  const point = '</trkpt>';
  const segment = '<trkseg>';
  final lastPoint = source.lastIndexOf(point);
  final firstSegment = source.indexOf(segment);
  final cut = lastPoint >= 0
      ? lastPoint + point.length
      : firstSegment >= 0
      ? firstSegment + segment.length
      : -1;
  if (cut < 0) return null;
  return '${source.substring(0, cut)}\n$gpxFooter';
}

String _utc(DateTime t) => t.toUtc().toIso8601String();

/// Escapes text for an XML element, dropping control characters XML 1.0
/// doesn't allow.
String _escape(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
