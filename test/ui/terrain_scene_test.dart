import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/core/course.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/map_layers.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/state/run_session.dart';
import 'package:ibex_trails/ui/terrain_scene.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

Position _fix(GeoPoint p, {double speed = 3, double heading = 90}) => Position(
  latitude: p.lat,
  longitude: p.lon,
  timestamp: DateTime.now(),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 5,
  heading: heading,
  headingAccuracy: 10,
  speed: speed,
  speedAccuracy: 1,
);

/// East 1 km, then sharp back to the north-west (135° left).
TrailRoute _hairpin() => TrailRoute.fromPoints('Hairpin', [
  ...eastLine(1000),
  for (var d = 50.0; d <= 1000; d += 50)
    offset(d * math.sqrt1_2, 1000 - d * math.sqrt1_2),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'layers: tiles come from the proxy; hillshade and contours from DEM',
    () {
      final map = ResolvedMap.of(
        const MapSetup(
          baseId: 'esri_sat',
          overlays: {'hillshade': 0.4, 'contours': 0.8, 'labels': 1},
          terrain3d: true,
          exaggeration: 1.5,
        ),
        (_) => '',
      );
      final cfg = TerrainScene.layers(map, (l) => 'http://proxy/t/${l.id}');
      expect(cfg['base'], {
        'id': 'esri_sat',
        'tiles': 'http://proxy/t/esri_sat',
        'maxzoom': 18,
      });
      expect(cfg['overlays'], [
        {'id': 'hillshade', 'render': 'hillshade', 'opacity': 0.4},
        {'id': 'contours', 'render': 'contours', 'opacity': 0.8},
        {
          'id': 'labels',
          'render': 'raster',
          'opacity': 1.0,
          'tiles': 'http://proxy/t/labels',
          'maxzoom': 19,
        },
      ]);
      expect(cfg['dem'], {
        'id': 'aws_terrain',
        'tiles': 'http://proxy/t/aws_terrain',
        'maxzoom': 12,
        'encoding': 'terrarium',
      });
      expect(cfg['exaggeration'], 1.5);
      // It goes to the page as JSON.
      expect(() => jsonEncode(cfg), returnsNormally);
    },
  );

  test('route: line, start/finish and only the turns easy to miss', () {
    final route = _hairpin();
    final course = Course.fromRoute(route, id: 'c');
    final r = TerrainScene.route(route, course)!;
    expect(r['coords'], hasLength(route.points.length));
    expect(
      (r['coords'] as List).first,
      [
        route.start.lon,
        route.start.lat,
      ].map((v) => (v * 1e6).round() / 1e6).toList(),
    );
    expect(r['finish'], isNotNull);
    final turn = (r['turns'] as List).single as Map;
    expect(turn['uTurn'], isFalse);
    expect(turn['right'], isFalse);
    expect(turn['label'], 'Sharp left');
    expect(turn['lon'], closeTo(offset(0, 1000).lon, 2e-4));
    expect(TerrainScene.route(null, null), isNull);
  });

  test('colors are CSS hex', () {
    expect(TerrainScene.hex(const Color(0xFF1C6DD0)), '#1c6dd0');
    expect(TerrainScene.hex(const Color(0x80000102)), '#000102');
  });

  test('accuracy circle is a closed ring of the right size', () {
    final ring = TerrainScene.circle(30, 31, 100);
    expect(ring.first, ring.last);
    for (final p in ring) {
      final d = distanceBetween(GeoPoint(30, 31), GeoPoint(p[1], p[0]));
      expect(d, closeTo(100, 1));
    }
  });

  testWidgets('live: progress cut, you, and only new track points', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final settings = (await tester.runAsync(AppSettings.load))!;
    final gps = StreamController<Position>();
    final route = _hairpin();
    final session = (await tester.runAsync(
      () => RunSession.solo(
        settings,
        Notifier(),
        route: route,
        locationSource: () => gps.stream,
      ),
    ))!;
    addTearDown(() {
      session.dispose();
      gps.close();
    });

    Future<void> runTo(
      double east, {
      double speed = 3,
      double south = 0,
    }) async {
      gps.add(_fix(offset(-south, east), speed: speed));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }

    for (var e = 0.0; e <= 300; e += 25) {
      await runTo(e);
    }
    final now = DateTime.now();
    var live = TerrainScene.live(session, now: now, recordedFrom: 0);
    expect(jsonDecode(jsonEncode(live)), isA<Map<String, Object?>>());

    final cut = live['cut']! as Map;
    expect(cut['i'], route.segmentIndexAt(session.match!.along));
    expect(cut['lon'], closeTo(offset(0, 300).lon, 1e-4));

    final me = live['me']! as Map;
    expect(me['heading'], 90.0);
    expect(live['accuracy'], isNotNull);
    expect(live['offRoute'], isNull);
    expect(live['people'], isEmpty);

    final recorded = session.recorded.length;
    expect(recorded, greaterThan(5));
    expect(live['recordedFrom'], 0);
    expect(live['recorded'], hasLength(recorded));

    // Next update: only what's new. Standing still: no heading arrow.
    await runTo(350, speed: 0.2);
    live = TerrainScene.live(session, now: now, recordedFrom: recorded);
    expect(live['recordedFrom'], recorded);
    expect(live['recorded'], hasLength(session.recorded.length - recorded));
    expect((live['me']! as Map)['heading'], isNull);

    // Further than the track (a new session): everything again.
    live = TerrainScene.live(session, now: now, recordedFrom: 99999);
    expect(live['recordedFrom'], 0);
    expect(live['recorded'], hasLength(session.recorded.length));

    // Far from the trail for a few fixes: a guide line back to it.
    for (var i = 0; i < 4; i++) {
      await runTo(300 + i * 10, south: 150);
    }
    expect(session.match!.offRoute, isTrue);
    live = TerrainScene.live(session, now: now, recordedFrom: 0);
    final guide = live['offRoute']! as List;
    expect(guide, hasLength(2));
    expect((guide.last as List)[1], closeTo(originLat, 1e-4));
  });
}
