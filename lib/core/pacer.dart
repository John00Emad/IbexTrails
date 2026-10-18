import 'dart:math' as math;

import 'effort.dart';
import 'geo.dart';
import 'route.dart';

/// The pace range a runner wants to hold in a race, for the virtual pacer.
/// Paces are in seconds per km: smaller is faster.
class PacerPlan {
  const PacerPlan({
    this.enabled = false,
    this.fastest = 360,
    this.slowest = 420,
    this.hills = true,
    this.voice = true,
  });

  /// Range limits: 3:00 to 15:00 per km.
  static const minPace = 180;
  static const maxPace = 900;

  final bool enabled;

  /// Fastest pace of the range (s/km).
  final int fastest;

  /// Slowest pace of the range (s/km).
  final int slowest;

  /// On a route with elevation, climbs get more time (km-effort).
  final bool hills;

  /// Say cues out loud as well as buzzing.
  final bool voice;

  /// The virtual runner's pace: the middle of the range.
  double get target => (fastest + slowest) / 2;

  PacerPlan copyWith({
    bool? enabled,
    int? fastest,
    int? slowest,
    bool? hills,
    bool? voice,
  }) => PacerPlan(
    enabled: enabled ?? this.enabled,
    fastest: fastest ?? this.fastest,
    slowest: slowest ?? this.slowest,
    hills: hills ?? this.hills,
    voice: voice ?? this.voice,
  );

  Map<String, Object?> toJson() => {
    'on': enabled,
    'fast': fastest,
    'slow': slowest,
    'hills': hills,
    'voice': voice,
  };

  static PacerPlan fromJson(Map json) {
    int pace(Object? v, int fallback) =>
        ((v as num?)?.round() ?? fallback).clamp(minPace, maxPace);
    final a = pace(json['fast'], 360);
    final b = pace(json['slow'], 420);
    return PacerPlan(
      enabled: json['on'] as bool? ?? false,
      fastest: math.min(a, b),
      slowest: math.max(a, b),
      hills: json['hills'] as bool? ?? true,
      voice: json['voice'] as bool? ?? true,
    );
  }
}

/// A pace as minutes and seconds per km, e.g. `5:30`.
String formatPace(num secondsPerKm) =>
    formatDuration(Duration(seconds: secondsPerKm.round()));

/// A pace as it is said out loud: "5 minutes 30 seconds".
String spokenPace(num secondsPerKm) {
  final s = secondsPerKm.round();
  final minutes = s ~/ 60 == 1 ? '1 minute' : '${s ~/ 60} minutes';
  final seconds = s % 60;
  if (seconds == 0) return minutes;
  return '$minutes $seconds ${seconds == 1 ? 'second' : 'seconds'}';
}

/// Where the current pace is, relative to the range.
enum PaceZone {
  tooFast('Too fast'),
  onPace('On pace'),
  tooSlow('Too slow');

  const PaceZone(this.label);
  final String label;
}

/// Something to tell the runner: their pace left the range, or came back.
class PacerCue {
  const PacerCue(this.zone, this.pace);

  /// [PaceZone.onPace] means back on pace.
  final PaceZone zone;

  /// The pace at the time (s/km).
  final double pace;

  String get title => zone == PaceZone.onPace ? 'Back on pace' : zone.label;

  /// What is said out loud.
  String get spoken => switch (zone) {
    PaceZone.tooFast =>
      'Too fast: ${spokenPace(pace)} per kilometre. Ease off.',
    PaceZone.onPace => 'Back on pace.',
    PaceZone.tooSlow =>
      'Too slow: ${spokenPace(pace)} per kilometre. Pick it up.',
  };
}

/// Where and when the virtual runner set off.
class PacerAnchor {
  const PacerAnchor(this.time, this.progress);
  final DateTime time;

  /// Metres along the route, or of distance run when there is no route.
  final double progress;
}

/// One GPS fix, as the pacer sees it.
class _Sample {
  const _Sample(
    this.time,
    this.speed,
    this.distance,
    this.progress,
    this.along,
  );
  final DateTime time;

  /// m/s.
  final double speed;

  /// Distance run so far (m).
  final double distance;

  /// Distance along the route when following one, else [distance].
  final double progress;
  final double? along;
}

