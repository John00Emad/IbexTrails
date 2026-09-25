import 'course.dart';
import 'geo.dart';
import 'protocol.dart';

/// Everything known about one participant, built from their reports.
class Participant {
  Participant(PositionReport first, DateTime receivedAt)
    : latest = first,
      lastHeard = _heard(first, receivedAt),
      _anchor = first.point,
      lastMovedAt = first.time {
    _appendTrail(first);
  }

  PositionReport latest;

  /// When we last heard from them (never later than the report's own time,
  /// so retained reports from long ago are not mistaken for fresh ones).
  DateTime lastHeard;

  /// Last time they moved more than [_moveRadius] metres.
  DateTime lastMovedAt;
  GeoPoint _anchor;

  /// Whether they have moved at all since we first heard from them. Nobody
  /// is reported as "not moving" while still waiting at the start.
  bool hasMoved = false;

  /// Breadcrumb trail as received, oldest first.
  final List<TrailPoint> track = [];

  static const double _moveRadius = 40;
  static const int _maxTrack = 5000;

  String get id => latest.id;
  String get name => latest.name;

  static DateTime _heard(PositionReport r, DateTime receivedAt) =>
      r.time.isBefore(receivedAt) ? r.time : receivedAt;

  /// Applies a newer report. Returns false if [r] is older than what we have.
  bool apply(PositionReport r, DateTime receivedAt) {
    if (!r.time.isAfter(latest.time)) return false;
    latest = r;
    lastHeard = _heard(r, receivedAt);
    _appendTrail(r);
    return true;
  }

  void _appendTrail(PositionReport r) {
    final lastTime = track.isEmpty ? null : track.last.time;
    for (final p in [...r.trail, TrailPoint(r.lat, r.lon, r.time)]) {
      if (lastTime != null && !p.time.isAfter(lastTime)) continue;
      if (track.isNotEmpty && !p.time.isAfter(track.last.time)) continue;
      track.add(p);
      final here = GeoPoint(p.lat, p.lon);
      if (distanceBetween(here, _anchor) > _moveRadius) {
        _anchor = here;
        lastMovedAt = p.time;
        hasMoved = true;
      }
    }
    if (track.length > _maxTrack) {
      track.removeRange(0, track.length - _maxTrack);
    }
  }

  bool isActive() =>
      latest.status != RunnerStatus.left &&
      latest.status != RunnerStatus.finished;
}

/// Ordered by urgency.
enum AlertKind {
  sos('SOS'),
  offRoute('Off route'),
  wrongWay('Wrong way'),
  cutoffMissed('Missed cut-off'),
  leftUnconfirmed('Left, not confirmed safe'),
  behindSweeper('Behind the sweeper'),
  noSignal('No signal'),
  stopped('Not moving'),
  cutoffRisk('Behind cut-off pace'),
  lowBattery('Low battery');

  const AlertKind(this.label);
  final String label;
}

class GroupAlert {
  const GroupAlert(this.participant, this.kind, this.detail, {this.tag = ''});
  final Participant participant;
  final AlertKind kind;
  final String detail;

  /// Distinguishes alerts of the same kind, e.g. which checkpoint.
  final String tag;

  String get key => '${participant.id}/${kind.name}/$tag';
}

/// Who has passed one checkpoint, who is still out there, who missed it.
class CheckpointRow {
  const CheckpointRow({
    required this.checkpoint,
    required this.cutoff,
    required this.passed,
    required this.pending,
    required this.missed,
  });

  final Checkpoint checkpoint;

  /// Clock-time cut-off when the course has a set start.
  final DateTime? cutoff;
  final List<(Participant, DateTime)> passed;
  final List<Participant> pending;
  final List<Participant> missed;
}

/// Where everyone is, so the organizer can be sure nobody is left out on
/// the course.
class Headcount {
  Headcount({
    required this.notStarted,
    required this.onCourse,
    required this.finished,
    required this.safeOut,
    required this.unaccounted,
  });

  /// Joined but not really under way yet.
  final List<Participant> notStarted;
  final List<Participant> onCourse;
  final List<Participant> finished;

  /// Dropped out and confirmed safe, or ticked off by the organizer.
  final List<Participant> safeOut;

  /// Left without confirming they're safe, or silent for a long time.
  final List<Participant> unaccounted;

  int get total =>
      notStarted.length +
      onCourse.length +
      finished.length +
      safeOut.length +
      unaccounted.length;

  /// Finished or safely out.
  int get accountedFor => finished.length + safeOut.length;

  /// Everyone is home: nobody left on the course or missing.
  bool get allIn => total > 0 && accountedFor == total;
}

