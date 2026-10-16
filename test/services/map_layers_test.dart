import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/services/map_layers.dart';
import 'package:ibex_trails/services/map_tiles.dart';

import '../fake_tile_cache.dart';
import '../helpers.dart';

String noKey(MapProvider p) => '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The 2D map's tile cache lives in the app's cache directory.
  final tmp = Directory.systemTemp.createTempSync('ibex_tiles');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tmp.path,
      );

  test('catalog is consistent', () {
    final ids = mapLayers.map((l) => l.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'unique ids');
    for (final l in mapLayers) {
      if (l.urlTemplate case final url?) {
        expect(url, allOf(contains('{z}'), contains('{x}'), contains('{y}')));
        expect(url.contains('{key}'), l.provider.needsKey, reason: l.id);
        expect(url, startsWith('https://'));
      }
      if (l.kind == LayerKind.elevation) {
        expect(l.demEncoding, anyOf('terrarium', 'mapbox'), reason: l.id);
      }
      if (l.kind != LayerKind.overlay) {
        expect(l.urlTemplate, isNotNull, reason: l.id);
        expect(l.attribution, isNotEmpty, reason: l.id);
      }
    }
    // The free stack is complete on its own.
    const d = MapSetup();
    expect(layerById(d.baseId)!.provider, MapProvider.free);
    expect(layerById(d.elevationId)!.provider, MapProvider.free);
    for (final p in mapPresets) {
      expect(layerById(p.setup.baseId)!.provider, MapProvider.free);
      for (final id in p.setup.overlays.keys) {
        expect(layerById(id)!.provider, MapProvider.free);
      }
    }
  });

  test('tile URLs: subdomains, Esri y/x order and keys', () {
    expect(
      layerById('otm')!.urlFor(10, 1, 1),
      'https://c.tile.opentopomap.org/10/1/1.png',
    );
    expect(
      layerById('esri_sat')!.urlFor(12, 2404, 1714),
      endsWith('/World_Imagery/MapServer/tile/12/1714/2404'),
    );
    expect(
      layerById('mt_satellite')!.urlFor(3, 4, 5, key: 'abc'),
      'https://api.maptiler.com/maps/satellite/256/3/4/5.jpg?key=abc',
    );
  });

  test('prefetch and proxy URLs match what the 2D map requests', () {
    // The offline cache is keyed by URL, so these must agree exactly.
    for (final l in mapLayers.where((l) => l.has2d)) {
      final layer = MapTiles.layer(l, key: 'k3y');
      for (final (z, x, y) in [(10, 600, 427), (14, 9612, 6857)]) {
        expect(
          layer.tileProvider.getTileUrl(TileCoordinates(x, y, z), layer),
          l.urlFor(z, x, y, key: 'k3y'),
          reason: l.id,
        );
      }
    }
  });

  group('ResolvedMap', () {
    test('a keyed layer without a key falls back to free ones', () {
      const setup = MapSetup(
        baseId: 'mt_satellite',
        elevationId: 'mb_terrain',
        overlays: {'hillshade': 0.4},
      );
      final noKeys = ResolvedMap.of(setup, noKey);
      expect(noKeys.base.id, 'otm');
      expect(noKeys.elevation.id, 'aws_terrain');

      final withKeys = ResolvedMap.of(
        setup,
        (p) => p == MapProvider.maptiler ? 'mt' : '',
      );
      expect(withKeys.base.id, 'mt_satellite');
      expect(withKeys.keyFor(withKeys.base), 'mt');
      expect(withKeys.elevation.id, 'aws_terrain', reason: 'no Mapbox key');
    });

    test('2D and 3D layers', () {
      final map = ResolvedMap.of(
        const MapSetup(
          baseId: 'esri_sat',
          overlays: {'labels': 1, 'contours': 0.8, 'hillshade': 0.4},
        ),
        noKey,
      );
      // Catalog order, whatever order they were switched on in.
      expect(map.overlays.map((o) => o.$1.id), [
        'hillshade',
        'contours',
        'labels',
      ]);
      expect(map.layers2d.map((o) => o.$1.id), [
        'esri_sat',
        'hillshade',
        'labels',
      ]);
      expect(map.fetched(in3d: false).map((l) => l.id), [
        'esri_sat',
        'hillshade',
        'labels',
      ]);
      // In 3D, hillshade and contours are computed from the elevation.
      expect(map.fetched(in3d: true).map((l) => l.id), [
        'esri_sat',
        'labels',
        'aws_terrain',
      ]);
      expect(map.attribution(in3d: false), contains('Hillshade © Esri'));
      expect(map.attribution(in3d: true), isNot(contains('Hillshade')));
      expect(map.attribution(in3d: true), contains('Terrain Tiles'));
    });
  });

  test('MapSetup JSON round-trips and ignores junk', () {
    const setup = MapSetup(
      baseId: 's2_2016',
      overlays: {'trails': 0.5, 'contours': 1},
      terrain3d: true,
      exaggeration: 1.6,
    );
    expect(MapSetup.fromJson(setup.toJson()), setup);
    final junk = MapSetup.fromJson({
      'base': 'hillshade', // not a base map
      'overlays': {'nope': 1, 'labels': 7, 'trails': 'x'},
      'elevation': 'otm',
      'exaggeration': 9,
    });
    expect(junk.baseId, 'otm');
    expect(junk.overlays, {'labels': 1.0});
    expect(junk.elevationId, 'aws_terrain');
    expect(junk.exaggeration, 2);
    expect(junk.terrain3d, isFalse);
  });

  group('offline download', () {
    final route = TrailRoute.fromPoints('Wadi', eastLine(1000));

    test('elevation needs fewer zoom levels', () {
      expect(MapTiles.prefetchZooms(layerById('aws_terrain')!), (8, 12));
      expect(MapTiles.prefetchZooms(layerById('otm')!), (11, 16));
      expect(MapTiles.prefetchZooms(layerById('s2_2016')!), (11, 15));
    });

    test(
      'skips layers whose terms forbid it, includes elevation in 3D',
      () async {
        final requested = <String>[];
        final client = MockClient((req) async {
          requested.add(req.url.toString());
          return http.Response.bytes([1, 2, 3], 200);
        });
        final map = ResolvedMap.of(
          const MapSetup(baseId: 'esri_sat', overlays: {'trails': 0.8}),
          noKey,
        );
        final cache = FakeCache();
        final progress = await MapTiles.prefetchRoute(
          route,
          map,
          in3d: true,
          maxTiles: 6,
          client: client,
          cache: cache,
        ).toList();

        final last = progress.last;
        expect(last.skipped, ['Satellite (Esri)', 'Hiking trails']);
        expect(last.total, inInclusiveRange(1, 6));
        expect(last.done, last.total);
        expect(last.finished, isTrue);
        // Only the elevation is left, from zoom 8.
        expect(requested, hasLength(last.total));
        expect(requested, everyElement(contains('elevation-tiles-prod')));
        expect(requested.first, contains('/terrarium/8/'));
        expect(cache.tiles.keys, unorderedEquals(requested));

        // Already cached: nothing is downloaded again.
        requested.clear();
        await MapTiles.prefetchRoute(
          route,
          map,
          in3d: true,
          maxTiles: 6,
          client: client,
          cache: cache,
        ).drain<void>();
        expect(requested, isEmpty);
      },
    );

    test('2D downloads the base map only when it may', () async {
      final requested = <String>[];
      final client = MockClient((req) async {
        requested.add(req.url.toString());
        return http.Response.bytes([1], 200);
      });
      final progress = await MapTiles.prefetchRoute(
        route,
        ResolvedMap.of(const MapSetup(overlays: {'contours': 1}), noKey),
        in3d: false,
        maxTiles: 3,
        client: client,
        cache: FakeCache(),
      ).toList();
      expect(progress.last.skipped, isEmpty);
      expect(requested, hasLength(3));
      expect(requested, everyElement(contains('.tile.opentopomap.org/')));
      // Coarsest first, starting at zoom 11.
      expect(requested.first, contains('opentopomap.org/11/'));
    });
  });
}
