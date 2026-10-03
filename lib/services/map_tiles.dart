import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../core/route.dart';
import 'map_layers.dart';

const userAgentPackage = 'com.ibextrails.ibex_trails';

class PrefetchProgress {
  const PrefetchProgress(
    this.done,
    this.total,
    this.failed, {
    this.skipped = const [],
  });
  final int done;
  final int total;
  final int failed;

  /// Layers left out because their terms don't allow downloading ahead.
  final List<String> skipped;
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

  static TileLayer layer(MapLayer l, {double opacity = 1, String key = ''}) =>
      TileLayer(
        urlTemplate: l.urlTemplate,
        subdomains: l.subdomains,
        additionalOptions: {'key': key},
        maxNativeZoom: l.maxNativeZoom,
        userAgentPackageName: userAgentPackage,
        tileDisplay: opacity < 1
            ? TileDisplay.instantaneous(opacity: opacity)
            : const TileDisplay.fadeIn(),
        tileProvider: NetworkTileProvider(
          cachingProvider: cache,
          silenceExceptions: true,
        ),
      );

  static const _userAgent = 'flutter_map ($userAgentPackage)';

  /// Tile bytes for [url] from the cache, downloading them when missing or
  /// stale. A stale tile is still returned when there is no signal.
  /// `fetched` tells whether the network was used.
  static Future<({Uint8List bytes, bool fetched})> fetchTile(
    String url, {
    required http.Client client,
    MapCachingProvider? cache,
  }) async {
    final store = cache ?? MapTiles.cache;
    CachedMapTile? cached;
    try {
      cached = await store.getTile(url);
    } on Object {
      cached = null;
    }
    if (cached != null && !cached.metadata.isStale) {
      return (bytes: cached.bytes, fetched: false);
    }
    final http.Response res;
    try {
      res = await client
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw http.ClientException('HTTP ${res.statusCode}', Uri.parse(url));
      }
    } on Object {
      if (cached != null) return (bytes: cached.bytes, fetched: false);
      rethrow;
    }
    try {
      await store.putTile(
        url: url,
        metadata: CachedMapTileMetadata(
          staleAt: DateTime.timestamp().add(const Duration(days: 60)),
          lastModified: null,
          etag: res.headers['etag'],
        ),
        bytes: res.bodyBytes,
      );
    } on Object {
      // Still worth showing; it is cached next time round.
    }
    return (bytes: res.bodyBytes, fetched: true);
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

  /// Zoom levels downloaded for [l] along a route: enough detail to run
  /// with, without hammering the servers. Elevation needs less, since the
  /// terrain, hillshade and contours are smoothed from it anyway.
  static (int, int) prefetchZooms(MapLayer l) => l.kind == LayerKind.elevation
      ? (8, math.min(12, l.maxNativeZoom))
      : (11, math.min(16, l.maxNativeZoom));

  /// Downloads the route corridor of every layer the map shows into the
  /// cache. Layers whose terms don't allow it are skipped (and listed in
  /// the progress). Cancel by cancelling the stream subscription.
  static Stream<PrefetchProgress> prefetchRoute(
    TrailRoute route,
    ResolvedMap map, {
    required bool in3d,
    int maxTiles = 2500,
    http.Client? client,
    MapCachingProvider? cache,
  }) async* {
    final layers = map.fetched(in3d: in3d);
    final skipped = [
      for (final l in layers)
        if (!l.allowsBulkDownload) l.name,
    ];
    final all = <(int, int, int, MapLayer)>[];
    for (final l in layers.where((l) => l.allowsBulkDownload)) {
      final (minZoom, maxZoom) = prefetchZooms(l);
      for (final (z, x, y) in corridorTiles(
        route,
        minZoom: minZoom,
        maxZoom: maxZoom,
      )) {
        all.add((z, x, y, l));
      }
    }
    // Coarse zooms first, so a cut-off download is still useful.
    all.sort((a, b) => a.$1.compareTo(b.$1));
    final tiles = all.take(maxTiles).toList();
    final httpClient = client ?? http.Client();
    var done = 0, failed = 0;
    try {
      yield PrefetchProgress(0, tiles.length, 0, skipped: skipped);
      for (final (z, x, y, l) in tiles) {
        try {
          final r = await fetchTile(
            l.urlFor(z, x, y, key: map.keyFor(l)),
            client: httpClient,
            cache: cache,
          );
          // Be gentle with volunteer-run tile servers.
          if (r.fetched) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          done++;
        } on Object {
          failed++;
        }
        yield PrefetchProgress(done, tiles.length, failed, skipped: skipped);
      }
    } finally {
      if (client == null) httpClient.close();
    }
  }
}
