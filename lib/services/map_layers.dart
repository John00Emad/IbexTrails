import 'dart:convert';

/// Who serves a layer. Paid providers need the runner's own key: the
/// provider bills them directly and IbexTrails takes nothing.
enum MapProvider {
  free('Free', null, null),
  maptiler(
    'MapTiler',
    'https://cloud.maptiler.com/account/keys/',
    'Free plan for personal, non-commercial use',
  ),
  thunderforest(
    'Thunderforest',
    'https://manage.thunderforest.com/',
    'Free hobby plan',
  ),
  mapbox(
    'Mapbox',
    'https://account.mapbox.com/access-tokens/',
    'Free monthly allowance, then pay as you go',
  );

  const MapProvider(this.label, this.keyUrl, this.plan);
  final String label;

  /// Where to sign up and copy a key.
  final String? keyUrl;
  final String? plan;

  bool get needsKey => this != free;
}

enum LayerKind { base, overlay, elevation }

/// How a layer is drawn in the 3D view.
enum Render3d {
  /// Same raster tiles as the 2D map.
  raster,

  /// Shaded relief computed from the elevation layer.
  hillshade,

  /// Contour lines computed from the elevation layer.
  contours,
}

class MapLayer {
  const MapLayer({
    required this.id,
    required this.name,
    required this.kind,
    required this.attribution,
    this.description = '',
    this.provider = MapProvider.free,
    this.urlTemplate,
    this.subdomains = const [],
    this.maxNativeZoom = 18,
    this.allowsBulkDownload = false,
    this.render3d = Render3d.raster,
    this.demEncoding,
    this.defaultOpacity = 1,
  });

  final String id;
  final String name;
  final String description;
  final LayerKind kind;
  final MapProvider provider;

  /// Raster tile URL with `{z}`, `{x}`, `{y}`, optionally `{s}` and `{key}`.
  /// Null for layers that are computed on the phone (contours).
  final String? urlTemplate;
  final List<String> subdomains;
  final int maxNativeZoom;
  final String attribution;

  /// Whether the provider's terms allow downloading tiles ahead of time for
  /// offline use. Tiles that were viewed are cached either way.
  final bool allowsBulkDownload;
  final Render3d render3d;

  /// `terrarium` or `mapbox`, for elevation layers.
  final String? demEncoding;
  final double defaultOpacity;

  /// Can be drawn by the flat (2D) map.
  bool get has2d => urlTemplate != null && kind != LayerKind.elevation;

  /// Only exists in the 3D view.
  bool get terrainOnly => kind == LayerKind.overlay && !has2d;

  /// Same URL the map's tile layer requests, so prefetched tiles are found
  /// in the cache.
  String urlFor(int z, int x, int y, {String key = ''}) {
    var url = urlTemplate!
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y')
        .replaceAll('{key}', key);
    if (subdomains.isNotEmpty) {
      url = url.replaceAll('{s}', subdomains[(x + y) % subdomains.length]);
    }
    return url;
  }
}

// ---- Catalog ---------------------------------------------------------------

const _esriTile = 'https://server.arcgisonline.com/ArcGIS/rest/services';

