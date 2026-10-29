// The GPS is asked for every fix it makes, so the map and turn warnings
// keep up at any speed.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ibex_trails/services/location_service.dart';

void main() {
  test('Android: a fix every second, however little you moved', () {
    final s =
        LocationService.settingsFor(TargetPlatform.android) as AndroidSettings;
    expect(s.intervalDuration, const Duration(seconds: 1));
    expect(s.distanceFilter, 0);
    expect(s.accuracy, LocationAccuracy.best);
    // Tracking carries on with the screen off.
    expect(s.foregroundNotificationConfig, isNotNull);
  });

  test('iPhone: every fix, in the background too', () {
    final s = LocationService.settingsFor(TargetPlatform.iOS) as AppleSettings;
    expect(s.distanceFilter, 0);
    expect(s.accuracy, LocationAccuracy.best);
    expect(s.activityType, ActivityType.fitness);
    expect(s.allowBackgroundLocationUpdates, isTrue);
    expect(s.pauseLocationUpdatesAutomatically, isFalse);
  });

  test('elsewhere: every fix', () {
    final s = LocationService.settingsFor(null);
    expect(s.distanceFilter, 0);
    expect(s.accuracy, LocationAccuracy.best);
  });
}
