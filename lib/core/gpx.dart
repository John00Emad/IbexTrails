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
    required this.waypoints,
  });

  /// Best available name: metadata, then track, then route name.
  final String? name;

  /// All track segments (or, if the file has no track, route points)
  /// joined into one continuous line in file order.
  final List<GeoPoint> track;

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
  String? trackName;
  for (final trk in _children(root, 'trk')) {
    trackName ??= _text(trk, 'name');
    for (final seg in _children(trk, 'trkseg')) {
      for (final pt in _children(seg, 'trkpt')) {
        final p = _point(pt);
        if (p != null) track.add(p);
      }
    }
  }

  String? routeName;
  if (track.isEmpty) {
    for (final rte in _children(root, 'rte')) {
      routeName ??= _text(rte, 'name');
      for (final pt in _children(rte, 'rtept')) {
        final p = _point(pt);
        if (p != null) track.add(p);
      }
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

  return GpxData(
    name: metaName ?? trackName ?? routeName ?? _text(root, 'name'),
    track: _dropDuplicates(track),
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
/// devices log while standing still), keeping the first one.
List<GeoPoint> _dropDuplicates(List<GeoPoint> pts) {
  final out = <GeoPoint>[];
  for (final p in pts) {
    if (out.isNotEmpty && out.last.lat == p.lat && out.last.lon == p.lon) {
      continue;
    }
    out.add(p);
  }
  return out;
}

/// Writes a minimal GPX 1.1 document for a recorded track.
String writeGpx({
  required String name,
  required List<GeoPoint> points,
  List<DateTime>? times,
}) {
  final b = XmlBuilder();
  b.processing('xml', 'version="1.0" encoding="UTF-8"');
  b.element(
    'gpx',
    nest: () {
      b.attribute('version', '1.1');
      b.attribute('creator', 'IbexTrails');
      b.attribute('xmlns', 'http://www.topografix.com/GPX/1/1');
      b.element('metadata', nest: () => b.element('name', nest: name));
      b.element(
        'trk',
        nest: () {
          b.element('name', nest: name);
          b.element(
            'trkseg',
            nest: () {
              for (var i = 0; i < points.length; i++) {
                final p = points[i];
                b.element(
                  'trkpt',
                  nest: () {
                    b.attribute('lat', p.lat.toStringAsFixed(7));
                    b.attribute('lon', p.lon.toStringAsFixed(7));
                    if (p.ele != null) {
                      b.element('ele', nest: p.ele!.toStringAsFixed(1));
                    }
                    if (times != null && i < times.length) {
                      b.element(
                        'time',
                        nest: times[i].toUtc().toIso8601String(),
                      );
                    }
                  },
                );
              }
            },
          );
        },
      );
    },
  );
  return b.buildDocument().toXmlString(pretty: true);
}