/// Every layer the app can show. Free layers first; keyed layers are only
/// usable once the runner has added a key for their provider.
const mapLayers = <MapLayer>[
  // Base maps, free.
  MapLayer(
    id: 'otm',
    name: 'OpenTopoMap',
    description: 'Topo map with contours, hillshade and trails',
    kind: LayerKind.base,
    urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c'],
    maxNativeZoom: 17,
    attribution:
        '© OpenStreetMap contributors, SRTM · © OpenTopoMap (CC-BY-SA)',
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'osm',
    name: 'OpenStreetMap',
    description: 'Streets and paths',
    kind: LayerKind.base,
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    maxNativeZoom: 19,
    attribution: '© OpenStreetMap contributors',
    // The OSMF tile policy forbids downloading areas for offline use.
  ),
  MapLayer(
    id: 'esri_sat',
    name: 'Satellite (Esri)',
    description: 'Sharp, high-resolution imagery',
    kind: LayerKind.base,
    urlTemplate: '$_esriTile/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    maxNativeZoom: 18,
    attribution:
        'Imagery © Esri, Maxar, Earthstar Geographics, '
        'and the GIS User Community',
    // Esri's terms reserve offline export for a paid service.
  ),
  MapLayer(
    id: 's2_2016',
    name: 'Satellite (Sentinel-2)',
    description: 'Open imagery, 10 m detail',
    kind: LayerKind.base,
    urlTemplate:
        'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/'
        '{z}/{y}/{x}.jpg',
    maxNativeZoom: 15,
    attribution:
        'Sentinel-2 cloudless – https://s2maps.eu by EOX IT Services GmbH '
        '(Contains modified Copernicus Sentinel data 2016 & 2017)',
    allowsBulkDownload: true,
  ),

  // Base maps with the runner's own key.
  MapLayer(
    id: 'mt_satellite',
    name: 'MapTiler Satellite',
    description: 'High-resolution imagery',
    kind: LayerKind.base,
    provider: MapProvider.maptiler,
    urlTemplate:
        'https://api.maptiler.com/maps/satellite/256/{z}/{x}/{y}.jpg?key={key}',
    maxNativeZoom: 19,
    attribution: '© MapTiler © OpenStreetMap contributors',
    // MapTiler allows caching on the user's own device for that user.
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'mt_hybrid',
    name: 'MapTiler Satellite Hybrid',
    description: 'Imagery with roads and place names',
    kind: LayerKind.base,
    provider: MapProvider.maptiler,
    urlTemplate:
        'https://api.maptiler.com/maps/hybrid/256/{z}/{x}/{y}.jpg?key={key}',
    maxNativeZoom: 19,
    attribution: '© MapTiler © OpenStreetMap contributors',
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'mt_topo',
    name: 'MapTiler Topo',
    description: 'Topo map with contours and hillshade',
    kind: LayerKind.base,
    provider: MapProvider.maptiler,
    urlTemplate:
        'https://api.maptiler.com/maps/topo-v2/256/{z}/{x}/{y}.png?key={key}',
    maxNativeZoom: 19,
    attribution: '© MapTiler © OpenStreetMap contributors',
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'mt_outdoor',
    name: 'MapTiler Outdoor',
    description: 'Trails, peaks and contours',
    kind: LayerKind.base,
    provider: MapProvider.maptiler,
    urlTemplate: 'https://api.maptiler.com/maps/outdoor-v2/256/{z}/{x}/{y}.png?key={key}',
    maxNativeZoom: 19,
    attribution: '© MapTiler © OpenStreetMap contributors',
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'tf_outdoors',
    name: 'Thunderforest Outdoors',
    description: 'Hiking map with contours and hillshade',
    kind: LayerKind.base,
    provider: MapProvider.thunderforest,
    urlTemplate:
        'https://tile.thunderforest.com/outdoors/{z}/{x}/{y}.png?apikey={key}',
    maxNativeZoom: 20,
    attribution: 'Maps © Thunderforest · Data © OpenStreetMap contributors',
    // Pre-downloading needs one of their business plans.
  ),
  MapLayer(
    id: 'mb_satellite',
    name: 'Mapbox Satellite',
    description: 'High-resolution imagery',
    kind: LayerKind.base,
    provider: MapProvider.mapbox,
    urlTemplate:
        'https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90'
        '?access_token={key}',
    maxNativeZoom: 19,
    attribution: '© Mapbox © Maxar © OpenStreetMap contributors',
  ),
  MapLayer(
    id: 'mb_outdoors',
    name: 'Mapbox Outdoors',
    description: 'Trails, contours and hillshade',
    kind: LayerKind.base,
    provider: MapProvider.mapbox,
    urlTemplate:
        'https://api.mapbox.com/styles/v1/mapbox/outdoors-v12/tiles/256/'
        '{z}/{x}/{y}@2x?access_token={key}',
    maxNativeZoom: 19,
    attribution: '© Mapbox © OpenStreetMap contributors',
  ),

  // Overlays, all free.
  MapLayer(
    id: 'hillshade',
    name: 'Hillshade',
    description: 'Shaded relief so ridges and wadis stand out',
    kind: LayerKind.overlay,
    urlTemplate:
        '$_esriTile/Elevation/World_Hillshade/MapServer/tile/'
        '{z}/{y}/{x}',
    maxNativeZoom: 16,
    attribution: 'Hillshade © Esri',
    render3d: Render3d.hillshade,
    defaultOpacity: 0.4,
  ),
  MapLayer(
    id: 'contours',
    name: 'Contour lines',
    description: 'Every 10–100 m depending on zoom, with heights',
    kind: LayerKind.overlay,
    attribution: '',
    render3d: Render3d.contours,
    defaultOpacity: 0.8,
  ),
  MapLayer(
    id: 'trails',
    name: 'Hiking trails',
    description: 'Marked routes from OpenStreetMap',
    kind: LayerKind.overlay,
    urlTemplate: 'https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png',
    maxNativeZoom: 18,
    attribution: 'Trails © waymarkedtrails.org (CC-BY-SA)',
    defaultOpacity: 0.8,
  ),
  MapLayer(
    id: 'labels',
    name: 'Place names',
    description: 'Names and borders, handy over satellite',
    kind: LayerKind.overlay,
    urlTemplate:
        '$_esriTile/Reference/World_Boundaries_and_Places/MapServer/'
        'tile/{z}/{y}/{x}',
    maxNativeZoom: 19,
    attribution: 'Labels © Esri',
  ),

  // Elevation for 3D terrain, hillshade and contours.
  MapLayer(
    id: 'aws_terrain',
    name: 'Terrain Tiles (AWS Open Data)',
    description: 'Free worldwide elevation, about 30 m detail',
    kind: LayerKind.elevation,
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    // Deeper zooms add no real detail outside the US/Europe and can step
    // out of line with their neighbours (cliffs in 3D). 12 is also exactly
    // what the offline download saves.
    maxNativeZoom: 12,
    demEncoding: 'terrarium',
    attribution: 'Elevation: Mapzen Terrain Tiles (SRTM, GMTED2010, ETOPO1 …)',
    allowsBulkDownload: true,
  ),
  MapLayer(
    id: 'mb_terrain',
    name: 'Mapbox Terrain',
    description: 'Elevation from Mapbox',
    kind: LayerKind.elevation,
    provider: MapProvider.mapbox,
    urlTemplate:
        'https://api.mapbox.com/v4/mapbox.mapbox-terrain-dem-v1/{z}/{x}/{y}'
        '.pngraw?access_token={key}',
    maxNativeZoom: 14,
    demEncoding: 'mapbox',
    attribution: 'Elevation © Mapbox',
  ),
];

