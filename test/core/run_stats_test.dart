import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/run_stats.dart';

import '../helpers.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 3, 6);

  test('steady 5:00/km: distance, time, pace and km splits', () {
    // 3.5 km east, a point every 50 m and 15 s.
    final pts = eastLine(3500);
    final times = [
      for (var i = 0; i < pts.length; i++) t0.add(Duration(seconds: 15 * i)),
    ];
    final s = RunStats.of(pts, times);
    expect(s.distance, closeTo(3500, 1));
    expect(s.elapsed, const Duration(seconds: 15 * 70));
    expect(s.moving, s.elapsed);
    expect(s.pace!.inMilliseconds, closeTo(300000, 500));
    expect(s.splits, hasLength(3));
    for (final split in s.splits) {
      expect(split.inMilliseconds, closeTo(300000, 500));
    }
  });

  test('a stop counts in the time but not the moving time', () {
    // 2.1 km, a point every 100 m and 30 s, with a 10 minute stop at 1 km.
    final pts = eastLine(2100, step: 100);
    final times = <DateTime>[];
    var t = t0;
    for (var i = 0; i < pts.length; i++) {
      times.add(t);
      t = t.add(Duration(seconds: i == 10 ? 630 : 30));
    }
    final s = RunStats.of(pts, times);
    expect(s.elapsed, const Duration(seconds: 20 * 30 + 630));
    expect(s.moving, const Duration(seconds: 20 * 30));
    expect(s.splits, hasLength(2));
    expect(s.splits.first.inMilliseconds, closeTo(300000, 500));
    expect(s.splits.last.inMilliseconds, closeTo(900000, 500));
  });

  test('without times there is only distance and climbing', () {
    final s = RunStats.of(
      [offset(0, 0, 100), offset(0, 500, 150), offset(0, 1000, 120)],
      const [null, null, null],
    );
    expect(s.distance, closeTo(1000, 1));
    expect(s.ascent, 50);
    expect(s.descent, 30);
    expect(s.elapsed, isNull);
    expect(s.moving, isNull);
    expect(s.pace, isNull);
    expect(s.splits, isEmpty);
  });

  test('a run nobody named is named after the time of day', () {
    expect(defaultRunName(DateTime(2026, 10, 3, 6, 15)), 'Morning run');
    expect(defaultRunName(DateTime(2026, 10, 3, 13)), 'Afternoon run');
    expect(defaultRunName(DateTime(2026, 10, 3, 18, 30)), 'Evening run');
    expect(defaultRunName(DateTime(2026, 10, 3, 23)), 'Night run');
    expect(defaultRunName(DateTime(2026, 10, 3, 2)), 'Night run');
  });
}
