import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

enum LocationProblem { serviceOff, denied, deniedForever }

class LocationUnavailable implements Exception {
  const LocationUnavailable(this.problem);
  final LocationProblem problem;

  String get message => switch (problem) {
    LocationProblem.serviceOff =>
      'Location is turned off. Turn on GPS/location services.',
    LocationProblem.denied =>
      'Location permission was denied. IbexTrails needs it to navigate.',
    LocationProblem.deniedForever =>
      'Location permission is blocked. Enable it in the system settings.',
  };

  @override
  String toString() => message;
}

/// Continuous GPS tracking that keeps running with the screen off.
///
/// On Android this runs as a foreground service with a persistent
/// notification; on iOS it uses background location updates.
class LocationService {
  /// Makes sure location is on and permitted. Throws [LocationUnavailable].
  static Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable(LocationProblem.serviceOff);
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw const LocationUnavailable(LocationProblem.denied);
    }
    if (perm == LocationPermission.deniedForever) {
      throw const LocationUnavailable(LocationProblem.deniedForever);
    }
  }

  static Future<bool> openSettings() => Geolocator.openAppSettings();
  static Future<bool> openLocationSettings() =>
      Geolocator.openLocationSettings();

  /// Stream of GPS fixes suitable for running navigation: every fix the
  /// receiver makes, about one a second, however little you moved. The map,
  /// the stats and turn warnings keep up even when hiking up a steep climb;
  /// the run itself ignores GPS jitter.
  static Stream<Position> track() => Geolocator.getPositionStream(
    locationSettings: settingsFor(kIsWeb ? null : defaultTargetPlatform),
  );

  /// The location request on [platform] (null on the web).
  @visibleForTesting
  static LocationSettings settingsFor(TargetPlatform? platform) =>
      switch (platform) {
        TargetPlatform.android => AndroidSettings(
          accuracy: LocationAccuracy.best,
          // No distance filter: it holds fixes back while walking slowly.
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'IbexTrails is tracking your run',
            notificationText:
                'Navigation and group tracking stay active '
                'while the screen is off.',
            notificationChannelName: 'Run tracking',
            enableWakeLock: true,
            setOngoing: true,
          ),
        ),
        TargetPlatform.iOS || TargetPlatform.macOS => AppleSettings(
          accuracy: LocationAccuracy.best,
          activityType: ActivityType.fitness,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: true,
        ),
        _ => const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      };
}
