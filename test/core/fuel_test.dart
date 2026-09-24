import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/fuel.dart';

void main() {
  final t0 = DateTime(2026, 10, 2, 6);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
  FuelItem item(String id) => defaultFuelItems.firstWhere((i) => i.id == id);

  test('first reminder after the settle-in period, then every interval', () {
    final coach = FuelCoach(
      plan: const FuelPlan(
        carbsPerHour: 60,
        intervalMin: 20,
        firstAfterMin: 30,
      ),
      log: FuelLog(),
      start: t0,
    );
    expect(coach.due(at(29)), isNull);
    final r = coach.due(at(30))!;
    // 30 min at 60 g/h = 30 g, capped at 1.5 x 20 g = 30 g.
    expect(r.carbs, closeTo(30, 0.01));
    expect(r.title, 'Fuel time');
    expect(coach.nextAt, at(50));
    expect(coach.due(at(40)), isNull);
  });

  test('catch-up is capped at 1.5x a normal serving', () {
    final coach = FuelCoach(
      plan: const FuelPlan(
        carbsPerHour: 90,
        intervalMin: 20,
        firstAfterMin: 90,
      ),
      log: FuelLog(),
      start: t0,
    );
    // 90 min with nothing eaten = 135 g behind, but at most 45 g now.
    expect(coach.carbDeficitAt(at(90)), closeTo(135, 0.01));
    expect(coach.due(at(90))!.carbs, closeTo(45, 0.01));
  });

  test('stays quiet when the runner is on plan', () {
    final log = FuelLog();
    final coach = FuelCoach(
      plan: const FuelPlan(
        carbsPerHour: 60,
        fluidMlPerHour: 0,
        intervalMin: 20,
        firstAfterMin: 30,
      ),
      log: log,
      start: t0,
    );
    log.add(FuelEntry.of(item('gel'), at(15)));
    log.add(FuelEntry.of(item('gel'), at(25)));
    expect(coach.due(at(30)), isNull, reason: '50 g eaten, 30 g needed');
    expect(coach.nextAt, at(50), reason: 'schedule still advances');
    expect(coach.due(at(50)), isNull, reason: 'exactly on plan at 50 min');
    final r = coach.due(at(70))!;
    expect(r.carbs, closeTo(20, 0.01));
  });

  test('suggestions add up to the amount without overshooting much', () {
    final coach = FuelCoach(plan: const FuelPlan(), log: FuelLog(), start: t0);
    List<(String, int)> s(double g) => [
      for (final (i, n) in coach.suggest(g)) (i.id, n),
    ];
    expect(s(25), [('gel', 1)]);
    expect(s(45), [('banana', 1), ('date', 1)]);
    expect(s(8), [('chew', 1)]);
    expect(s(3), isEmpty);
    // Never more than 4 servings.
    final big = coach.suggest(500);
    expect(big.fold<int>(0, (a, e) => a + e.$2), 4);
  });

  test('hot day raises fluid targets and reminders mention drinking', () {
    final coach = FuelCoach(
      plan: const FuelPlan(
        carbsPerHour: 0,
        fluidMlPerHour: 500,
        hotDay: true,
        firstAfterMin: 20,
      ),
      log: FuelLog(),
      start: t0,
    );
    expect(coach.fluidTargetAt(at(60)), closeTo(750, 0.01));
    final r = coach.due(at(20))!;
    expect(r.carbs, 0);
    expect(r.fluidMl, closeTo(250, 0.01));
    expect(r.body, contains('ml to drink'));
  });

  test('a reminder waits for an aid station a few minutes ahead', () {
    final coach = FuelCoach(plan: const FuelPlan(), log: FuelLog(), start: t0);
    final stop = UpcomingStop('CP2 Wadi Hof', at(36));
    expect(coach.due(at(30), stop: stop), isNull);
    expect(coach.nextAt, at(36));
    final r = coach.due(at(36), stop: UpcomingStop('CP2 Wadi Hof', at(36)))!;
    expect(r.stop, 'CP2 Wadi Hof');
    expect(r.title, 'Fuel & refill at CP2 Wadi Hof');
  });

  test('never postpones more than 10 minutes for a stop', () {
    final coach = FuelCoach(plan: const FuelPlan(), log: FuelLog(), start: t0);
    expect(coach.due(at(30), stop: UpcomingStop('A', at(38))), isNull);
    // Runner slowed down; the stop keeps being "8 minutes away".
    expect(coach.due(at(38), stop: UpcomingStop('A', at(46))), isNotNull);
  });

  test('snooze and undo', () {
    final log = FuelLog();
    final coach = FuelCoach(plan: const FuelPlan(), log: log, start: t0);
    expect(coach.due(at(30)), isNotNull);
    coach.snooze(at(31), const Duration(minutes: 5));
    expect(coach.nextAt, at(36));
    log.add(FuelEntry.of(item('gel'), at(32)));
    expect(log.carbs, 25);
    expect(log.undo()!.itemId, 'gel');
    expect(log.carbs, 0);
  });

  test('plan and log JSON round trip', () {
    final plan = const FuelPlan(carbsPerHour: 75, hotDay: true).copyWith(
      items: [
        ...defaultFuelItems,
        const FuelItem(id: 'x', name: 'Koshari bar', carbs: 40, sodiumMg: 200),
      ],
    );
    final copy = FuelPlan.fromJson(plan.toJson());
    expect(copy.carbsPerHour, 75);
    expect(copy.hotDay, isTrue);
    expect(copy.item('x')!.carbs, 40);
    final log = FuelLog()..add(FuelEntry.of(copy.item('x')!, at(10)));
    final logCopy = FuelLog.fromJson(log.toJson());
    expect(logCopy.carbs, 40);
    expect(logCopy.sodiumMg, 200);
    expect(logCopy.entries.single.time, at(10));
  });

  test('guidance by duration', () {
    expect(FuelPlan.guidance(const Duration(minutes: 60)), contains('0–30'));
    expect(FuelPlan.guidance(const Duration(hours: 2)), contains('30–60'));
    expect(FuelPlan.guidance(const Duration(hours: 5)), contains('60–90'));
  });
}
