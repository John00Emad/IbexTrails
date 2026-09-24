import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../core/route.dart';
import 'settings.dart';

const userAgentPackage = 'com.ibextrails.ibex_trails';

class TileSource {
  const TileSource({
    required this.urlTemplate,
    required this.attribution,
    required this.maxNativeZoom,
    this.subdomains = const [],
  });

  final String urlTemplate;
  final List<String> subdomains;
  final String attribution;
  final int maxNativeZoom;

  /// Same URL the map's tile layer will request, so prefetched tiles are
  /// found in the cache.
  String urlFor(int z, int x, int y) {
    var url = urlTemplate
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    if (subdomains.isNotEmpty) {
      url = url.replaceAll('{s}', subdomains[(x + y) % subdomains.length]);
    }
    return url;
  }
}

TileSource tileSourceFor(MapStyle style) => switch (style) {
  MapStyle.topo => const TileSource(
    urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c'],
    attribution:
        '© OpenStreetMap contributors, SRTM · © OpenTopoMap (CC-BY-SA)',
    maxNativeZoom: 17,
  ),
  MapStyle.osm => const TileSource(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    maxNativeZoom: 19,
  ),
};

class PrefetchProgress {
  const PrefetchProgress(this.done, this.total, this.failed);
  final int done;
  final int total;
  final int failed;
  bool get finished => done + failed >= total;
}

/// Map tile caching so the map keeps working where there is no signal.
///
/// Tiles are cached as they are viewed. [prefetchRoute] also downloads a
/// narrow corridor around a route in advance, at a modest zoom range and at
/// a gentle rate, in line with the tile servers' usage policies.
class MapTiles {
  MapTiles._();

  static MapCachingProvider? _cache;

  static MapCachingProvider get cache =>
      _cache ??= BuiltInMapCachingProvider.getOrCreateInstance(
        maxCacheSize: 600 * 1024 * 1024,
        // Trails rarely change; keep tiles usable offline for a long time.
        overrideFreshAge: const Duration(days: 60),
      );

  static TileLayer layer(MapStyle style) {
    final src = tileSourceFor(style);
    return TileLayer(
      urlTemplate: src.urlTemplate,
      subdomains: src.subdomains,
      maxNativeZoom: src.maxNativeZoom,
      userAgentPackageName: userAgentPackage,
      tileProvider: NetworkTileProvider(
        cachingProvider: cache,
        silenceExceptions: true,
      ),
    );
  }

  /// Tiles covering a corridor of [bufferMeters] either side of the route.
  static Set<(int, int, int)> corridorTiles(
    TrailRoute route, {
    int minZoom = 11,
    int maxZoom = 16,
    double bufferMeters = 250,
  }) {
    final tiles = <(int, int, int)>{};
    final step = math.max(50.0, bufferMeters / 2);
    for (var along = 0.0; along <= route.length + step; along += step) {
      final p = route.pointAt(math.min(along, route.length));
      final dLat = bufferMeters / 111195;
      final dLon = dLat / math.cos(p.lat * math.pi / 180);
      for (var z = minZoom; z <= maxZoom; z++) {
        final (x0, y0) = _tileXY(p.lat + dLat, p.lon - dLon, z);
        final (x1, y1) = _tileXY(p.lat - dLat, p.lon + dLon, z);
        for (var x = x0; x <= x1; x++) {
          for (var y = y0; y <= y1; y++) {
            tiles.add((z, x, y));
          }
        }
      }
    }
    return tiles;
  }

  static (int, int) _tileXY(double lat, double lon, int z) {
    final n = 1 << z;
    final latR = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
    final x = ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
    final y =
        ((1 - math.log(math.tan(latR) + 1 / math.cos(latR)) / math.pi) / 2 * n)
            .floor()
            .clamp(0, n - 1);
    return (x, y);
  }

  /// Downloads the route corridor into the cache. Cancel by cancelling the
  /// stream subscription.
  static Stream<PrefetchProgress> prefetchRoute(
    TrailRoute route,
    MapStyle style, {
    int maxTiles = 2500,
  }) async* {
    final src = tileSourceFor(style);
    final all = corridorTiles(
      route,
      maxZoom: math.min(16, src.maxNativeZoom),
    ).toList()..sort((a, b) => a.$1.compareTo(b.$1));
    final tiles = all.take(maxTiles).toList();
    final client = http.Client();
    var done = 0, failed = 0;
    try {
      yield PrefetchProgress(0, tiles.length, 0);
      for (final (z, x, y) in tiles) {
        final url = src.urlFor(z, x, y);
        try {
          final cached = await cache.getTile(url);
          if (cached == null || cached.metadata.isStale) {
            final res = await client
                .get(
                  Uri.parse(url),
                  headers: {'User-Agent': 'flutter_map ($userAgentPackage)'},
                )
                .timeout(const Duration(seconds: 20));
            if (res.statusCode != 200) {
              throw http.ClientException('HTTP ${res.statusCode}');
            }
            await cache.putTile(
              url: url,
              metadata: CachedMapTileMetadata(
                staleAt: DateTime.timestamp().add(const Duration(days: 60)),
                lastModified: null,
                etag: res.headers['etag'],
              ),
              bytes: res.bodyBytes,
            );
            // Be gentle with volunteer-run tile servers.
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          done++;
        } on Object {
          failed++;
        }
        yield PrefetchProgress(done, tiles.length, failed);
      }
    } finally {
      client.close();
    }
  }
}