/// Alerting thresholds for the organizer.
class AlertPolicy {
  const AlertPolicy({
    this.noSignalAfter = const Duration(minutes: 5),
    this.stoppedAfter = const Duration(minutes: 10),
    this.lowBatteryPercent = 15,
    this.lostAfter = const Duration(minutes: 15),
    this.behindSweeperBy = 200,
  });

  /// Silence after which a runner counts as unaccounted in the headcount.
  final Duration lostAfter;

  /// How far (m) behind the last sweeper a runner must be to raise an alert.
  final double behindSweeperBy;
  final Duration noSignalAfter;
  final Duration stoppedAfter;
  final int lowBatteryPercent;
}

/// The organizer's view of everyone in the event.
class Group {
  final Map<String, Participant> _byId = {};

  Iterable<Participant> get participants => _byId.values;
  Participant? operator [](String id) => _byId[id];
  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;

  /// Returns true if the report changed anything.
  bool apply(PositionReport r, DateTime receivedAt) {
    final existing = _byId[r.id];
    if (existing == null) {
      _byId[r.id] = Participant(r, receivedAt);
      return true;
    }
    return existing.apply(r, receivedAt);
  }

  void remove(String id) => _byId.remove(id);
  void clear() => _byId.clear();

  /// Participants (optionally only those on [course]), furthest along the
  /// route first. Those without route progress come last, most recently
  /// heard first.
  List<Participant> byProgress({String? course}) {
    final list = _byId.values
        .where((p) => course == null || p.latest.course == course)
        .toList();
    list.sort((a, b) {
      final pa = a.latest.along, pb = b.latest.along;
      if (pa != null && pb != null) return pb.compareTo(pa);
      if (pa != null) return -1;
      if (pb != null) return 1;
      return b.lastHeard.compareTo(a.lastHeard);
    });
    return list;
  }

  /// Leader and last runner along the route among active participants.
  (Participant, Participant)? spread({String? course}) {
    final active = byProgress(course: course)
        .where((p) => p.isActive() && p.latest.along != null)
        .toList();
    if (active.isEmpty) return null;
    return (active.first, active.last);
  }

  /// All conditions that currently need the organizer's attention.
  /// [courseOf] resolves a runner's course, for checkpoint cut-offs.
  /// People in [accountedFor] (ticked off by the organizer) only raise SOS.
  List<GroupAlert> alerts(
    DateTime now,
    AlertPolicy policy, {
    Course? Function(String? id)? courseOf,
    Set<String> accountedFor = const {},
  }) {
    final out = <GroupAlert>[];
    final sweepers = _rearmostSweepers(now, policy);
    for (final p in _byId.values) {
      final r = p.latest;
      if (r.status == RunnerStatus.sos) {
        out.add(GroupAlert(p, AlertKind.sos, 'needs help'));
      }
      if (accountedFor.contains(p.id)) continue;
      if (r.status == RunnerStatus.left) {
        if (!r.safe) {
          out.add(
            GroupAlert(
              p,
              AlertKind.leftUnconfirmed,
              'closed the app at ${_clock(r.time)} without confirming they '
              'are off the course',
            ),
          );
        }
        continue;
      }
      final course = courseOf?.call(r.course);
      if (course != null) out.addAll(_cutoffAlerts(p, course, now));
      if (r.status == RunnerStatus.finished) continue;
      final sweeperAlong = sweepers[r.course];
      if (r.role == Role.runner &&
          r.along != null &&
          sweeperAlong != null &&
          r.along! < sweeperAlong - policy.behindSweeperBy) {
        out.add(
          GroupAlert(
            p,
            AlertKind.behindSweeper,
            '${formatDistance(sweeperAlong - r.along!)} behind the last '
            'sweeper',
          ),
        );
      }
      final silent = now.difference(p.lastHeard);
      if (silent > policy.noSignalAfter) {
        out.add(
          GroupAlert(
            p,
            AlertKind.noSignal,
            'last heard ${formatAgo(p.lastHeard, now)} ago',
          ),
        );
      }
      if (r.status == RunnerStatus.offRoute) {
        out.add(
          GroupAlert(
            p,
            AlertKind.offRoute,
            '${formatDistance(r.offBy ?? 0)} from the route',
          ),
        );
      }
      if (r.status == RunnerStatus.wrongWay) {
        out.add(
          GroupAlert(p, AlertKind.wrongWay, 'heading back along the route'),
        );
      }
      final still = r.time.difference(p.lastMovedAt);
      if (p.hasMoved &&
          silent <= policy.noSignalAfter &&
          still > policy.stoppedAfter) {
        out.add(
          GroupAlert(
            p,
            AlertKind.stopped,
            'stationary for ${formatAgo(p.lastMovedAt, now)}',
          ),
        );
      }
      if (r.battery != null && r.battery! <= policy.lowBatteryPercent) {
        out.add(GroupAlert(p, AlertKind.lowBattery, 'battery ${r.battery}%'));
      }
    }
    out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return out;
  }

