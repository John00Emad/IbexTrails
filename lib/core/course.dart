import 'geo.dart';
import 'route.dart';

enum CheckpointKind {
  checkpoint('cp', 'Checkpoint'),
  water('wt', 'Water point'),
  aid('aid', 'Aid station'),
  medical('med', 'Medical');

  const CheckpointKind(this.code, this.label);
  final String code;
  final String label;

  /// Places where runners can eat or drink.
  bool get refuels => this == water || this == aid;

  static CheckpointKind fromCode(String? code) => values.firstWhere(
    (k) => k.code == code,
    orElse: () => CheckpointKind.checkpoint,
  );

  /// Best guess from a waypoint name, e.g. "Water station 2" -> water.
  static CheckpointKind guess(String name) {
    final n = name.toLowerCase();
    if (n.contains('medic') || n.contains('first aid')) return medical;
    if (n.contains('water') || n.contains('drink')) return water;
    if (n.contains('aid') || n.contains('food') || n.contains('station')) {
      return aid;
    }
    return checkpoint;
  }
}

/// A point on a course that runners are timed through, optionally with a
/// cut-off measured from the course start.
class Checkpoint {
  const Checkpoint({
    required this.id,
    required this.name,
    required this.kind,
    required this.along,
    this.cutoff,
  });

  final String id;
  final String name;
  final CheckpointKind kind;

  /// Distance from the start along the course (m).
  final double along;

  /// Latest allowed arrival, as time since the course start.
  final Duration? cutoff;

  Checkpoint copyWith({
    String? name,
    CheckpointKind? kind,
    double? along,
    Duration? cutoff,
    bool clearCutoff = false,
  }) => Checkpoint(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    along: along ?? this.along,
    cutoff: clearCutoff ? null : (cutoff ?? this.cutoff),
  );

  Map<String, Object?> toJson() => {
    'i': id,
    'n': name,
    'k': kind.code,
    'a': along.round(),
    if (cutoff != null) 'co': cutoff!.inMinutes,
  };

  static Checkpoint fromJson(Map json) => Checkpoint(
    id: json['i'] as String,
    name: json['n'] as String? ?? 'Checkpoint',
    kind: CheckpointKind.fromCode(json['k'] as String?),
    along: (json['a'] as num).toDouble(),
    cutoff: json['co'] == null
        ? null
        : Duration(minutes: (json['co'] as num).toInt()),
  );
}

/// Summary of a course, small enough to list in the event info.
class CourseInfo {
  const CourseInfo({
    required this.id,
    required this.name,
    required this.length,
    required this.ascent,
    this.start,
  });

  final String id;
  final String name;
  final double length;
  final double ascent;
  final DateTime? start;

  Map<String, Object?> toJson() => {
    'i': id,
    'n': name,
    'l': length.round(),
    'u': ascent.round(),
    if (start != null) 's': start!.millisecondsSinceEpoch,
  };

  static CourseInfo fromJson(Map json) => CourseInfo(
    id: json['i'] as String,
    name: json['n'] as String? ?? 'Course',
    length: (json['l'] as num?)?.toDouble() ?? 0,
    ascent: (json['u'] as num?)?.toDouble() ?? 0,
    start: json['s'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['s'] as num).toInt()),
  );
}

/// One distance of an event (e.g. the 25 km of a race with 5/10/25/50 km),
/// with its route, checkpoints and start time.
class Course {
  Course({
    required this.id,
    required this.name,
    required this.route,
    List<Checkpoint> checkpoints = const [],
    this.start,
  }) : checkpoints = List.unmodifiable(
         [...checkpoints]..sort((a, b) => a.along.compareTo(b.along)),
       );

  /// A course made from a route, with its GPX waypoints as checkpoints.
  factory Course.fromRoute(TrailRoute route, {String? id, String? name}) =>
      Course(
        id: id ?? 'c1',
        name: name ?? defaultName(route),
        route: route,
        checkpoints: checkpointsFromWaypoints(route),
      );

  final String id;
  final String name;
  final TrailRoute route;
  final List<Checkpoint> checkpoints;

  /// Scheduled start (wave start). Null for casual runs, in which case
  /// cut-offs count from when each runner starts.
  final DateTime? start;

  CourseInfo get info => CourseInfo(
    id: id,
    name: name,
    length: route.length,
    ascent: route.totalAscent,
    start: start,
  );

  GeoPoint pointOf(Checkpoint cp) => route.pointAt(cp.along);

  /// Cut-off as a clock time, from [start] or else from [runnerStart].
  DateTime? cutoffTime(Checkpoint cp, {DateTime? runnerStart}) {
    final from = start ?? runnerStart;
    if (from == null || cp.cutoff == null) return null;
    return from.add(cp.cutoff!);
  }

  Course copyWith({
    String? name,
    List<Checkpoint>? checkpoints,
    DateTime? start,
    bool clearStart = false,
  }) => Course(
    id: id,
    name: name ?? this.name,
    route: route,
    checkpoints: checkpoints ?? this.checkpoints,
    start: clearStart ? null : (start ?? this.start),
  );

  Map<String, Object?> toShareJson() => {
    'i': id,
    'n': name,
    'r': route.toShareJson(),
    'cp': [for (final c in checkpoints) c.toJson()],
    if (start != null) 's': start!.millisecondsSinceEpoch,
  };

  static Course fromShareJson(Map json) => Course(
    id: json['i'] as String,
    name: json['n'] as String? ?? 'Course',
    route: TrailRoute.fromShareJson((json['r'] as Map).cast<String, Object?>()),
    checkpoints: [
      for (final c in (json['cp'] as List? ?? const []).cast<Map>())
        Checkpoint.fromJson(c),
    ],
    start: json['s'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['s'] as num).toInt()),
  );

  /// "25 km" style name from the route length.
  static String defaultName(TrailRoute route) {
    final km = route.length / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }

  /// Checkpoints from the route's GPX waypoints: one per pass, so a water
  /// point used on the way out and back becomes two timed checkpoints.
  static List<Checkpoint> checkpointsFromWaypoints(TrailRoute route) {
    final found = <(double, String, CheckpointKind)>[];
    for (final w in route.waypoints) {
      for (var i = 0; i < w.passes.length; i++) {
        final name = w.passes.length == 1
            ? w.name
            : '${w.name} (pass ${i + 1})';
        found.add((w.passes[i], name, CheckpointKind.guess(w.name)));
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [
      for (var i = 0; i < found.length; i++)
        Checkpoint(
          id: 'cp${i + 1}',
          name: found[i].$2,
          kind: found[i].$3,
          along: found[i].$1,
        ),
    ];
  }
}
