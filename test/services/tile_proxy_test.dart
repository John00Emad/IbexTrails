import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ibex_trails/services/map_layers.dart';
import 'package:ibex_trails/services/tile_proxy.dart';

import '../fake_tile_cache.dart';

final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

void main() {
  // No test binding here: it would replace real HTTP with fakes.
  late TileProxy proxy;
  late FakeCache cache;
  late List<String> upstream;
  var online = true;
  Future<void>? slow;
  var map = ResolvedMap.of(const MapSetup(), (_) => '');
  final assets = {
    'assets/map3d/index.html': utf8.encode('<html>3D</html>'),
    'assets/map3d/glyphs/noto-sans-regular/0-255.pbf': [1, 2, 3],
  };

  Future<HttpClientResponse> get(String url) async {
    final client = HttpClient();
    try {
      return await (await client.getUrl(Uri.parse(url))).close();
    } finally {
      client.close();
    }
  }

  Future<List<int>> body(HttpClientResponse r) =>
      r.fold<List<int>>([], (a, b) => a..addAll(b));

  setUp(() async {
    cache = FakeCache();
    upstream = [];
    online = true;
    slow = null;
    map = ResolvedMap.of(const MapSetup(), (_) => '');
    proxy = await TileProxy.start(
      layers: () => map,
      cache: cache,
      client: MockClient((req) async {
        upstream.add(req.url.toString());
        await slow;
        if (!online) throw const SocketException('no signal');
        expect(req.headers['User-Agent'], contains('com.ibextrails'));
        return http.Response.bytes(_png, 200);
      }),
      assets: (key) async {
        final bytes = assets[key];
        if (bytes == null) throw StateError('no asset $key');
        return ByteData.sublistView(Uint8List.fromList(bytes));
      },
    );
  });

  tearDown(() => proxy.close());

  test('listens on loopback only, behind a random token', () async {
    expect(proxy.origin, startsWith('http://127.0.0.1:'));
    expect(proxy.token, hasLength(32));
    final port = Uri.parse(proxy.origin).port;
    final wrong = await get('http://127.0.0.1:$port/nottoken/app/index.html');
    expect(wrong.statusCode, HttpStatus.forbidden);
    await wrong.drain<void>();
  });

  test('serves the bundled page and fonts', () async {
    final page = await get(proxy.pageUrl);
    expect(page.statusCode, 200);
    expect(page.headers.contentType?.mimeType, 'text/html');
    expect(utf8.decode(await body(page)), '<html>3D</html>');

    // Font stacks are requested by their name.
    final glyphs = await get(
      '${proxy.origin}app/glyphs/Noto%20Sans%20Regular/0-255.pbf',
    );
    expect(glyphs.statusCode, 200);
    expect(await body(glyphs), [1, 2, 3]);

    final missing = await get('${proxy.origin}app/nope.js');
    expect(missing.statusCode, 404);
    await missing.drain<void>();

    final escape = await get('${proxy.origin}app/%2E%2E/secret');
    expect(escape.statusCode, 404);
    await escape.drain<void>();
  });

  test('fetches tiles once, then serves them from the cache offline', () async {
    final url = proxy.tileTemplate(layerById('otm')!);
    final tile = url
        .replaceAll('{z}', '12')
        .replaceAll('{x}', '2404')
        .replaceAll('{y}', '1714');

    final first = await get(tile);
    expect(first.statusCode, 200);
    expect(first.headers.contentType?.mimeType, 'image/png');
    expect(first.headers.value('access-control-allow-origin'), '*');
    expect(await body(first), _png);
    expect(upstream, [layerById('otm')!.urlFor(12, 2404, 1714)]);
    expect(cache.tiles.keys, upstream, reason: 'same key as the 2D map');

    online = false;
    final again = await get(tile);
    expect(again.statusCode, 200);
    expect(await body(again), _png);
    expect(upstream, hasLength(1), reason: 'fresh cached tile, no request');

    // Not cached and no signal: a miss, so the map shows a coarser tile.
    final other = await get(tile.replaceFirst('/1714', '/1715'));
    expect(other.statusCode, 404);
    await other.drain<void>();
  });

  test('one download when the page asks for a tile three times', () async {
    // Terrain, hillshade and contours all want the same elevation tile.
    final gate = Completer<void>();
    slow = gate.future;
    final tile = '${proxy.origin}t/aws_terrain/10/600/427';
    final pending = Future.wait([get(tile), get(tile), get(tile)]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    gate.complete();
    for (final r in await pending) {
      expect(r.statusCode, 200);
      expect(await body(r), _png);
    }
    expect(upstream, hasLength(1));
  });

  test('only serves catalog layers and valid tiles', () async {
    for (final path in [
      't/evil/1/0/0',
      't/otm/1/2/0', // x out of range at zoom 1
      't/otm/x/0/0',
      't/contours/1/0/0', // computed on the phone, no tiles
    ]) {
      final r = await get('${proxy.origin}$path');
      expect(r.statusCode, 404, reason: path);
      await r.drain<void>();
    }
    expect(upstream, isEmpty);
  });

  test('adds the runner\'s key, and refuses keyed layers without', () async {
    final noKey = await get('${proxy.origin}t/mt_satellite/1/0/0');
    expect(noKey.statusCode, HttpStatus.forbidden);
    await noKey.drain<void>();
    expect(upstream, isEmpty);

    map = ResolvedMap.of(
      const MapSetup(baseId: 'mt_satellite'),
      (p) => p == MapProvider.maptiler ? 'k3y' : '',
    );
    final r = await get('${proxy.origin}t/mt_satellite/1/0/0');
    expect(r.statusCode, 200);
    await r.drain<void>();
    expect(upstream.single, endsWith('/1/0/0.jpg?key=k3y'));
  });
}