final _byId = {for (final l in mapLayers) l.id: l};

MapLayer? layerById(String? id) => _byId[id];

Iterable<MapLayer> layersOfKind(LayerKind kind) =>
    mapLayers.where((l) => l.kind == kind);

// ---- The runner's choice ---------------------------------------------------

/// One base map, any overlays (each with its own opacity), and the 3D view.
class MapSetup {
  const MapSetup({
    this.baseId = 'otm',
    this.overlays = const {},
    this.elevationId = 'aws_terrain',
    this.terrain3d = false,
    this.exaggeration = 1.3,
  });

  final String baseId;

  /// Overlay id → opacity (0–1), drawn in catalog order.
  final Map<String, double> overlays;
  final String elevationId;
  final bool terrain3d;

  /// Vertical exaggeration in the 3D view. Desert relief reads better a
  /// little stretched.
  final double exaggeration;

  MapSetup copyWith({
    String? baseId,
    Map<String, double>? overlays,
    String? elevationId,
    bool? terrain3d,
    double? exaggeration,
  }) => MapSetup(
    baseId: baseId ?? this.baseId,
    overlays: overlays ?? this.overlays,
    elevationId: elevationId ?? this.elevationId,
    terrain3d: terrain3d ?? this.terrain3d,
    exaggeration: exaggeration ?? this.exaggeration,
  );

  MapSetup withOverlay(String id, double? opacity) {
    final next = Map.of(overlays);
    if (opacity == null) {
      next.remove(id);
    } else {
      next[id] = opacity.clamp(0.0, 1.0);
    }
    return copyWith(overlays: next);
  }

  Map<String, Object> toJson() => {
    'base': baseId,
    'overlays': {
      for (final id in overlays.keys.toList()..sort()) id: overlays[id]!,
    },
    'elevation': elevationId,
    '3d': terrain3d,
    'exaggeration': exaggeration,
  };

