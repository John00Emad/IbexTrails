import 'package:flutter/material.dart';

import '../brand.dart';
import '../core/geo.dart';
import '../services/run_library.dart';
import 'group_sheet.dart';
import 'run_detail_screen.dart';

/// My runs: every run recorded on this phone, newest first.
class RunsScreen extends StatefulWidget {
  const RunsScreen({super.key});

  @override
  State<RunsScreen> createState() => _RunsScreenState();
}

class _RunsScreenState extends State<RunsScreen> {
  late Future<List<SavedRun>> _runs = RunLibrary.list();

  Future<void> _open(SavedRun run) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => RunDetailScreen(run: run)));
    // It may have been renamed or deleted, or run again.
    if (mounted) setState(() => _runs = RunLibrary.list());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My runs')),
      body: FutureBuilder<List<SavedRun>>(
        future: _runs,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final runs = snap.data;
          if (runs == null) {
            return _Empty(
              icon: Icons.error_outline,
              title: 'Could not read your runs',
              text: '${snap.error}',
            );
          }
          if (runs.isEmpty) {
            return const _Empty(
              icon: Icons.directions_run,
              title: 'No runs yet',
              text:
                  'During a run, solo or in a group, tap Record on the map. '
                  'What you record is kept here as a GPX file.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: runs.length + 1,
            itemBuilder: (context, i) => i == 0
                ? _Totals(runs: runs)
                : _RunTile(run: runs[i - 1], onTap: () => _open(runs[i - 1])),
          );
        },
      ),
    );
  }
}

/// "Fri, Oct 3 · 06:15", with the year when it isn't this year.
String runDate(BuildContext context, DateTime start) {
  final local = start.toLocal();
  final year = local.year == DateTime.now().year ? '' : ' ${local.year}';
  final date = MaterialLocalizations.of(context).formatMediumDate(local);
  return '$date$year · ${clock(local)}';
}

class _Totals extends StatelessWidget {
  const _Totals({required this.runs});
  final List<SavedRun> runs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final km = runs.fold(0.0, (sum, r) => sum + r.distance);
    final climb = runs.fold(0.0, (sum, r) => sum + r.ascent);
    final facts = [
      '${runs.length} ${runs.length == 1 ? 'run' : 'runs'}',
      formatDistance(km),
      if (climb > 0) 'D+ ${climb.round()} m',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Brand.sand.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.insights, color: Brand.canyon),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              facts.join(' · '),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Brand.night,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run, required this.onTap});
  final SavedRun run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = run.elapsed;
    final facts = [
      formatDistance(run.distance),
      if (time != null) formatDuration(time),
      if (run.ascent >= 1) 'D+ ${run.ascent.round()} m',
    ];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Brand.ember,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.directions_run, color: Colors.white),
        ),
        title: Text(
          run.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('${runDate(context, run.start)}\n${facts.join(' · ')}'),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Brand.canyon),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
