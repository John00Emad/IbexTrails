import 'dart:math' as math;

import 'geo.dart';
import 'route.dart';

/// Where the runner is relative to the route after a GPS fix.
class RouteMatch {
  const RouteMatch({
    required this.along,
    required this.distance,
    required this.nearest,
    required this.offRoute,
    required this.wrongWay,
    required this.finished,
    required this.jump,
  });

  /// Progress along the route in metres.
  final double along;

  /// Distance from the runner to the closest point of the route (m).
  final double distance;

  /// Closest point on the route.
  final GeoPoint nearest;

  /// Debounced: runner has been away from the route for several fixes.
  final bool offRoute;

  /// Debounced: runner is travelling backwards along the route.
  final bool wrongWay;

  /// Runner has reached the finish.
  final bool finished;

  /// Non-zero when this fix re-attached the runner to a distant part of the
  /// route (m, positive = ahead). Large forward jumps usually mean a wrong
  /// turn that happened to join the route further on.
  final double jump;
}

/// Tracks a runner's progress along a [TrailRoute] and decides when they are
/// off route or going the wrong way.
///
/// Matching is windowed around the last known progress so out-and-back
/// routes, loops and figure-eights (where the same trail is used more than
/// once) resolve to the correct pass. A global search is used to initialise
/// and to recover after a GPS gap or a shortcut.
class RouteMatcher {
  RouteMatcher(
    this.route, {
    this.offRouteThreshold = 50,
    this.wrongWayThreshold = 150,
    this.offFixesRequired = 3,
    this.onFixesRequired = 2,
  });

  final TrailRoute route;

  /// Distance from the route (m) beyond which the runner is off route.
  double offRouteThreshold;

  /// How far (m) the runner must travel backwards before a wrong-way alert.
  final double wrongWayThreshold;

  final int offFixesRequired;
  final int onFixesRequired;

  static const double _windowBack = 300;
  static const double _windowAhead = 1500;
  static const double _maxUsableAccuracy = 100;

  RouteMatch? _last;
  GeoPoint? _lastPos;
  double _maxAlong = 0;
  double _minAlongWhileWrong = double.infinity;
  int _offStreak = 0;
  int _onStreak = 0;
  bool _off = false;
  bool _wrongWay = false;
  bool _finished = false;

  RouteMatch? get last => _last;

  void reset() {
    _last = null;
    _lastPos = null;
    _maxAlong = 0;
    _minAlongWhileWrong = double.infinity;
    _offStreak = 0;
    _onStreak = 0;
    _off = false;
    _wrongWay = false;
    _finished = false;
  }

