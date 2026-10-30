import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';

/// The phone's compass, for your arrow on the map.
abstract final class Compass {
  /// Which way the phone faces, in degrees from north, about 15 times a
  /// second while listened to. A phone without a compass sends only an
  /// error.
  static Stream<double> headings() {
    if (!RotationSensor.isPlatformSupported) return const Stream.empty();
    RotationSensor.samplingPeriod = SensorInterval.uiInterval;
    // iPhones give true north. Android phones give magnetic north, a few
    // degrees off in most places.
    RotationSensor.referenceFrame = ReferenceFrame.trueNorth;
    return RotationSensor.orientationStream.map(
      (e) => facing(e.rotationMatrix),
    );
  }

  /// The way you look over a phone turned by [r] (device axes to world
  /// axes: x east, y north, z up): where the top of the screen points with
  /// the phone flat, where its back points with it upright. The sensor's
  /// own azimuth follows the top of the screen only, so it swings about as
  /// you raise the phone to read the map.
  @visibleForTesting
  static double facing(Matrix3 r) {
    // The screen's up axis minus its outward axis (2nd and 3rd columns)
    // stays clear of vertical at any tilt between flat and upright.
    final east = r.b - r.c;
    final north = r.e - r.f;
    return (math.atan2(east, north) * 180 / math.pi) % 360;
  }
}
