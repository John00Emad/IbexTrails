import 'geo.dart';
import 'route.dart';

enum TurnKind {
  slight('Slight'),
  turn('Turn'),
  sharp('Sharp'),
  uTurn('U-turn'),

  /// Several turns close together, announced once.
  switchbacks('Switchbacks');

  const TurnKind(this.label);
  final String label;
}

/// A change of direction along a route, found from the route's shape.
class Turn {
  const Turn({
    required this.id,
    required this.along,
    required this.change,
    required this.kind,
    this.until,
  });

  final int id;

  /// Distance from the start where the turn happens (m).
  final double along;

  /// Change of heading in degrees: positive turns right, negative left.
  final double change;
  final TurnKind kind;

  /// For switchbacks: where the last turn of the group is.
  final double? until;

  bool get isRight => change > 0;

  /// "Sharp left", "Turn right", "U-turn", "Switchbacks".
  String get label => switch (kind) {
    TurnKind.uTurn || TurnKind.switchbacks => kind.label,
    TurnKind.turn => 'Turn ${isRight ? 'right' : 'left'}',
    _ => '${kind.label} ${isRight ? 'right' : 'left'}',
  };

  /// What to say [distance] metres before it.
  String spoken(double distance) {
    final metres = (distance / 10).round() * 10;
    if (kind == TurnKind.switchbacks) {
      return 'Switchbacks ahead in $metres metres';
    }
    return '$label in $metres metres';
  }
}

/// The next turn ahead of the runner.
class UpcomingTurn {
  const UpcomingTurn(this.turn, this.distance);
  final Turn turn;
  final double distance;
}

const _step = 10.0;
const _arm = 30.0;
const _minChange = 40.0;

TurnKind _kindOf(double change) {
  final a = change.abs();
  if (a >= 150) return TurnKind.uTurn;
  if (a >= 110) return TurnKind.sharp;
  if (a >= 60) return TurnKind.turn;
  return TurnKind.slight;
}

double _signedDelta(double from, double to) {
  var d = (to - from) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// Finds turns by comparing the heading 30 m before and 30 m after points
/// every 10 m along the route. Small wiggles (GPS noise, gentle bends) are
/// ignored; 3 or more turns in quick succession become one "switchbacks"
/// cue so a zig-zag climb doesn't buzz every few seconds.
List<Turn> detectTurns(TrailRoute route) {
  final length = route.length;
  if (length < 150) return const [];

  // 1. Candidate points where the heading changes a lot.
  final candidates = <(double along, double change)>[];
  for (var d = 50.0; d <= length - 50; d += _step) {
    final a = route.pointAt(d - _arm);
    final b = route.pointAt(d);
    final c = route.pointAt(d + _arm);
    if (distanceBetween(a, b) < _arm / 3 || distanceBetween(b, c) < _arm / 3) {
      continue;
    }
    final change = _signedDelta(bearingBetween(a, b), bearingBetween(b, c));
    if (change.abs() >= _minChange) candidates.add((d, change));
  }

  // 2. Each run of neighbouring candidates in the same direction is one
  // turn, located at its strongest point.
  final peaks = <(double, double)>[];
  var previous = double.negativeInfinity;
  for (final c in candidates) {
    final last = peaks.isEmpty ? null : peaks.last;
    final sameRun =
        last != null &&
        c.$1 - previous <= _step * 2.5 &&
        (c.$2 > 0) == (last.$2 > 0);
    if (sameRun) {
      if (c.$2.abs() > last.$2.abs()) peaks.last = c;
    } else {
      peaks.add(c);
    }
    previous = c.$1;
  }

  // 3. Turns closer than 60 m are one manoeuvre: keep the stronger.
  final merged = <(double, double)>[];
  for (final p in peaks) {
    if (merged.isNotEmpty && p.$1 - merged.last.$1 < 60) {
      if (p.$2.abs() > merged.last.$2.abs()) merged.last = p;
    } else {
      merged.add(p);
    }
  }

  // 4. Collapse chains of 3+ turns less than 150 m apart into switchbacks.
  final out = <Turn>[];
  var i = 0;
  while (i < merged.length) {
    var j = i;
    while (j + 1 < merged.length && merged[j + 1].$1 - merged[j].$1 <= 150) {
      j++;
    }
    if (j - i >= 2) {
      out.add(
        Turn(
          id: out.length,
          along: merged[i].$1,
          change: merged[i].$2,
          kind: TurnKind.switchbacks,
          until: merged[j].$1,
        ),
      );
    } else {
      for (var k = i; k <= j; k++) {
        out.add(
          Turn(
            id: out.length,
            along: merged[k].$1,
            change: merged[k].$2,
            kind: _kindOf(merged[k].$2),
          ),
        );
      }
    }
    i = j + 1;
  }
  return out;
}

/// The first turn ahead of [along] (a switchbacks group counts until the
/// runner reaches it).
UpcomingTurn? findNextTurn(List<Turn> turns, double along) {
  for (final t in turns) {
    if (t.along > along) return UpcomingTurn(t, t.along - along);
  }
  return null;
}
