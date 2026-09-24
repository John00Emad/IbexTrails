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

enum AlertKind {
  sos('SOS'),
  offRoute('Off route'),
  wrongWay('Wrong way'),
  noSignal('No signal'),
  stopped('Not moving'),
  lowBattery('Low battery');

  const AlertKind(this.label);
  final String label;
}

class GroupAlert {
  const GroupAlert(this.participant, this.kind, this.detail);
  final Participant participant;
  final AlertKind kind;
  final String detail;

  String get key => '${participant.id}/${kind.name}';
}

/// Alerting thresholds for the organizer.
class AlertPolicy {
  const AlertPolicy({
    this.noSignalAfter = const Duration(minutes: 5),
    this.stoppedAfter = const Duration(minutes: 10),
    this.lowBatteryPercent = 15,
  });

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

  /// Active participants, furthest along the route first. Those without
  /// route progress come last, most recently heard first.
  List<Participant> byProgress() {
    final list = _byId.values.toList();
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
  (Participant, Participant)? spread() {
    final active = byProgress()
        .where((p) => p.isActive() && p.latest.along != null)
        .toList();
    if (active.isEmpty) return null;
    return (active.first, active.last);
  }

  /// All conditions that currently need the organizer's attention.
  List<GroupAlert> alerts(DateTime now, AlertPolicy policy) {
    final out = <GroupAlert>[];
    for (final p in _byId.values) {
      final r = p.latest;
      if (r.status == RunnerStatus.left) continue;
      if (r.status == RunnerStatus.sos) {
        out.add(GroupAlert(p, AlertKind.sos, 'needs help'));
      }
      if (r.status == RunnerStatus.finished) continue;
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
}

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