  static MapSetup fromJson(Map<Object?, Object?> j) {
    const d = MapSetup();
    final overlays = <String, double>{};
    if (j['overlays'] case final Map<Object?, Object?> m) {
      for (final MapEntry(:key, :value) in m.entries) {
        if (key is String && value is num && layerById(key) != null) {
          overlays[key] = value.toDouble().clamp(0.0, 1.0);
        }
      }
    }
    final base = j['base'];
    final elevation = j['elevation'];
    final exaggeration = j['exaggeration'];
    return MapSetup(
      baseId: layerById(base as String?)?.kind == LayerKind.base
          ? base!
          : d.baseId,
      overlays: overlays,
      elevationId: layerById(elevation as String?)?.kind == LayerKind.elevation
          ? elevation!
          : d.elevationId,
      terrain3d: j['3d'] == true,
      exaggeration: exaggeration is num
          ? exaggeration.toDouble().clamp(1.0, 2.0)
          : d.exaggeration,
    );
  }

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is MapSetup && encode() == other.encode();

  @override
  int get hashCode => encode().hashCode;
}

/// Ready-made combinations, like the layer packs in hiking apps.
class MapPreset {
  const MapPreset(this.name, this.description, this.setup);
  final String name;
  final String description;
  final MapSetup setup;
}

const mapPresets = [
  MapPreset(
    'Satellite Topo',
    'Satellite, hillshade, contours and names in 3D',
    MapSetup(
      baseId: 'esri_sat',
      overlays: {'hillshade': 0.4, 'contours': 0.8, 'labels': 1},
      terrain3d: true,
    ),
  ),
  MapPreset('Topo', 'OpenTopoMap, flat', MapSetup()),
  MapPreset(
    'Streets & trails',
    'OpenStreetMap with marked hiking routes',
    MapSetup(baseId: 'osm', overlays: {'trails': 0.8}),
  ),
];

/// [setup] with every layer resolved, falling back to free layers where a
/// key is missing, so the map always shows something.
class ResolvedMap {
  ResolvedMap._(
    this.setup,
    this.base,
    this.overlays,
    this.elevation,
    this.keys,
  );

  factory ResolvedMap.of(MapSetup setup, String Function(MapProvider) keyFor) {
    final keys = {for (final p in MapProvider.values) p: keyFor(p)};
    bool usable(MapLayer l) =>
        !l.provider.needsKey || keys[l.provider]!.isNotEmpty;

    const fallback = MapSetup();
    var base = layerById(setup.baseId)!;
    if (!usable(base)) base = layerById(fallback.baseId)!;
    var elevation = layerById(setup.elevationId)!;
    if (!usable(elevation)) elevation = layerById(fallback.elevationId)!;
    final overlays = [
      for (final l in layersOfKind(LayerKind.overlay))
        if (setup.overlays[l.id] case final opacity? when usable(l))
          (l, opacity),
    ];
    return ResolvedMap._(setup, base, overlays, elevation, keys);
  }

  final MapSetup setup;
  final MapLayer base;
  final List<(MapLayer, double)> overlays;
  final MapLayer elevation;
  final Map<MapProvider, String> keys;

  bool get terrain3d => setup.terrain3d;

  String keyFor(MapLayer l) => keys[l.provider] ?? '';

  /// Base plus overlays the flat map can draw.
  List<(MapLayer, double)> get layers2d => [
    (base, 1.0),
    for (final o in overlays)
      if (o.$1.has2d) o,
  ];

  /// Layers whose tiles are fetched in the given view, for the offline
  /// download and the tile proxy.
  List<MapLayer> fetched({required bool in3d}) => [
    base,
    for (final (l, _) in overlays)
      if (in3d ? l.render3d == Render3d.raster : l.has2d) l,
    if (in3d) elevation,
  ];

  /// Credits for whatever is on screen.
  String attribution({required bool in3d}) {
    final parts = <String>[];
    void add(MapLayer l) {
      if (l.attribution.isNotEmpty && !parts.contains(l.attribution)) {
        parts.add(l.attribution);
      }
    }

    add(base);
    for (final (l, _) in overlays) {
      if (in3d ? l.render3d == Render3d.raster : l.has2d) {
        add(l);
      }
    }
    if (in3d) add(elevation);
    return parts.join(' · ');
  }
}