/// Runs with you at your target pace and keeps an eye on yours.
///
/// Feed it every GPS fix with [addFix]. It averages your pace over the last
/// minute of running, compares it with the plan's range (allowing more time
/// on climbs), and returns a [PacerCue] when you drift out of the range and
/// when you are back in it. It also keeps a virtual runner going at the
/// middle of the range, from when you start running, so you can see how far
/// ahead or behind it you are.
///
/// Times are those of the fixes. While you stand still the GPS sends none,
/// so [tick] moves the clock on and notices the stop.
class VirtualPacer {
  VirtualPacer({required this.plan, this._route});

  PacerPlan plan;

  /// The pace is averaged over this much running.
  static const window = Duration(seconds: 60);

  /// Running needed before the pace counts, after starting or a stop.
  static const settle = Duration(seconds: 20);

  /// No movement for this long is a stop: the pacer goes quiet.
  static const stopAfter = Duration(seconds: 10);

  /// Slower than this (m/s) isn't moving.
  static const movingSpeed = 0.5;

  /// Out of the range for this long before the first cue.
  static const confirm = Duration(seconds: 15);

  /// Back in the range for this long before "back on pace".
  static const confirmBack = Duration(seconds: 10);

  /// Reminder while the pace stays out of the range.
  static const repeat = Duration(minutes: 3);

  /// How far past an edge of the range (as a fraction) the pace must go to
  /// count as out of it, so GPS wobble at the edge doesn't flip it.
  static const tolerance = 0.02;

  /// Climbs never get more than this many times the flat pace (about 40%).
  static const maxClimbFactor = 5.0;

  /// How far outside the range overall still counts as in it, so that early
  /// on, when a few metres of GPS error are a lot, [schedule] doesn't
  /// flicker.
  static const scheduleSlack = Duration(seconds: 10);

  TrailRoute? _route;

  /// Scheduled race (wave) start. When following a route, the virtual
  /// runner sets off from the start of the route at this time.
  DateTime? raceStart;

  /// Fixes of the current stretch of running, over the last [window].
  final _samples = <_Sample>[];
  _Sample? _last;
  _Sample? _finish;
  DateTime? _now;
  DateTime? _lastMoving;
  DateTime? _movingSince;

  /// Fixes before this don't count for setting off (after [restart]).
  DateTime? _since;
  bool _restarted = false;
  PacerAnchor? _anchor;

  double? _pace;
  double _factor = 1;
  PaceZone? _zone;
  DateTime? _zoneSince;

  /// The zone the runner was last told about; null once back on pace.
  PaceZone? _cued;
  DateTime? _cuedAt;

  /// The route being followed, if any: progress is then measured along it.
  /// Changing it starts the virtual runner again.
  TrailRoute? get route => _route;
  set route(TrailRoute? r) {
    if (identical(r, _route)) return;
    _route = r;
    _samples.clear();
    _last = null;
    _finish = null;
    _lastMoving = null;
    _movingSince = null;
    _since = null;
    _restarted = false;
    _anchor = null;
    _reset();
  }

  /// Your pace (s/km), averaged over the last minute of running. Null until
  /// you have been running for a moment, and while you stop.
  double? get pace => _pace;

  /// Whether you were running and have stopped.
  bool get stopped => _lastMoving != null && _isStopped(_now!);

  /// Whether you have finished the route.
  bool get finished => _finish != null;

  /// Where your pace is relative to [range]. Null without a [pace].
  PaceZone? get zone => _zone;

  /// How much more time the stretch just run deserves for its climbing: 1
  /// on the flat or downhill, 1.5 for 5 m of climbing per 100 m (100 m of
  /// climbing counts as 1 km, as in km-effort).
  double get climbFactor => _factor;

  /// The range for the stretch just run (s/km): the plan's, with more time
  /// on climbs.
  (double, double) get range =>
      (plan.fastest * _factor, plan.slowest * _factor);

  /// When and where the virtual runner set off. Null until you start
  /// running, unless the race has a start time.
  PacerAnchor? get anchor {
    final start = raceStart;
    if (!_restarted && start != null && _route != null) {
      return PacerAnchor(start, 0);
    }
    return _anchor;
  }

