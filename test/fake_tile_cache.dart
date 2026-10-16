import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';

/// In-memory stand-in for the map's tile cache.
class FakeCache implements MapCachingProvider {
  final tiles = <String, CachedMapTile>{};

  @override
  bool get isSupported => true;

  @override
  Future<CachedMapTile?> getTile(String url) async => tiles[url];

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    tiles[url] = (bytes: bytes ?? tiles[url]!.bytes, metadata: metadata);
  }
}
