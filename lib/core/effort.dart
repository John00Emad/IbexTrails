import 'dart:math' as math;

import 'route.dart';

/// ITRA "km-effort": distance in km plus climbing in hundreds of metres.
/// 100 m of ascent costs about as much as 1 km on the flat, which makes
/// arrival times on hilly trails far more realistic than distance alone.
double effortKm(TrailRoute route, double fromAlong, double toAlong) {
  final a = math.min(fromAlong, toAlong).clamp(0.0, route.length);
  final b = math.max(fromAlong, toAlong).clamp(0.0, route.length);
  return (b - a) / 1000 + (route.ascentAt(b) - route.ascentAt(a)) / 100;
}

/// Estimates a runner's pace in minutes per km-effort from recent progress
/// and projects arrival times further along the route.
class PaceEstimator {
  PaceEstimator(
    this.route, {
    this.window = const Duration(minutes: 15),
    this.fallbackMinPerEffortKm = 8,
  });

  final TrailRoute route;

  /// How much recent history the pace is based on.
  final Duration window;

  /// Used until there is enough data (a steady trail-running effort).
  final double fallbackMinPerEffortKm;

  final List<(DateTime, double)> _samples = [];
  (DateTime, double)? _first;

  void add(DateTime time, double along) {
    _first ??= (time, along);
    _samples.add((time, along));
    // Keep one sample older than the window as the anchor.
    while (_samples.length > 2 && time.difference(_samples[1].$1) > window) {
      _samples.removeAt(0);
    }
  }

  void reset() {
    _samples.clear();
    _first = null;
  }

  /// Minutes per km-effort, from the recent window if it has enough
  /// progress, else since the start, else the fallback.
  double get minPerEffortKm {
    double? paceBetween((DateTime, double)? a, (DateTime, double) b) {
      if (a == null) return null;
      final minutes = b.$1.difference(a.$1).inSeconds / 60;
      final effort = effortKm(route, a.$2, b.$2);
      if (minutes < 3 || effort < 0.2 || b.$2 <= a.$2) return null;
      return minutes / effort;
    }

    if (_samples.isEmpty) return fallbackMinPerEffortKm;
    final last = _samples.last;
    final pace = paceBetween(_samples.first, last) ?? paceBetween(_first, last);
    // Clamp to plausible values: 3 min (elite downhill) to 40 min (hiking a
    // steep climb) per km-effort.
    return (pace ?? fallbackMinPerEffortKm).clamp(3.0, 40.0);
  }

  /// Time needed from [fromAlong] to [toAlong] at the current pace.
  Duration timeBetween(double fromAlong, double toAlong) {
    if (toAlong <= fromAlong) return Duration.zero;
    final minutes = effortKm(route, fromAlong, toAlong) * minPerEffortKm;
    return Duration(seconds: (minutes * 60).round());
  }

  /// Projected clock time of reaching [toAlong] from [fromAlong] at [now].
  DateTime arrival(DateTime now, double fromAlong, double toAlong) =>
      now.add(timeBetween(fromAlong, toAlong));
}
