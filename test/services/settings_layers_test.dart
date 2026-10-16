import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/services/map_layers.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to the free topo map, flat', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    expect(s.mapSetup, const MapSetup());
    expect(s.resolvedMap.base.id, 'otm');
    expect(s.resolvedMap.terrain3d, isFalse);
  });

  test('keeps the map style chosen in earlier versions', () async {
    SharedPreferences.setMockInitialValues({'mapStyle': 'osm'});
    expect((await AppSettings.load()).mapSetup.baseId, 'osm');
    SharedPreferences.setMockInitialValues({'mapStyle': 'topo'});
    expect((await AppSettings.load()).mapSetup.baseId, 'otm');
  });

  test('layers and 3D persist', () async {
    SharedPreferences.setMockInitialValues({'mapStyle': 'osm'});
    final s = await AppSettings.load();
    var notified = 0;
    s.addListener(() => notified++);
    const setup = MapSetup(
      baseId: 'esri_sat',
      overlays: {'hillshade': 0.4, 'contours': 0.8},
      terrain3d: true,
      exaggeration: 1.5,
    );
    s.mapSetup = setup;
    expect(notified, 1);
    expect((await AppSettings.load()).mapSetup, setup);
  });

  test('a broken saved value falls back to the default', () async {
    SharedPreferences.setMockInitialValues({'mapSetup': '{not json'});
    expect((await AppSettings.load()).mapSetup, const MapSetup());
  });

  test('provider keys are per provider and trimmed', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    s.setMapKey(MapProvider.maptiler, '  abc123 ');
    expect(s.mapKey(MapProvider.maptiler), 'abc123');
    expect(s.mapKey(MapProvider.mapbox), '');
    expect(s.mapKey(MapProvider.free), '');

    s.mapSetup = const MapSetup(baseId: 'mt_satellite');
    expect(s.resolvedMap.base.id, 'mt_satellite');
    expect(s.resolvedMap.keyFor(s.resolvedMap.base), 'abc123');

    // Removing the key brings the free map back.
    s.setMapKey(MapProvider.maptiler, '');
    expect(s.resolvedMap.base.id, 'otm');
    expect(s.mapSetup.baseId, 'mt_satellite', reason: 'choice is kept');
  });
}
