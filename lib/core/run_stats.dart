import 'geo.dart';
import 'route.dart';

/// Below this speed (m/s) the runner counts as stopped, e.g. at an aid
/// station or a viewpoint.
const _movingSpeed = 0.4;

/// The numbers of a recorded run, worked out from its track.
class RunStats {
  const RunStats({
    required this.distance,
    required this.ascent,
    required this.descent,
    this.elapsed,
    this.moving,
    this.splits = const [],
  });

  /// Stats for [points] recorded at [times] (one per point, null where
  /// unknown). Times are only used when every point has one.
  factory RunStats.of(List<GeoPoint> points, List<DateTime?> times) {
    final timed =
        points.length > 1 &&
        times.length == points.length &&
        times.every((t) => t != null);
    var distance = 0.0;
    var moving = Duration.zero;
    final splits = <Duration>[];
    DateTime? splitStart = timed ? times.first : null;
    var nextKm = 1000.0;
    for (var i = 1; i < points.length; i++) {
      final step = distanceBetween(points[i - 1], points[i]);
      if (timed) {
        final t0 = times[i - 1]!, t1 = times[i]!;
        final dt = t1.difference(t0);
        if (dt > Duration.zero &&
            step / (dt.inMilliseconds / 1000) >= _movingSpeed) {
          moving += dt;
        }
        // Time at each kilometre, interpolated within the step.
        while (step > 0 && distance + step >= nextKm) {
          final at = t0.add(dt * ((nextKm - distance) / step));
          splits.add(at.difference(splitStart!));
          splitStart = at;
          nextKm += 1000;
        }
      }
      distance += step;
    }
    final (ascent, descent) = points.length < 2
        ? (const [0.0], const [0.0])
        : cumulativeClimb(points);
    return RunStats(
      distance: distance,
      ascent: ascent.last,
      descent: descent.last,
      elapsed: timed ? times.last!.difference(times.first!) : null,
      moving: timed ? moving : null,
      splits: splits,
    );
  }

  /// Metres, from point to point (the distance the run screen showed).
  final double distance;

  final double ascent;
  final double descent;

  /// From the first point to the last. Null when the track has no times.
  final Duration? elapsed;

  /// [elapsed] without the stops.
  final Duration? moving;

  /// Time taken for each full kilometre, in order.
  final List<Duration> splits;

  /// Average moving time per kilometre.
  Duration? get pace {
    final m = moving;
    if (m == null || distance < 100) return null;
    return Duration(milliseconds: (m.inMilliseconds * 1000 / distance).round());
  }
}

/// A name for a run nobody named, from its local start time:
/// "Morning run", "Afternoon run", "Evening run" or "Night run".
String defaultRunName(DateTime start) {
  final h = start.toLocal().hour;
  final part = switch (h) {
    >= 5 && < 12 => 'Morning',
    >= 12 && < 17 => 'Afternoon',
    >= 17 && < 21 => 'Evening',
    _ => 'Night',
  };
  return '$part run';
}
