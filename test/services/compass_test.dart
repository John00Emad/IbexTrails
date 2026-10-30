import 'dart:math' as math;

import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/services/compass.dart';

/// How a phone is turned when you look towards [bearing] (degrees from
/// north) over it, tilted [tilt] degrees up from lying flat (90: upright).
Matrix3 _held(double bearing, double tilt) {
  final b = bearing * math.pi / 180;
  final t = tilt * math.pi / 180;
  final ahead = Vector3(math.sin(b), math.cos(b), 0);
  final up = Vector3(0, 0, 1);
  return Matrix3.columns(
    Vector3(math.cos(b), -math.sin(b), 0), // the screen's right edge
    ahead * math.cos(t) + up * math.sin(t), // its top edge
    up * math.cos(t) - ahead * math.sin(t), // out of the screen, at you
  );
}

void main() {
  test('the compass shows where you look over the phone', () {
    // Flat in your hand: where the top of the screen points.
    expect(Compass.facing(_held(90, 0)), closeTo(90, 0.01));
    // Raised to read the map.
    expect(Compass.facing(_held(270, 45)), closeTo(270, 0.01));
    expect(Compass.facing(_held(350, 30)), closeTo(350, 0.01));
    // Upright, like a camera: where its back points.
    expect(Compass.facing(_held(180, 90)), closeTo(180, 0.01));
    // Leaning back past upright, so the top of the screen points behind
    // you: still the way you look.
    expect(Compass.facing(_held(10, 100)), closeTo(10, 0.01));
  });
}
