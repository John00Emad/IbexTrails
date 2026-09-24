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

  /// Stream of GPS fixes suitable for running navigation.
  static Stream<Position> track() {
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'IbexTrails is tracking your run',
          notificationText:
              'Navigation and group tracking stay active '
              'while the screen is off.',
          notificationChannelName: 'Run tracking',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    } else if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.fitness,
        distanceFilter: 3,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      );
    }
    return Geolocator.getPositionStream(locationSettings: settings);
  }
}