  /// Feeds a GPS fix. [accuracy] is the horizontal accuracy radius (m).
  /// Returns the latest match; very inaccurate fixes do not change state.
  RouteMatch update(GeoPoint pos, {double accuracy = 10}) {
    if (_last != null && accuracy > _maxUsableAccuracy) return _last!;

    final prev = _last;
    _Candidate best;
    var jump = 0.0;
    if (prev == null) {
      best = _initialMatch(pos);
    } else {
      final moved = distanceBetween(_lastPos!, pos);
      final expected = prev.along + moved;
      final windowed = _windowedMatch(pos, prev.along, expected);
      if (windowed != null && windowed.distance <= offRouteThreshold) {
        best = windowed;
      } else {
        final global = _globalMatch(pos);
        if (windowed == null ||
            (global.distance < windowed.distance - 20 &&
                global.distance <= offRouteThreshold)) {
          best = global;
          if ((global.along - expected).abs() > 300) {
            jump = global.along - expected;
          }
          // Re-anchor direction tracking on the new section.
          _maxAlong = best.along;
          _wrongWay = false;
          _minAlongWhileWrong = double.infinity;
        } else {
          best = windowed;
        }
      }
    }

    // Off-route with hysteresis. Poor accuracy widens the tolerance so a
    // wandering fix under trees does not raise a false alarm.
    final tolerance = offRouteThreshold + math.min(accuracy * 0.5, 25.0);
    if (best.distance > tolerance) {
      _offStreak++;
      _onStreak = 0;
      if (_offStreak >= offFixesRequired) _off = true;
    } else if (best.distance < offRouteThreshold * 0.8) {
      _onStreak++;
      _offStreak = 0;
      if (_onStreak >= onFixesRequired) _off = false;
    }

    // Direction: only judged while on the route.
    if (!_off) {
      if (_wrongWay) {
        _minAlongWhileWrong = math.min(_minAlongWhileWrong, best.along);
        if (best.along > _minAlongWhileWrong + 50) {
          // Turned around and heading forwards again.
          _wrongWay = false;
          _minAlongWhileWrong = double.infinity;
          _maxAlong = best.along;
        }
      } else if (best.along < _maxAlong - wrongWayThreshold) {
        _wrongWay = true;
        _minAlongWhileWrong = best.along;
      }
      _maxAlong = math.max(_maxAlong, best.along);
    }

    if (!_finished &&
        best.along >= route.length - 50 &&
        distanceBetween(pos, route.finish) < 60) {
      _finished = true;
    }

    _lastPos = pos;
    return _last = RouteMatch(
      along: best.along,
      distance: best.distance,
      nearest: best.point,
      offRoute: _off,
      wrongWay: _wrongWay && !_off,
      finished: _finished,
      jump: jump,
    );
  }

  _Candidate _candidateOn(int seg, GeoPoint pos) {
    final a = route.points[seg];
    final b = route.points[seg + 1];
    final proj = projectOntoSegment(pos, a, b);
    final along =
        route.cumDist[seg] +
        proj.t * (route.cumDist[seg + 1] - route.cumDist[seg]);
    return _Candidate(along, proj.distance, proj.point);
  }

  /// First fix: nearest segment, preferring the earliest pass among
  /// near-equal candidates (so a loop starts at 0 km, not at the finish).
  _Candidate _initialMatch(GeoPoint pos) {
    final all = [
      for (var i = 0; i < route.points.length - 1; i++) _candidateOn(i, pos),
    ];
    final minDist = all.map((c) => c.distance).reduce(math.min);
    final slack = math.max(20.0, minDist * 0.25);
    return all
        .where((c) => c.distance <= minDist + slack)
        .reduce((a, b) => a.along <= b.along ? a : b);
  }

  _Candidate _globalMatch(GeoPoint pos) {
    _Candidate? best;
    for (var i = 0; i < route.points.length - 1; i++) {
      final c = _candidateOn(i, pos);
      if (best == null || c.distance < best.distance) best = c;
    }
    return best!;
  }

  /// Best candidate whose progress lies in a window around the last known
  /// progress, or null if the route has no point in that window.
  _Candidate? _windowedMatch(GeoPoint pos, double lastAlong, double expected) {
    final lo = lastAlong - _windowBack;
    final hi = math.max(lastAlong, expected) + _windowAhead;
    final from = route.segmentIndexAt(lo);
    final to = route.segmentIndexAt(hi);
    _Candidate? best;
    var bestCost = double.infinity;
    for (var i = from; i <= to; i++) {
      final c = _candidateOn(i, pos);
      if (c.along < lo || c.along > hi) continue;
      final diff = c.along - expected;
      // Prefer continuing forwards at the expected pace. Going backwards is
      // penalised strongly so that on overlapping trails (out-and-back,
      // lollipops) a few metres of GPS error cannot flip the runner onto the
      // other pass; skipping ahead is penalised mildly.
      final cost = c.distance + (diff >= 0 ? diff * 0.02 : -diff * 0.5);
      if (cost < bestCost) {
        bestCost = cost;
        best = c;
      }
    }
    return best;
  }
}

class _Candidate {
  const _Candidate(this.along, this.distance, this.point);
  final double along;
  final double distance;
  final GeoPoint point;
}
