import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/pacer.dart';
import 'package:ibex_trails/core/route.dart';

import '../helpers.dart';

final _t0 = DateTime(2026, 10, 18, 7);

/// Pace range 6:00–7:00 /km: the virtual runner goes at 6:30.
const _plan = PacerPlan(enabled: true, fastest: 360, slowest: 420);

/// A runner with a GPS fix every 2 s, as on Android.
class _Runner {
  _Runner(this.pacer);
  final VirtualPacer pacer;
  DateTime time = _t0;
  double distance = 0;
  final cues = <PacerCue>[];

  Duration get elapsed => time.difference(_t0);

  /// Runs at [pace] (s/km) for [seconds]. Along the route, if there is one,
  /// [distance] is how far along it.
  void run(double pace, int seconds, {bool quiet = false}) {
    final speed = 1000 / pace;
    for (var i = 0; i < seconds; i += 2) {
      time = time.add(const Duration(seconds: 2));
      distance += speed * 2;
      final cue = pacer.addFix(
        time,
        distance: distance,
        speed: speed,
        along: pacer.route == null ? null : distance,
        quiet: quiet,
      );
      if (cue != null) cues.add(cue);
    }
  }

  /// Stands still for [seconds]: no fixes, only the session's clock.
  void stand(int seconds) {
    for (var i = 0; i < seconds; i += 10) {
      time = time.add(const Duration(seconds: 10));
      pacer.tick(time);
    }
  }

  List<String> get heard => [for (final c in cues) c.title];
}

/// 2 km flat, then 1 km climbing 100 m (10%), then 1 km flat on top.
TrailRoute _hill() => TrailRoute.fromPoints('Hill', [
  for (var e = 0.0; e <= 4000; e += 50)
    offset(
      0,
      e,
      e <= 2000
          ? 100
          : e <= 3000
          ? 100 + (e - 2000) / 10
          : 200,
    ),
]);

