import 'course.dart';
import 'effort.dart';
import 'geo.dart';
import 'route_matcher.dart';

/// The runner's situation relative to the next checkpoint.
class CheckpointOutlook {
  const CheckpointOutlook({
    required this.checkpoint,
    required this.distance,
    required this.eta,
    this.cutoff,
  });

  final Checkpoint checkpoint;

  /// Distance still to run to it (m).
  final double distance;

  /// Projected arrival.
  final DateTime eta;

  /// Cut-off as a clock time, if it has one.
  final DateTime? cutoff;

  /// Positive when the runner is ahead of the cut-off.
  Duration? get margin => cutoff?.difference(eta);

  bool isMissed(DateTime now) => cutoff != null && now.isAfter(cutoff!);
  bool get atRisk => margin != null && margin!.isNegative;
}

/// Runner-side checkpoint timing: records when each checkpoint is passed
/// and projects arrival at the next one.
class CheckpointTracker {
  CheckpointTracker(this.course) : pace = PaceEstimator(course.route);

  final Course course;
  final PaceEstimator pace;

  /// Checkpoint id -> time passed.
  final Map<String, DateTime> passed = {};

  double? _lastAlong;

  /// Radius around a checkpoint that counts as passing it.
  static const passRadius = 80.0;

  /// Feeds a route match. Returns the checkpoints passed with this fix.
  List<Checkpoint> update(RouteMatch m, GeoPoint position, DateTime now) {
    final prev = _lastAlong;
    _lastAlong = m.along;
    if (!m.offRoute) pace.add(now, m.along);

    final fresh = <Checkpoint>[];
    for (final cp in course.checkpoints) {
      if (passed.containsKey(cp.id)) continue;
      // Crossed it while following the route. A jump (re-attaching to a
      // distant section, i.e. a shortcut) does not count.
      final crossed =
          prev != null &&
          !m.offRoute &&
          m.jump == 0 &&
          prev < cp.along &&
          m.along >= cp.along;
      // Or physically at it, on the matching pass of the route.
      final atIt =
          distanceBetween(position, course.pointOf(cp)) <= passRadius &&
          (m.along - cp.along).abs() < 300;
      if (crossed || atIt) {
        passed[cp.id] = now;
        fresh.add(cp);
      }
    }
    return fresh;
  }

  /// First checkpoint ahead that has not been passed.
  Checkpoint? get next {
    final along = _lastAlong ?? 0;
    for (final cp in course.checkpoints) {
      if (!passed.containsKey(cp.id) && cp.along >= along - 20) return cp;
    }
    return null;
  }

  CheckpointOutlook? outlook(DateTime now, {DateTime? runnerStart}) {
    final cp = next;
    final along = _lastAlong;
    if (cp == null || along == null) return null;
    return CheckpointOutlook(
      checkpoint: cp,
      distance: (cp.along - along).clamp(0, double.infinity).toDouble(),
      eta: pace.arrival(now, along, cp.along),
      cutoff: course.cutoffTime(cp, runnerStart: runnerStart),
    );
  }

  /// Checkpoints whose cut-off has passed without the runner getting there.
  List<Checkpoint> missed(DateTime now, {DateTime? runnerStart}) => [
    for (final cp in course.checkpoints)
      if (!passed.containsKey(cp.id) &&
          (course.cutoffTime(cp, runnerStart: runnerStart)?.isBefore(now) ??
              false))
        cp,
  ];

  /// Restores passes after the app was restarted.
  void restore(Map<String, DateTime> times) => passed.addAll(times);
}
