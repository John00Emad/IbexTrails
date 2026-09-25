import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/geo.dart';
import 'package:ibex_trails/core/route.dart';
import 'package:ibex_trails/core/turns.dart';

import '../helpers.dart';

TrailRoute route(List<GeoPoint> pts) =>
    TrailRoute.fromPoints('t', pts, simplifyTolerance: 0.5);

void main() {
  test('a right-angle turn is found, on the right side, at the corner', () {
    // 1 km east, then 1 km south (a right turn when heading east).
    final r = route([
      ...eastLine(1000),
      for (var n = -50.0; n >= -1000; n -= 50) offset(n, 1000),
    ]);
    final turns = detectTurns(r);
    expect(turns, hasLength(1));
    final t = turns.single;
    expect(t.along, closeTo(1000, 15));
    expect(t.isRight, isTrue);
    expect(t.kind, TurnKind.turn);
    expect(t.change, closeTo(90, 10));
    expect(t.label, 'Turn right');
    expect(t.spoken(58), 'Turn right in 60 metres');
  });

  test('left, sharp and slight turns are classified', () {
    // East, then sharp back to the north-west (135 deg left).
    final sharp = route([
      ...eastLine(1000),
      for (var d = 50.0; d <= 1000; d += 50)
        offset(d * math.sqrt1_2, 1000 - d * math.sqrt1_2),
    ]);
    final t = detectTurns(sharp).single;
    expect(t.isRight, isFalse);
    expect(t.kind, TurnKind.sharp);
    expect(t.label, 'Sharp left');

    // East, then 45 deg left.
    final slight = route([
      ...eastLine(1000),
      for (var d = 50.0; d <= 1000; d += 50)
        offset(d * math.sqrt1_2, 1000 + d * math.sqrt1_2),
    ]);
    expect(detectTurns(slight).single.kind, TurnKind.slight);
  });

  test('a gentle curve is not a turn', () {
    // Quarter circle of radius 2 km: the heading changes ~1.7 deg per 60 m.
    final r = route([
      for (var a = 0.0; a <= 90; a += 1)
        offset(
          2000 * math.sin(a * math.pi / 180),
          2000 - 2000 * math.cos(a * math.pi / 180),
        ),
    ]);
    expect(detectTurns(r), isEmpty);
  });

  test('the turnaround of an out-and-back is a u-turn', () {
    final r = route([...eastLine(3000), ...eastLine(3000, north: 5).reversed]);
    final turns = detectTurns(r);
    expect(turns, hasLength(1));
    expect(turns.single.kind, TurnKind.uTurn);
    expect(turns.single.along, closeTo(3000, 20));
  });

  test('a zig-zag climb collapses into one switchbacks cue', () {
    final pts = <GeoPoint>[...eastLine(500)];
    // Six legs of 100 m alternating north-east / north-west.
    var n = 0.0, e = 500.0;
    for (var leg = 0; leg < 6; leg++) {
      final dir = leg.isEven ? 1 : -1;
      for (var s = 10.0; s <= 100; s += 10) {
        pts.add(offset(n + s * 0.6, e + dir * s * 0.8));
      }
      n += 60;
      e += dir * 80;
    }
    pts.addAll([for (var s = 50.0; s <= 800; s += 50) offset(n + s, e)]);
    final turns = detectTurns(route(pts));
    final zig = turns.where((t) => t.kind == TurnKind.switchbacks).toList();
    expect(zig, hasLength(1));
    expect(zig.single.until! - zig.single.along, greaterThan(300));
    expect(zig.single.label, 'Switchbacks');
  });

  test('GPS-noise wiggles on a straight trail are ignored', () {
    final rng = math.Random(1);
    final r = route([
      for (var e = 0.0; e <= 3000; e += 8)
        offset((rng.nextDouble() - 0.5) * 6, e),
    ]);
    expect(detectTurns(r), isEmpty);
  });

  test('next turn ahead of the runner', () {
    final r = route([
      ...eastLine(1000),
      for (var n = -50.0; n >= -1000; n -= 50) offset(n, 1000),
    ]);
    final turns = detectTurns(r);
    expect(findNextTurn(turns, 400)!.distance, closeTo(600, 15));
    expect(findNextTurn(turns, 1100), isNull);
    expect(detectTurns(route(eastLine(100))), isEmpty);
  });
}