  /// Time ahead of the virtual runner (negative: behind it). Null until it
  /// has set off.
  Duration? get gap {
    final a = anchor;
    final last = _finish ?? _last;
    final now = _finish?.time ?? _now;
    if (a == null || last == null || now == null || now.isBefore(a.time)) {
      return null;
    }
    final needs = _km(a.progress, last.progress) * plan.target;
    final took = now.difference(a.time).inMilliseconds / 1000;
    return Duration(milliseconds: ((needs - took) * 1000).round());
  }

  /// How you are doing overall since the virtual runner set off: ahead of
  /// even the fastest pace of the range, within it, or behind the slowest
  /// (give or take [scheduleSlack]). Null until it has set off.
  PaceZone? get schedule {
    final a = anchor;
    final last = _finish ?? _last;
    final now = _finish?.time ?? _now;
    if (a == null || last == null || now == null || now.isBefore(a.time)) {
      return null;
    }
    final km = _km(a.progress, last.progress);
    final took = now.difference(a.time).inMilliseconds / 1000;
    final slack = scheduleSlack.inSeconds;
    if (took < km * plan.fastest - slack) return PaceZone.tooFast;
    if (took > km * plan.slowest + slack) return PaceZone.tooSlow;
    return PaceZone.onPace;
  }

  /// Metres ahead of the virtual runner (negative: behind it), along the
  /// route or in distance run. Null until it has set off.
  double? get lead {
    final last = _finish ?? _last;
    final ghost = ghostProgress;
    if (last == null || ghost == null) return null;
    return last.progress - ghost;
  }

  /// Where the virtual runner is along the route (m). Null without a route
  /// or before it has set off.
  double? get ghostAlong => _route == null ? null : ghostProgress;

