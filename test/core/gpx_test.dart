import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/gpx.dart';

const _gpx11 = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Test" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
  <metadata><name>Wadi Loop</name></metadata>
  <wpt lat="30.001" lon="31.001"><name>Water</name><desc>Spring</desc></wpt>
  <wpt lat="30.002" lon="31.002"></wpt>
  <trk>
    <name>Track name</name>
    <trkseg>
      <trkpt lat="30.0" lon="31.0"><ele>100</ele><time>2026-01-01T06:00:00Z</time></trkpt>
      <trkpt lat="30.0" lon="31.0"><ele>100</ele></trkpt>
      <trkpt lat="30.001" lon="31.0"><ele>110</ele>
        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>140</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
      </trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="30.002" lon="31.0"><ele>120</ele></trkpt>
    </trkseg>
  </trk>
</gpx>''';

const _gpx10Route = '''<gpx version="1.0">
  <rte><name>Planned</name>
    <rtept lat="10" lon="20"/>
    <rtept lat="10.01" lon="20"/>
    <rtept lat="bad" lon="20"/>
  </rte>
</gpx>''';

void main() {
  test('parses GPX 1.1 tracks, segments, waypoints and metadata', () {
    final gpx = parseGpx(_gpx11);
    expect(gpx.name, 'Wadi Loop');
    // Duplicate consecutive point dropped, segments joined.
    expect(gpx.track, [
      const GeoPoint(30.0, 31.0, 100),
      const GeoPoint(30.001, 31.0, 110),
      const GeoPoint(30.002, 31.0, 120),
    ]);
    expect(gpx.waypoints.map((w) => w.name), ['Water', 'Waypoint 1']);
    expect(gpx.waypoints.first.description, 'Spring');
  });

  test('falls back to route points when there is no track', () {
    final gpx = parseGpx(_gpx10Route);
    expect(gpx.name, 'Planned');
    expect(gpx.track.length, 2);
    expect(gpx.track.first.ele, isNull);
  });

  test('rejects non-GPX and empty files', () {
    expect(() => parseGpx('not xml'), throwsA(isA<GpxFormatException>()));
    expect(() => parseGpx('<kml></kml>'), throwsA(isA<GpxFormatException>()));
    expect(
      () => parseGpx('<gpx><trk><trkseg/></trk></gpx>'),
      throwsA(isA<GpxFormatException>()),
    );
  });

  test('writeGpx output parses back', () {
    final xml = writeGpx(
      name: 'Recorded',
      points: const [GeoPoint(1, 2, 3), GeoPoint(1.001, 2, 4)],
      times: [DateTime.utc(2026), DateTime.utc(2026, 1, 1, 0, 0, 5)],
    );
    final gpx = parseGpx(xml);
    expect(gpx.name, 'Recorded');
    expect(gpx.track, const [GeoPoint(1, 2, 3), GeoPoint(1.001, 2, 4)]);
    expect(gpx.times, [DateTime.utc(2026), DateTime.utc(2026, 1, 1, 0, 0, 5)]);
  });

  test('keeps each point\'s time, dropping it with a duplicate point', () {
    expect(parseGpx(_gpx11).times, [DateTime.utc(2026, 1, 1, 6), null, null]);
    expect(parseGpx(_gpx10Route).times, [null, null]);
  });

  const pts = [
    GeoPoint(30, 31, 100),
    GeoPoint(30.001, 31, 104.5),
    GeoPoint(30.002, 31.001),
  ];
  final times = [
    DateTime.utc(2026, 10, 3, 6),
    DateTime.utc(2026, 10, 3, 6, 0, 4),
    DateTime.utc(2026, 10, 3, 6, 0, 9),
  ];

  test('a recording written piece by piece is the same as writeGpx', () {
    const name = 'Wadi & <Hof>';
    final pieces =
        gpxHeader(name, time: times.first) +
        gpxTrackPoints(pts.sublist(0, 2), times.sublist(0, 2)) +
        gpxTrackPoints(pts.sublist(2), times.sublist(2)) +
        gpxFooter;
    expect(pieces, writeGpx(name: name, points: pts, times: times));
    final gpx = parseGpx(pieces);
    expect(gpx.name, name);
    expect(gpx.track, pts);
    expect(gpx.times, times);
  });

  test('a file cut off mid-write is mended up to its last whole point', () {
    final full = writeGpx(name: 'Cut', points: pts, times: times);
    final cut = full.substring(0, full.lastIndexOf('<trkpt') + 20);
    expect(() => parseGpx(cut), throwsA(isA<GpxFormatException>()));
    final gpx = parseGpx(repairGpx(cut)!);
    expect(gpx.name, 'Cut');
    expect(gpx.track, pts.sublist(0, 2));
    expect(repairGpx('<gpx><metadata><name>No track'), isNull);
  });
}
