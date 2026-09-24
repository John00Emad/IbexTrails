// Renders the launcher icon artwork (lib/brand.dart) to a 1024 px PNG.
//
//   IBEX_ICON_OUT=/tmp/icon.png flutter test test/tool/app_icon_test.dart
//
// Then resize into android/app/src/main/res/mipmap-*/ic_launcher.png and
// ios/Runner/Assets.xcassets/AppIcon.appiconset/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/brand.dart';

final _out = Platform.environment['IBEX_ICON_OUT'];

void main() {
  test('render app icon', () async {
    const size = 1024.0;
    final recorder = ui.PictureRecorder();
    const AppIconPainter().paint(Canvas(recorder), const Size(size, size));
    final image = await recorder.endRecording().toImage(1024, 1024);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(_out!).writeAsBytesSync(png!.buffer.asUint8List());
  }, skip: _out == null ? 'set IBEX_ICON_OUT to render' : false);
}