void main() {
  group('plan', () {
    test('JSON round trip', () {
      const plan = PacerPlan(
        enabled: true,
        fastest: 330,
        slowest: 350,
        hills: false,
        voice: false,
      );
      final copy = PacerPlan.fromJson(plan.toJson());
      expect(copy.enabled, isTrue);
      expect(copy.fastest, 330);
      expect(copy.slowest, 350);
      expect(copy.hills, isFalse);
      expect(copy.voice, isFalse);
      expect(copy.target, 340);
    });

    test('defaults: off, 6:00–7:00, hills and voice on', () {
      final plan = PacerPlan.fromJson(const {});
      expect(plan.enabled, isFalse);
      expect((plan.fastest, plan.slowest), (360, 420));
      expect(plan.hills, isTrue);
      expect(plan.voice, isTrue);
    });

    test('a stored range is kept in order and within limits', () {
      final swapped = PacerPlan.fromJson(const {'fast': 400, 'slow': 300});
      expect((swapped.fastest, swapped.slowest), (300, 400));
      final wild = PacerPlan.fromJson(const {'fast': 10, 'slow': 99999});
      expect((wild.fastest, wild.slowest), (180, 900));
    });
  });

  test('paces are shown as m:ss and said in words', () {
    expect(formatPace(330), '5:30');
    expect(formatPace(359.6), '6:00');
    expect(spokenPace(330), '5 minutes 30 seconds');
    expect(spokenPace(360), '6 minutes');
    expect(spokenPace(61), '1 minute 1 second');
    const cue = PacerCue(PaceZone.tooFast, 310);
    expect(cue.title, 'Too fast');
    expect(
      cue.spoken,
      'Too fast: 5 minutes 10 seconds per kilometre. Ease off.',
    );
    expect(
      const PacerCue(PaceZone.tooSlow, 455).spoken,
      'Too slow: 7 minutes 35 seconds per kilometre. Pick it up.',
    );
    expect(const PacerCue(PaceZone.onPace, 380).title, 'Back on pace');
  });

  group('pace', () {
    test('counts after 20 s of running, averaged over the last minute', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 18);
      expect(r.pacer.pace, isNull, reason: 'just started');
      r.run(390, 4);
      expect(r.pacer.pace, closeTo(390, 0.5));
      expect(r.pacer.zone, PaceZone.onPace);
      // Speeding up to 5:00 shows gradually, over a minute.
      r.run(300, 30);
      expect(r.pacer.pace, inExclusiveRange(300, 390));
      r.run(300, 40);
      expect(r.pacer.pace, closeTo(300, 0.5));
    });

    test('stops and starts afresh after standing still', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      expect(r.pacer.stopped, isFalse);
      r.stand(10);
      expect(r.pacer.stopped, isTrue);
      expect(r.pacer.pace, isNull);
      expect(r.pacer.zone, isNull);
      // Running again: the stop isn't averaged in, and it takes a moment.
      r.run(390, 10);
      expect(r.pacer.stopped, isFalse);
      expect(r.pacer.pace, isNull);
      r.run(390, 12);
      expect(r.pacer.pace, closeTo(390, 0.5));
    });

    test('slowing to a walk for a few seconds is not a stop', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(3000, 6);
      expect(r.pacer.stopped, isFalse);
      expect(r.pacer.pace, isNotNull);
    });

    test('without GPS speed, the pace comes from the distance run', () {
      final pacer = VirtualPacer(plan: _plan);
      var t = _t0;
      for (var d = 6.0; d <= 300; d += 6) {
        t = t.add(const Duration(seconds: 2));
        pacer.addFix(t, distance: d);
      }
      expect(pacer.pace, closeTo(1000 / 3, 0.5));
    });
  });

  group('cues', () {
    test('none while on pace', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(380, 600);
      expect(r.cues, isEmpty);
    });

    test('too fast after 15 s out of the range, then every 3 min', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(300, 20);
      expect(r.pacer.zone, PaceZone.onPace, reason: 'the minute lags');
      r.run(300, 10);
      // The minute's average left the range a few seconds ago: not long
      // enough yet.
      expect(r.pacer.zone, PaceZone.tooFast);
      expect(r.cues, isEmpty);
      r.run(300, 10);
      expect(r.heard, ['Too fast']);
      expect(r.cues.single.pace, inInclusiveRange(300, 360 * 0.98));
      r.run(300, 150);
      expect(r.heard, ['Too fast'], reason: 'reminder only after 3 min');
      r.run(300, 30);
      expect(r.heard, ['Too fast', 'Too fast']);
    });

    test('back on pace once in the range for 10 s', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(480, 90);
      expect(r.heard, ['Too slow']);
      r.run(390, 60);
      expect(r.heard, ['Too slow', 'Back on pace']);
      r.run(390, 300);
      expect(r.heard, ['Too slow', 'Back on pace']);
    });

    test('a short surge says nothing', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(240, 10);
      r.run(390, 120);
      expect(r.cues, isEmpty);
    });

    test('just past the edge of the range is still on pace', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(425, 300);
      expect(r.pacer.zone, PaceZone.onPace);
      expect(r.cues, isEmpty);
      r.run(435, 60);
      expect(r.heard, ['Too slow']);
      // Not back on pace until inside the range, not just inside the margin.
      r.run(425, 100);
      expect(r.pacer.zone, PaceZone.tooSlow);
      expect(r.heard, ['Too slow']);
      r.run(410, 60);
      expect(r.heard, ['Too slow', 'Back on pace']);
    });

    test('quiet holds cues back until it is over', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(480, 120, quiet: true);
      expect(r.cues, isEmpty);
      r.run(480, 2);
      expect(r.heard, ['Too slow']);
    });

    test('a stop starts afresh: no "back on pace" after it', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 60);
      r.run(480, 90);
      expect(r.heard, ['Too slow']);
      r.stand(60);
      r.run(390, 120);
      expect(r.heard, ['Too slow']);
    });
  });

  group('hills', () {
    test('a 10% climb doubles the range, as in km-effort', () {
      final r = _Runner(VirtualPacer(plan: _plan, route: _hill()));
      r.run(390, 2000 * 390 ~/ 1000);
      expect(r.pacer.climbFactor, closeTo(1, 0.01));
      // 13:00 /km up the climb is 6:30 per km-effort.
      r.run(780, 300);
      expect(r.pacer.climbFactor, closeTo(2, 0.05));
      final (lo, hi) = r.pacer.range;
      expect(lo, closeTo(720, 20));
      expect(hi, closeTo(840, 20));
      expect(r.pacer.zone, PaceZone.onPace);
      expect(r.cues, isEmpty);
    });

    test('without hill adjustment the climb is too slow', () {
      final r = _Runner(
        VirtualPacer(plan: _plan.copyWith(hills: false), route: _hill()),
      );
      r.run(390, 2000 * 390 ~/ 1000);
      r.run(780, 120);
      expect(r.pacer.climbFactor, 1);
      expect(r.heard, ['Too slow']);
    });

    test('downhill gets no extra time', () {
      final route = TrailRoute.fromPoints('Down', [
        for (var e = 0.0; e <= 2000; e += 50) offset(0, e, 300 - e / 10),
      ]);
      final r = _Runner(VirtualPacer(plan: _plan, route: route));
      r.run(390, 300);
      expect(r.pacer.climbFactor, 1);
    });
  });

  group('virtual runner', () {
    test('sets off when you start running and goes at mid-range', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.stand(120);
      expect(r.pacer.anchor, isNull, reason: 'not running yet');
      expect(r.pacer.gap, isNull);
      r.run(390, 30);
      expect(r.pacer.anchor!.time, _t0.add(const Duration(seconds: 122)));
      expect(r.pacer.gap!.inSeconds.abs(), lessThanOrEqualTo(1));
      // 10 s/km faster than the pacer over 3 km: 30 s ahead, about 80 m.
      r.run(380, 3 * 380 - 30);
      expect(r.pacer.gap!.inSeconds, closeTo(30, 2));
      expect(r.pacer.lead, closeTo(80, 6));
      expect(r.pacer.ghostAlong, isNull, reason: 'no route');
    });

    test('overall: ahead of the fastest pace, in the range, or behind', () {
      final fast = _Runner(VirtualPacer(plan: _plan))..run(300, 600);
      expect(fast.pacer.schedule, PaceZone.tooFast);
      // Early on, a few seconds either way don't count.
      final early = _Runner(VirtualPacer(plan: _plan))..run(300, 30);
      expect(early.pacer.gap!.inSeconds, inInclusiveRange(1, 9));
      expect(early.pacer.schedule, PaceZone.onPace);
      final r = _Runner(VirtualPacer(plan: _plan))..run(390, 600);
      expect(r.pacer.schedule, PaceZone.onPace);
      // Two minutes at an aid station drop it behind 7:00 /km overall.
      r.stand(120);
      expect(r.pacer.schedule, PaceZone.tooSlow);
    });

    test('keeps going while you stop', () {
      final r = _Runner(VirtualPacer(plan: _plan));
      r.run(390, 600);
      final before = r.pacer.gap!;
      r.stand(60);
      expect((before - r.pacer.gap!).inSeconds, closeTo(60, 1));
    });

    test('on a route: slower up the climb, by km-effort', () {
      final route = _hill();
      final r = _Runner(VirtualPacer(plan: _plan, route: route));
      // Exactly at the pacer's effort: 6:30 on the flat, 13:00 up 10%.
      r.run(390, 2000 * 390 ~/ 1000);
      r.run(780, 1000 * 780 ~/ 1000);
      expect(r.pacer.gap!.inSeconds.abs(), lessThanOrEqualTo(3));
      expect(r.pacer.ghostAlong, closeTo(r.distance, 10));
      // Without hill adjustment the pacer would be far ahead by now.
      r.pacer.plan = _plan.copyWith(hills: false);
      expect(r.pacer.gap!.inSeconds, lessThan(-350));
      expect(r.pacer.ghostAlong, greaterThan(r.distance + 900));
    });

    test('starts at the race start time, from the start of the route', () {
      final pacer = VirtualPacer(plan: _plan, route: _hill())
        ..raceStart = _t0.add(const Duration(minutes: 1));
      final r = _Runner(pacer);
      // On the start line, waiting for the gun.
      pacer.addFix(r.time, distance: 0, speed: 0, along: 0);
      r.stand(30);
      expect(pacer.gap, isNull, reason: 'before the start');
      expect(pacer.ghostAlong, isNull);
      r.stand(60);
      // Not off the line yet, 30 s after the gun.
      expect(pacer.gap!.inSeconds, -30);
      expect(pacer.ghostAlong, closeTo(30 / 390 * 1000, 1));
      r.run(390, 60);
      expect(pacer.gap!.inSeconds, closeTo(-30, 1));
    });

    test('quiet while warming up before the race start', () {
      final pacer = VirtualPacer(plan: _plan, route: _hill())
        ..raceStart = _t0.add(const Duration(minutes: 10));
      final r = _Runner(pacer)..run(600, 300);
      expect(pacer.zone, PaceZone.tooSlow);
      expect(r.cues, isEmpty);
      // The gun: still jogging, so now it says so.
      r.run(600, 330);
      expect(r.heard, ['Too slow']);
    });

    test('restart: from here while running, else at the next start', () {
      final pacer = VirtualPacer(plan: _plan, route: _hill())..raceStart = _t0;
      final r = _Runner(pacer);
      r.stand(60);
      r.run(390, 120);
      expect(pacer.gap!.inSeconds, closeTo(-60, 1));
      pacer.restart(r.time);
      expect(pacer.anchor!.time, r.time);
      expect(pacer.gap, Duration.zero);
      r.run(380, 380);
      expect(pacer.gap!.inSeconds, closeTo(10, 1));

      r.stand(30);
      pacer.restart(r.time);
      expect(pacer.anchor, isNull);
      r.stand(30);
      r.run(390, 30);
      expect(pacer.anchor!.time, r.time.subtract(const Duration(seconds: 28)));
    });

    test('stops at the finish', () {
      final pacer = VirtualPacer(plan: _plan, route: _hill());
      final r = _Runner(pacer);
      r.run(380, 600);
      final at = r.time.add(const Duration(seconds: 2));
      pacer.addFix(at, distance: r.distance, along: r.distance, finished: true);
      final gap = pacer.gap;
      expect(pacer.finished, isTrue);
      r.run(600, 300);
      r.stand(300);
      expect(pacer.gap, gap);
      expect(r.cues, isEmpty);
    });

    test('carries on after the app restarts', () {
      final route = _hill();
      final r = _Runner(VirtualPacer(plan: _plan, route: route));
      r.run(390, 300);
      final saved = r.pacer.toJson()!;
      final again = VirtualPacer(plan: _plan, route: route)..restore(saved);
      expect(again.anchor!.time, r.pacer.anchor!.time);
      expect(again.anchor!.progress, r.pacer.anchor!.progress);
      expect(VirtualPacer(plan: _plan).toJson(), isNull);
    });

    test('another route starts it again', () {
      final pacer = VirtualPacer(plan: _plan, route: _hill());
      final r = _Runner(pacer);
      r.run(390, 300);
      expect(pacer.anchor, isNotNull);
      pacer.route = _hill();
      expect(pacer.anchor, isNull);
      expect(pacer.pace, isNull);
    });
  });
}