  /// Progress of the rearmost active sweeper on each course.
  Map<String?, double> _rearmostSweepers(DateTime now, AlertPolicy policy) {
    final out = <String?, double>{};
    for (final p in _byId.values) {
      final r = p.latest;
      if (r.role != Role.sweeper || !p.isActive() || r.along == null) continue;
      if (now.difference(p.lastHeard) > policy.noSignalAfter) continue;
      final prev = out[r.course];
      if (prev == null || r.along! < prev) out[r.course] = r.along!;
    }
    return out;
  }

  /// Sorts everyone (optionally on one [course]) into headcount buckets.
  /// [exclude] leaves out the viewer, e.g. the organizer at the finish.
  Headcount headcount(
    DateTime now, {
    String? course,
    Set<String> accountedFor = const {},
    String? exclude,
    AlertPolicy policy = const AlertPolicy(),
  }) {
    final notStarted = <Participant>[];
    final onCourse = <Participant>[];
    final finished = <Participant>[];
    final safeOut = <Participant>[];
    final unaccounted = <Participant>[];
    for (final p in byProgress(course: course)) {
      if (p.id == exclude) continue;
      final r = p.latest;
      if (r.status == RunnerStatus.finished) {
        finished.add(p);
      } else if (accountedFor.contains(p.id) ||
          (r.status == RunnerStatus.left && r.safe)) {
        safeOut.add(p);
      } else if (r.status == RunnerStatus.left ||
          now.difference(p.lastHeard) > policy.lostAfter) {
        unaccounted.add(p);
      } else if ((r.along ?? 0) < 200 && r.passes.isEmpty && !p.hasMoved) {
        notStarted.add(p);
      } else {
        onCourse.add(p);
      }
    }
    return Headcount(
      notStarted: notStarted,
      onCourse: onCourse,
      finished: finished,
      safeOut: safeOut,
      unaccounted: unaccounted,
    );
  }

  List<GroupAlert> _cutoffAlerts(Participant p, Course course, DateTime now) {
    final r = p.latest;
    if (r.status == RunnerStatus.finished) return const [];
    final out = <GroupAlert>[];
    for (final cp in course.checkpoints) {
      final cutoff = course.cutoffTime(cp, runnerStart: r.started);
      if (cutoff == null || r.passes.containsKey(cp.id)) continue;
      if (now.isAfter(cutoff)) {
        out.add(
          GroupAlert(
            p,
            AlertKind.cutoffMissed,
            '${cp.name} closed at ${_clock(cutoff)}',
            tag: cp.id,
          ),
        );
      } else if (cp.id == r.next && r.eta != null && r.eta!.isAfter(cutoff)) {
        out.add(
          GroupAlert(
            p,
            AlertKind.cutoffRisk,
            '${cp.name}: ETA ${_clock(r.eta!)}, cut-off ${_clock(cutoff)}',
            tag: cp.id,
          ),
        );
      }
    }
    return out;
  }

  /// Per-checkpoint status for everyone on [course].
  List<CheckpointRow> checkpointBoard(Course course, DateTime now) {
    final runners = participants
        .where((p) => p.latest.course == course.id)
        .toList();
    return [
      for (final cp in course.checkpoints)
        () {
          final passed = <(Participant, DateTime)>[];
          final pending = <Participant>[];
          final missed = <Participant>[];
          for (final p in runners) {
            final at = p.latest.passes[cp.id];
            if (at != null) {
              passed.add((p, at));
              continue;
            }
            final cutoff = course.cutoffTime(cp, runnerStart: p.latest.started);
            if (cutoff != null && now.isAfter(cutoff)) {
              missed.add(p);
            } else if (p.latest.status != RunnerStatus.left) {
              pending.add(p);
            }
          }
          passed.sort((a, b) => a.$2.compareTo(b.$2));
          return CheckpointRow(
            checkpoint: cp,
            cutoff: course.cutoffTime(cp),
            passed: passed,
            pending: pending,
            missed: missed,
          );
        }(),
    ];
  }
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Remembers which alerts were already raised so each one notifies once
/// until it clears.
class AlertLatch {
  final Set<String> _active = {};

  /// Returns the alerts in [current] that were not active last time.
  List<GroupAlert> newlyRaised(List<GroupAlert> current) {
    final keys = current.map((a) => a.key).toSet();
    final fresh = current.where((a) => !_active.contains(a.key)).toList();
    _active
      ..clear()
      ..addAll(keys);
    return fresh;
  }

  void reset() => _active.clear();
}
