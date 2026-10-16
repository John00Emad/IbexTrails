import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/services/map_layers.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/ui/layers_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppSettings settings;

  Future<void> pumpPanel(WidgetTester tester) async {
    // Tall enough that the whole list is built.
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    settings = (await tester.runAsync(AppSettings.load))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LayersPanel(settings: settings)),
      ),
    );
  }

  testWidgets('choosing a free base map', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Satellite (Sentinel-2)'));
    await tester.pump();
    expect(settings.mapSetup.baseId, 's2_2016');
    expect(describeMapSetup(settings), 'Satellite (Sentinel-2)');
  });

  testWidgets('overlays switch on at their default opacity', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Hillshade'));
    await tester.pump();
    expect(settings.mapSetup.overlays, {'hillshade': 0.4});
    // An opacity slider appears for it.
    expect(find.byType(Slider), findsOneWidget);

    await tester.tap(find.text('Hillshade'));
    await tester.pump();
    expect(settings.mapSetup.overlays, isEmpty);
  });

  testWidgets('presets set base, overlays and 3D', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.text('Satellite Topo'));
    await tester.pump();
    final setup = settings.mapSetup;
    expect(setup.baseId, 'esri_sat');
    expect(setup.terrain3d, isTrue);
    expect(setup.overlays.keys, containsAll(['hillshade', 'contours']));
    expect(find.text('Exaggerate relief'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Satellite Topo'))
          .selected,
      isTrue,
    );
  });

  testWidgets('a keyed layer asks for the key first', (tester) async {
    await pumpPanel(tester);
    final tile = find.widgetWithText(ListTile, 'MapTiler Satellite');
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.lock_outline)),
      findsOneWidget,
    );

    // Cancelled: nothing changes.
    await tester.tap(find.text('MapTiler Satellite'));
    await tester.pumpAndSettle();
    expect(find.text('MapTiler key'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(settings.mapSetup.baseId, 'otm');

    // With a key: saved and selected.
    await tester.tap(find.text('MapTiler Satellite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' my-key ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(settings.mapKey(MapProvider.maptiler), 'my-key');
    expect(settings.mapSetup.baseId, 'mt_satellite');
    expect(settings.resolvedMap.base.id, 'mt_satellite');
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.lock_outline)),
      findsNothing,
    );
  });
}
