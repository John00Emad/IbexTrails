import 'package:flutter/material.dart';

import '../app.dart';
import '../core/pacer.dart';

/// The virtual pacer: the pace range to hold in a race, and how to be told
/// when you drift out of it.
class PacerPlanScreen extends StatelessWidget {
  const PacerPlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Virtual pacer')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final plan = settings.pacerPlan;
          void update(PacerPlan p) => settings.pacerPlan = p;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                title: const Text('Virtual pacer'),
                subtitle: const Text(
                  'Runs with you at your race pace, and tells you when your '
                  'pace drifts out of your range.',
                ),
                value: plan.enabled,
                onChanged: (v) => update(plan.copyWith(enabled: v)),
              ),
              _Header(
                'Pace range: ${formatPace(plan.fastest)}–'
                '${formatPace(plan.slowest)} per km',
              ),
              RangeSlider(
                values: RangeValues(
                  plan.fastest.toDouble(),
                  plan.slowest.toDouble(),
                ),
                min: PacerPlan.minPace.toDouble(),
                max: PacerPlan.maxPace.toDouble(),
                divisions: (PacerPlan.maxPace - PacerPlan.minPace) ~/ _step,
                labels: RangeLabels(
                  formatPace(plan.fastest),
                  formatPace(plan.slowest),
                ),
                onChanged: (v) => update(
                  plan.copyWith(
                    fastest: v.start.round(),
                    slowest: v.end.round(),
                  ),
                ),
              ),
              _PaceStepper(
                label: 'Fastest',
                pace: plan.fastest,
                min: PacerPlan.minPace,
                max: plan.slowest,
                onChanged: (v) => update(plan.copyWith(fastest: v)),
              ),
              _PaceStepper(
                label: 'Slowest',
                pace: plan.slowest,
                min: plan.fastest,
                max: PacerPlan.maxPace,
                onChanged: (v) => update(plan.copyWith(slowest: v)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'The pacer runs at ${formatPace(plan.target)} per km, the '
                  'middle of your range, so you can see how far ahead or '
                  'behind it you are.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Adjust for hills'),
                subtitle: const Text(
                  'On a route with elevation, climbs get more time, as '
                  'checkpoint arrival times do: 100 m of climbing counts as '
                  '1 km on the flat.',
                ),
                value: plan.hills,
                onChanged: (v) => update(plan.copyWith(hills: v)),
              ),
              ListTile(
                title: const Text('Average your pace over'),
                subtitle: const Text(
                  'Shorter reacts sooner. Longer ignores GPS wobble in '
                  'canyons and on switchbacks.',
                ),
                trailing: DropdownButton<int>(
                  value: plan.averageSeconds,
                  items: [
                    for (final s in PacerPlan.averageOptions)
                      DropdownMenuItem(value: s, child: Text(averageLabel(s))),
                  ],
                  onChanged: (v) {
                    if (v != null) update(plan.copyWith(averageSeconds: v));
                  },
                ),
              ),
              SwitchListTile(
                title: const Text('Say it out loud'),
                subtitle: const Text(
                  '"Too fast: 5 minutes 10 seconds per kilometre. Ease off." '
                  'The phone buzzes either way.',
                ),
                value: plan.voice,
                onChanged: (v) => update(plan.copyWith(voice: v)),
              ),
              const _Header('How it works'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Text(
                  'Your pace is updated every second or two, averaged over '
                  '${averagePhrase(plan.averageSeconds)}, so a short surge '
                  'doesn\'t count. Out of the range for 15 seconds, '
                  'you are told, and reminded every 3 minutes until you are '
                  'back on pace. The pacer is quiet while you stop, near '
                  'turns and off route.\n\n'
                  'It sets off when you start running, or at the race start '
                  'if the organizer set one. To start it again from where '
                  'you are, tap the pacer line under the map.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "5:30–6:30 per km · voice cues", or "Off".
String describePacer(PacerPlan plan) {
  if (!plan.enabled) return 'Off';
  return '${formatPace(plan.fastest)}–${formatPace(plan.slowest)} per km'
      '${plan.voice ? ' · voice cues' : ''}';
}

/// "30 s", "1 min".
String averageLabel(int seconds) =>
    seconds < 60 ? '$seconds s' : '${seconds ~/ 60} min';

/// "the last 30 seconds", "the last minute", "the last 2 minutes".
String averagePhrase(int seconds) => switch (seconds) {
  < 60 => 'the last $seconds seconds',
  60 => 'the last minute',
  _ => 'the last ${seconds ~/ 60} minutes',
};

/// Seconds per km between steps.
const _step = 5;

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w800,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// "Fastest  − 5:30 +", in 5 s steps between [min] and [max].
class _PaceStepper extends StatelessWidget {
  const _PaceStepper({
    required this.label,
    required this.pace,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int pace;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '$label: faster',
            icon: const Icon(Icons.remove),
            onPressed: pace - _step < min
                ? null
                : () => onChanged(pace - _step),
          ),
          SizedBox(
            width: 72,
            child: Text(
              '${formatPace(pace)} /km',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            tooltip: '$label: slower',
            icon: const Icon(Icons.add),
            onPressed: pace + _step > max
                ? null
                : () => onChanged(pace + _step),
          ),
        ],
      ),
    );
  }
}
