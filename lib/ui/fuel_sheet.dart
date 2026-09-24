import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/fuel.dart';
import '../state/run_session.dart';
import 'fuel_plan_screen.dart';
import 'group_sheet.dart' show clock;

/// Quick fuel logging during a run. Private to this phone.
Future<void> showFuelSheet(BuildContext context, RunSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: session,
      builder: (context, _) => _FuelSheet(session: session),
    ),
  );
}

class _FuelSheet extends StatelessWidget {
  const _FuelSheet({required this.session});
  final RunSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coach = session.fuel;
    if (coach == null) return const SizedBox(height: 120);
    final now = DateTime.now();
    final plan = coach.plan;
    final log = coach.log;
    final carbTarget = coach.carbTargetAt(now);
    final fluidTarget = coach.fluidTargetAt(now);
    final behind = coach.carbDeficitAt(now);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Fuel',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FuelPlanScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.tune),
                  label: Text('${plan.carbsPerHour.round()} g/h plan'),
                ),
              ],
            ),
            if (!plan.enabled)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Reminders are off. You can still log here.'),
              ),
            _Meter(
              label: 'Carbs',
              value: log.carbs,
              target: carbTarget,
              unit: 'g',
              color: Brand.canyon,
            ),
            const SizedBox(height: 8),
            _Meter(
              label: 'Fluids',
              value: log.fluidMl,
              target: fluidTarget,
              unit: 'ml',
              color: Brand.oasis,
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (behind >= 5)
                  '${behind.round()} g behind plan'
                else if (behind <= -5)
                  '${(-behind).round()} g ahead of plan'
                else
                  'On plan',
                if (log.lastCarbs != null)
                  'last carbs ${clock(log.lastCarbs!)}',
                if (plan.enabled) 'next reminder ${clock(coach.nextAt)}',
                if (log.sodiumMg > 0) 'sodium ${log.sodiumMg.round()} mg',
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              'Tap what you just had',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in plan.items)
                  ActionChip(
                    avatar: Icon(
                      item.isFood ? Icons.bolt : Icons.water_drop,
                      size: 18,
                      color: item.isFood ? Brand.canyon : Brand.oasis,
                    ),
                    label: Text('${item.name} · ${_amount(item)}'),
                    onPressed: () {
                      session.logFuel(item);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Logged ${item.name}'),
                          action: SnackBarAction(
                            label: 'UNDO',
                            onPressed: session.undoFuel,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            if (log.entries.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'This run',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              for (final e in log.entries.reversed.take(6))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text(clock(e.time)),
                  title: Text(e.name),
                  trailing: Text(
                    [
                      if (e.carbs > 0) '${e.carbs.round()} g',
                      if (e.fluidMl > 0) '${e.fluidMl.round()} ml',
                    ].join(' · '),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: session.undoFuel,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo last'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Your fuel log stays on this phone and is never shared.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _amount(FuelItem i) =>
      i.isFood ? '${i.carbs.round()} g' : '${i.fluidMl.round()} ml';
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.label,
    required this.value,
    required this.target,
    required this.unit,
    required this.color,
  });

  final String label;
  final double value;
  final double target;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = target <= 0 ? 1.0 : (value / target).clamp(0.0, 1.0);
    final behind = target > 0 && value < target * 0.75;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            const Spacer(),
            Text(
              target < 1
                  ? '${value.round()} $unit'
                  : '${value.round()} of ${target.round()} $unit',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 10,
            color: behind ? TrailColors.warning : color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
      ],
    );
  }
}
