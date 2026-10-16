// The route sheet: a solo run can go without a route.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/gpx.dart';
import 'package:ibex_trails/ui/route_picker.dart';

import '../helpers.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ibex_routes'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A page to open the sheet from, with saved routes kept in [dir].
  Future<BuildContext> pumpPage(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Home'))),
    );
    return tester.element(find.text('Home'));
  }

  /// Lets the sheet read the saved routes (real file access; widget tests
  /// otherwise run on fake time).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a solo run can start without a route', (tester) async {
    final choice = pickSoloRoute(await pumpPage(tester));
    await settle(tester);
    expect(find.text('Just run – no route'), findsOneWidget);
    expect(find.text('Import GPX file'), findsOneWidget);

    await tester.tap(find.text('Just run – no route'));
    await settle(tester);
    final picked = await choice;
    expect(picked, isNotNull);
    expect(picked!.route, isNull);
  });

  testWidgets('or follow a saved route', (tester) async {
    Directory('${dir.path}/routes').createSync();
    File('${dir.path}/routes/Wadi_loop_1727000000000.gpx')
        .writeAsStringSync(writeGpx(name: 'Wadi loop', points: eastLine(1000)));
    final choice = pickSoloRoute(await pumpPage(tester));
    await settle(tester);

    await tester.tap(find.text('Wadi loop'));
    await settle(tester);
    final picked = (await choice)!;
    expect(picked.route!.name, 'Wadi loop');
    expect(picked.route!.length, closeTo(1000, 1));
  });

  testWidgets('dismissing the sheet starts nothing', (tester) async {
    final choice = pickSoloRoute(await pumpPage(tester));
    await settle(tester);
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    expect(await choice, isNull);
  });

  testWidgets('loading a route mid-run has no Just run', (tester) async {
    unawaited(pickRoute(await pumpPage(tester)));
    await settle(tester);
    expect(find.text('Import GPX file'), findsOneWidget);
    expect(find.text('Just run – no route'), findsNothing);
  });
}
