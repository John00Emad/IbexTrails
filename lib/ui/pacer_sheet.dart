import 'package:flutter/material.dart';

import '../app.dart';
import '../core/geo.dart';
import '../core/pacer.dart';
import '../state/run_session.dart';
import 'group_sheet.dart' show clock;
import 'pacer_plan_screen.dart';

/// Green on pace, amber too fast, red too slow, grey without a pace.
Color paceColor(PaceZone? zone) => switch (zone) {
  PaceZone.onPace => TrailColors.ok,
  PaceZone.tooFast => TrailColors.warning,
  PaceZone.tooSlow => TrailColors.danger,
  null => Colors.blueGrey,
};

/// "+0:35" ahead of the pacer, "-1:10" behind it.
String formatGap(Duration gap) =>
    '${gap.isNegative ? '-' : '+'}${formatDuration(gap.abs())}';

/// One word or two for where the runner is: "On pace", "Stopped"...
String pacerStatus(VirtualPacer pacer) {
  if (pacer.finished) return 'Finished';
  final zone = pacer.zone;
  if (zone != null) return zone.label;
  return pacer.stopped ? 'Stopped' : 'Pacer ready';
}

/// The range for the stretch being run, e.g. "5:30–6:30" or, on a climb,
/// "7:10–8:30 uphill".
String pacerRange(VirtualPacer pacer) {
  final (lo, hi) = pacer.range;
  final uphill = pacer.climbFactor >= 1.05 ? ' uphill' : '';
  return '${formatPace(lo)}–${formatPace(hi)}$uphill';
}

/// The virtual pacer during a run: your pace against the range, how far
/// ahead or behind the pacer you are, and a restart. Private to this phone.
Future<void> showPacerSheet(BuildContext context, RunSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([session, session.settings]),
      builder: (context, _) => _PacerSheet(session: session),
    ),
  );
}

class _PacerSheet extends StatelessWidget {
  const _PacerSheet({required this.session});
  final RunSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pacer = session.pacer;
    final plan = session.settings.pacerPlan;
    final title = Row(
      children: [
        Expanded(
          child: Text(
            'Virtual pacer',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PacerPlanScreen()),
          ),
          icon: const Icon(Icons.tune),
          label: Text(
            '${formatPace(plan.fastest)}–${formatPace(plan.slowest)} /km',
          ),
        ),
      ],
    );
    if (pacer == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [title, const Text('The pacer is off.')],
          ),
        ),
      );
    }

    final pace = pacer.pace;
    final (lo, hi) = pacer.range;
    final color = paceColor(pacer.zone);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            title,
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  pace == null ? '–' : formatPace(pace),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(' /km', style: theme.textTheme.titleMedium),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    pacerStatus(pacer),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _PaceGauge(pace: pace, fastest: lo, slowest: hi, color: color),
            const SizedBox(height: 8),
            Text(
              'Your pace over ${averagePhrase(plan.averageSeconds)}. Range '
              '${pacerRange(pacer)} /km.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Text(
              _gapText(pacer),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'The pacer runs at ${formatPace(plan.target)} /km, the middle '
              'of your range${pacer.route != null && plan.hills ? ', and '
                        'slower up climbs' : ''}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: session.restartPacer,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Restart pacer here'),
            ),
            const SizedBox(height: 8),
            Text(
              'Starts the pacer again from where you are, e.g. on the start '
              'line. Your pace and the pacer stay on this phone.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _gapText(VirtualPacer pacer) {
    final gap = pacer.gap;
    if (gap == null) {
      final at = pacer.anchor?.time;
      return at == null
          ? 'The pacer sets off when you start running.'
          : 'The pacer sets off at ${clock(at)}, the race start.';
    }
    final lead = pacer.lead;
    final metres = lead == null ? '' : ' · ${formatDistance(lead.abs())}';
    if (gap.inSeconds == 0) return 'Level with the pacer';
    return '${formatDuration(gap.abs())} '
        '${gap.isNegative ? 'behind' : 'ahead of'} the pacer$metres';
  }
}

/// A bar from slower (left) to faster (right) with the range in green and
/// a dot for your pace.
class _PaceGauge extends StatelessWidget {
  const _PaceGauge({
    required this.pace,
    required this.fastest,
    required this.slowest,
    required this.color,
  });

  final double? pace;
  final double fastest;
  final double slowest;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // By speed, so that faster is further right.
    final left = 1000 / (slowest * 1.25);
    final right = 1000 / (fastest * 0.8);
    double at(double pace) =>
        ((1000 / pace - left) / (right - left)).clamp(0.0, 1.0);
    final p = pace;
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 8,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Positioned(
                    left: at(slowest) * w,
                    width: (at(fastest) - at(slowest)) * w,
                    top: 8,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: TrailColors.ok,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  if (p != null)
                    Positioned(
                      left: at(p) * w - 10,
                      top: 2,
                      width: 20,
                      height: 20,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(blurRadius: 3, color: Colors.black26),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Row(
          children: [
            Text('Slower', style: theme.textTheme.bodySmall),
            const Spacer(),
            Text('Faster', style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}
