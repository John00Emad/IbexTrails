import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'map_layers.dart';
import 'map_tiles.dart';

/// Loads a bundled asset (`rootBundle` in the app, a fake in tests).
typedef AssetLoader = Future<ByteData> Function(String key);

/// A tiny web server on the phone's loopback address for the 3D map page.
///
/// It serves the bundled page and fetches map tiles on its behalf, through
/// the same cache as the 2D map. So tiles saved for offline use work in both
/// views, the tile servers see the app's own User-Agent, and API keys never
/// reach the web page.
///
/// Only catalog layers are served (it is not an open proxy), and every path
/// starts with a random token, so other apps on the phone can't use it.
class TileProxy {
  TileProxy._(
    this._server,
    this.token,
    this._layers,
    this._client,
    this._cache,
    this._assets,
  );

  /// Starts serving on a free loopback port. [layers] gives the current
  /// layers and keys at request time.
  static Future<TileProxy> start({
    required ResolvedMap Function() layers,
    http.Client? client,
    MapCachingProvider? cache,
    AssetLoader? assets,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rng = math.Random.secure();
    final token = List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final proxy = TileProxy._(
      server,
      token,
      layers,
      client ?? http.Client(),
      cache,
      assets ?? rootBundle.load,
    );
    server.listen(proxy._handle, onError: (_) {});
    return proxy;
  }

  final HttpServer _server;
  final String token;
  final ResolvedMap Function() _layers;
  final http.Client _client;
  final MapCachingProvider? _cache;
  final AssetLoader _assets;
  bool _closed = false;

  /// Tiles being fetched, by upstream URL. The page asks for the same
  /// elevation tile for terrain, hillshade and contours at once.
  final _inFlight = <String, Future<Uint8List>>{};

  static const assetRoot = 'assets/map3d';

  /// Base URL every path hangs off, ending in `/`.
  String get origin => 'http://127.0.0.1:${_server.port}/$token/';

  /// The 3D map page.
  String get pageUrl => '${origin}app/index.html';

  /// Tile URL template for [l], for the map style.
  String tileTemplate(MapLayer l) => '${origin}t/${l.id}/{z}/{x}/{y}';

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    _client.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      if (req.method != 'GET' || seg.isEmpty || seg.first != token) {
        return await _send(res, HttpStatus.forbidden);
      }
      if (seg.length >= 3 && seg[1] == 'app') {
        return await _serveAsset(res, seg.sublist(2));
      }
      if (seg.length == 6 && seg[1] == 't') {
        return await _serveTile(res, seg[2], seg[3], seg[4], seg[5]);
      }
      await _send(res, HttpStatus.notFound);
    } on Object {
      try {
        await _send(res, HttpStatus.internalServerError);
      } on Object {
        // The page went away mid-request.
      }
    }
  }

  Future<void> _serveAsset(HttpResponse res, List<String> path) async {
    if (path.any((p) => p.isEmpty || p == '..' || p.startsWith('.'))) {
      return _send(res, HttpStatus.notFound);
    }
    // Font stacks are requested by name ("Noto Sans Regular").
    final key = '$assetRoot/${path.map(_assetName).join('/')}';
    final ByteData data;
    try {
      data = await _assets(key);
    } on Object {
      return _send(res, HttpStatus.notFound);
    }
    final ext = key.substring(key.lastIndexOf('.') + 1);
    await _send(
      res,
      HttpStatus.ok,
      body: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      type: _types[ext] ?? 'application/octet-stream',
      cache: 'no-cache',
    );
  }

  static String _assetName(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), '-');

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json',
    'pbf': 'application/x-protobuf',
    'png': 'image/png',
  };

  Future<void> _serveTile(
    HttpResponse res,
    String layerId,
    String zs,
    String xs,
    String ys,
  ) async {
    final map = _layers();
    final layer = layerById(layerId);
    final z = int.tryParse(zs), x = int.tryParse(xs), y = int.tryParse(ys);
    if (layer == null ||
        layer.urlTemplate == null ||
        z == null ||
        x == null ||
        y == null ||
        z < 0 ||
        z > 22 ||
        x < 0 ||
        y < 0 ||
        x >= 1 << z ||
        y >= 1 << z) {
      return _send(res, HttpStatus.notFound);
    }
    final key = map.keyFor(layer);
    if (layer.provider.needsKey && key.isEmpty) {
      return _send(res, HttpStatus.forbidden);
    }
    final url = layer.urlFor(z, x, y, key: key);
    final Uint8List bytes;
    try {
      bytes = await (_inFlight[url] ??=
          MapTiles.fetchTile(
            url,
            client: _client,
            cache: _cache,
          ).then((r) => r.bytes).whenComplete(() {
            // Not `=>`: remove() returns this very future, and
            // whenComplete would wait for it.
            _inFlight.remove(url);
          }));
    } on Object {
      // Offline and not cached: the map shows the parent tile instead.
      return _send(res, HttpStatus.notFound);
    }
    await _send(
      res,
      HttpStatus.ok,
      body: bytes,
      type: _sniff(bytes),
      cache: 'max-age=86400',
    );
  }

  /// Tile servers vary; the page only needs the right image type.
  static String _sniff(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
    if (b.length > 11 && b[8] == 0x57 && b[9] == 0x45) return 'image/webp';
    return 'application/octet-stream';
  }

  static Future<void> _send(
    HttpResponse res,
    int status, {
    Uint8List? body,
    String? type,
    String cache = 'no-store',
  }) async {
    res.statusCode = status;
    res.headers
      ..set(HttpHeaders.cacheControlHeader, cache)
      ..set('Access-Control-Allow-Origin', '*');
    if (type != null) res.headers.contentType = ContentType.parse(type);
    if (body != null) {
      res.contentLength = body.length;
      res.add(body);
    }
    await res.close();
  }
}