  /// How far the virtual runner has got: along the route, or in distance
  /// run without one. Null before it has set off.
  double? get ghostProgress {
    final a = anchor;
    final now = _finish?.time ?? _now;
    if (a == null || now == null || now.isBefore(a.time)) return null;
    final km = now.difference(a.time).inMilliseconds / 1000 / plan.target;
    final r = _route;
    if (r == null) return a.progress + km * 1000;
    if (!_climbing(r)) return math.min(r.length, a.progress + km * 1000);
    // Where the km-effort from the anchor reaches what it has covered.
    if (effortKm(r, a.progress, r.length) <= km) return r.length;
    var lo = a.progress, hi = r.length;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (effortKm(r, a.progress, mid) < km) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// Feeds a GPS fix taken at [time]: the [distance] run so far (m), the
  /// GPS [speed] (m/s) if known, and how far [along] the route you are when
  /// following one. [quiet] holds back cues (e.g. while off route), and
  /// [finished] stops the pacer at the finish. Returns a cue when the runner
  /// should hear one.
  PacerCue? addFix(
    DateTime time, {
    required double distance,
    double? speed,
    double? along,
    bool quiet = false,
    bool finished = false,
  }) {
    final prev = _last;
    if (_finish != null || (prev != null && !time.isAfter(prev.time))) {
      return null;
    }
    final now = _now;
    if (now == null || time.isAfter(now)) _now = time;
    final v =
        speed ??
        (prev == null
            ? 0.0
            : (distance - prev.distance) /
                  (time.difference(prev.time).inMilliseconds / 1000));
    final progress = _route == null ? distance : along ?? prev?.progress ?? 0;
    final sample = _Sample(time, v, distance, progress, along);
    _last = sample;
    if (finished && _route != null) {
      _finish = sample;
      _reset();
      return null;
    }

    if (v >= movingSpeed) {
      // Starting off, or again after a stop: the pace is measured afresh.
      if (_lastMoving == null || _isStopped(time)) {
        _samples.clear();
        _movingSince = time;
        _reset();
      }
      _lastMoving = time;
    } else if (_lastMoving == null || _isStopped(time)) {
      _reset();
      return null;
    }
    _samples.add(sample);
    final from = time.subtract(window);
    while (_samples.length > 1 && _samples.first.time.isBefore(from)) {
      _samples.removeAt(0);
    }

    _pace = _measurePace(time);
    final p = _pace;
    if (p == null) return null;
    _factor = _measureClimb();
    if (_anchor == null) {
      final since = _since;
      final first = _samples.firstWhere(
        (s) => since == null || !s.time.isBefore(since),
        orElse: () => sample,
      );
      _anchor = PacerAnchor(first.time, first.progress);
    }

    final z = _classify(p, _zone);
    if (z != _zone) {
      _zone = z;
      _zoneSince = time;
    }
    // Nothing to say while warming up before the race start either.
    if (quiet || (anchor?.time.isAfter(time) ?? false)) return null;
    final held = time.difference(_zoneSince!);
    if (z == PaceZone.onPace) {
      if (_cued == null || held < confirmBack) return null;
      _cued = null;
      return PacerCue(z, p);
    }
    if (held < confirm) return null;
    if (_cued == z && time.difference(_cuedAt!) < repeat) return null;
    _cued = z;
    _cuedAt = time;
    return PacerCue(z, p);
  }

  /// Moves the pacer's clock on to [now] without a fix, e.g. while standing
  /// still (the GPS sends nothing then), and notices a stop.
  void tick(DateTime now) {
    final prev = _now;
    if (prev == null || now.isAfter(prev)) _now = now;
    if (stopped) _reset();
  }

  /// Sets the virtual runner off again from where you are: now if you are
  /// running, otherwise when you next start.
  void restart(DateTime now) {
    _restarted = true;
    _since = now;
    _anchor = null;
    _finish = null;
    if (_pace != null) {
      final last = _last!;
      _anchor = PacerAnchor(last.time, last.progress);
    }
  }

  /// Where the virtual runner set off from, to carry on after the app is
  /// restarted. Null until it has.
  Map<String, Object?>? toJson() {
    final a = _anchor;
    if (a == null) return null;
    return {
      't': a.time.millisecondsSinceEpoch,
      'p': a.progress,
      if (_restarted) 'r': true,
    };
  }

  /// Carries on with a virtual runner saved by [toJson].
  void restore(Map json) {
    _anchor = PacerAnchor(
      DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
      (json['p'] as num).toDouble(),
    );
    _restarted = json['r'] == true;
  }

  bool _isStopped(DateTime now) => now.difference(_lastMoving!) >= stopAfter;

  bool _climbing(TrailRoute r) => plan.hills && r.hasElevation;

  /// Forgets the pace and the zone, e.g. on a stop. Cues start afresh.
  void _reset() {
    _pace = null;
    _factor = 1;
    _zone = null;
    _zoneSince = null;
    _cued = null;
    _cuedAt = null;
  }

  double? _measurePace(DateTime now) {
    final since = _movingSince;
    if (since == null || now.difference(since) < settle) return null;
    final speed =
        _samples.fold<double>(0, (sum, s) => sum + s.speed) / _samples.length;
    return speed < movingSpeed ? null : 1000 / speed;
  }

  double _measureClimb() {
    final r = _route;
    if (r == null || !_climbing(r)) return 1;
    final on = [
      for (final s in _samples)
        if (s.along != null) s.along!,
    ];
    if (on.length < 2 || on.last - on.first < 20) return 1;
    final a = on.first, b = on.last;
    final climb = (r.elevationAt(b) ?? 0) - (r.elevationAt(a) ?? 0);
    return (1 + 10 * math.max(0, climb) / (b - a)).clamp(1.0, maxClimbFactor);
  }

  /// Kilometres from [from] to [to] (m) as the pacer counts them: km-effort
  /// when climbs get more time.
  double _km(double from, double to) {
    final r = _route;
    if (r == null || !_climbing(r)) return (to - from) / 1000;
    return to >= from ? effortKm(r, from, to) : -effortKm(r, to, from);
  }

  PaceZone _classify(double pace, PaceZone? current) {
    final (lo, hi) = range;
    // Once out, it takes getting back inside the range to be on pace again.
    if (current == PaceZone.tooFast && pace < lo) return PaceZone.tooFast;
    if (current == PaceZone.tooSlow && pace > hi) return PaceZone.tooSlow;
    if (pace < lo * (1 - tolerance)) return PaceZone.tooFast;
    if (pace > hi * (1 + tolerance)) return PaceZone.tooSlow;
    return PaceZone.onPace;
  }
}
