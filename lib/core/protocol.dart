import 'geo.dart';
import 'route.dart';

/// MQTT topic layout for one event. `topicId` is derived from the event code
/// (see `EventCipher`), so the code itself never appears on the relay.
class EventTopics {
  const EventTopics(this.topicId);
  final String topicId;

  String get base => 'ibextrails/v1/$topicId';
  String get all => '$base/#';
  String get event => '$base/event';
  String get announcement => '$base/msg';
  String position(String participantId) => '$base/pos/$participantId';

  /// Returns the participant id if [topic] is a position topic of this event.
  String? participantOf(String topic) {
    final prefix = '$base/pos/';
    return topic.startsWith(prefix) ? topic.substring(prefix.length) : null;
  }
}

enum Role {
  organizer('org', 'Organizer'),
  sweeper('swp', 'Sweeper'),
  runner('run', 'Runner');

  const Role(this.code, this.label);
  final String code;
  final String label;

  static Role fromCode(String? code) =>
      values.firstWhere((r) => r.code == code, orElse: () => Role.runner);
}

enum RunnerStatus {
  ok('ok'),
  offRoute('off'),
  wrongWay('wrong'),
  sos('sos'),
  finished('done'),
  left('left');

  const RunnerStatus(this.code);
  final String code;

  static RunnerStatus fromCode(String? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => RunnerStatus.ok);
}

/// A breadcrumb recorded between two reports.
class TrailPoint {
  const TrailPoint(this.lat, this.lon, this.time);
  final double lat;
  final double lon;
  final DateTime time;
}

/// Periodic location report from one participant.
class PositionReport {
  const PositionReport({
    required this.id,
    required this.name,
    required this.role,
    required this.time,
    required this.lat,
    required this.lon,
    required this.status,
    this.accuracy,
    this.elevation,
    this.speed,
    this.along,
    this.offBy,
    this.battery,
    this.trail = const [],
  });

  final String id;
  final String name;
  final Role role;
  final DateTime time;
  final double lat;
  final double lon;
  final RunnerStatus status;
  final double? accuracy;
  final double? elevation;

  /// Ground speed in m/s.
  final double? speed;

  /// Progress along the shared route (m).
  final double? along;

  /// Distance from the route (m).
  final double? offBy;

  /// Battery level 0-100.
  final int? battery;

  /// Points recorded since the previous report (oldest first), so the
  /// organizer can see the path taken even across a connectivity gap.
  final List<TrailPoint> trail;

  GeoPoint get point => GeoPoint(lat, lon, elevation);

  Map<String, Object?> toJson() => {
    't': 'pos',
    'id': id,
    'n': name,
    'r': role.code,
    'ts': time.millisecondsSinceEpoch,
    'la': _r6(lat),
    'lo': _r6(lon),
    's': status.code,
    if (accuracy != null) 'ac': accuracy!.round(),
    if (elevation != null) 'el': elevation!.round(),
    if (speed != null) 'sp': _r1(speed!),
    if (along != null) 'al': along!.round(),
    if (offBy != null) 'of': offBy!.round(),
    if (battery != null) 'b': battery,
    if (trail.isNotEmpty)
      'tr': [
        for (final p in trail)
          [
            _r6(p.lat),
            _r6(p.lon),
            (time.difference(p.time).inMilliseconds / 1000).round(),
          ],
      ],
  };

  static PositionReport? fromJson(Object? json) {
    if (json is! Map || json['t'] != 'pos') return null;
    try {
      final time = DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num).toInt(),
      );
      return PositionReport(
        id: json['id'] as String,
        name: json['n'] as String? ?? 'Runner',
        role: Role.fromCode(json['r'] as String?),
        time: time,
        lat: (json['la'] as num).toDouble(),
        lon: (json['lo'] as num).toDouble(),
        status: RunnerStatus.fromCode(json['s'] as String?),
        accuracy: (json['ac'] as num?)?.toDouble(),
        elevation: (json['el'] as num?)?.toDouble(),
        speed: (json['sp'] as num?)?.toDouble(),
        along: (json['al'] as num?)?.toDouble(),
        offBy: (json['of'] as num?)?.toDouble(),
        battery: (json['b'] as num?)?.toInt(),
        trail: [
          for (final p in (json['tr'] as List? ?? const []).cast<List>())
            TrailPoint(
              (p[0] as num).toDouble(),
              (p[1] as num).toDouble(),
              time.subtract(Duration(seconds: (p[2] as num).toInt())),
            ),
        ],
      );
    } on Object {
      return null;
    }
  }
}

/// Event details published (retained) by the organizer.
class EventInfo {
  const EventInfo({
    required this.name,
    required this.organizerId,
    required this.organizerName,
    required this.updated,
    this.organizerPhone,
    this.route,
  });

  final String name;
  final String organizerId;
  final String organizerName;

  /// Optional phone number shown to runners for SOS calls/SMS.
  final String? organizerPhone;
  final DateTime updated;
  final TrailRoute? route;

  Map<String, Object?> toJson() => {
    't': 'event',
    'n': name,
    'oi': organizerId,
    'on': organizerName,
    if (organizerPhone != null && organizerPhone!.isNotEmpty)
      'op': organizerPhone,
    'u': updated.millisecondsSinceEpoch,
    if (route != null) 'rt': route!.toShareJson(),
  };

  static EventInfo? fromJson(Object? json) {
    if (json is! Map || json['t'] != 'event') return null;
    try {
      return EventInfo(
        name: json['n'] as String? ?? 'Group run',
        organizerId: json['oi'] as String,
        organizerName: json['on'] as String? ?? 'Organizer',
        organizerPhone: json['op'] as String?,
        updated: DateTime.fromMillisecondsSinceEpoch(
          (json['u'] as num).toInt(),
        ),
        route: json['rt'] is Map
            ? TrailRoute.fromShareJson(
                (json['rt'] as Map).cast<String, Object?>(),
              )
            : null,
      );
    } on Object {
      return null;
    }
  }
}

/// A short broadcast message from the organizer ("Regroup at the hut").
class Announcement {
  const Announcement({
    required this.id,
    required this.from,
    required this.text,
    required this.time,
  });

  final String id;
  final String from;
  final String text;
  final DateTime time;

  Map<String, Object?> toJson() => {
    't': 'msg',
    'id': id,
    'f': from,
    'x': text,
    'ts': time.millisecondsSinceEpoch,
  };

  static Announcement? fromJson(Object? json) {
    if (json is! Map || json['t'] != 'msg') return null;
    try {
      return Announcement(
        id: json['id'] as String,
        from: json['f'] as String? ?? 'Organizer',
        text: json['x'] as String,
        time: DateTime.fromMillisecondsSinceEpoch((json['ts'] as num).toInt()),
      );
    } on Object {
      return null;
    }
  }
}

double _r6(double v) => (v * 1e6).round() / 1e6;
double _r1(double v) => (v * 10).round() / 10;
