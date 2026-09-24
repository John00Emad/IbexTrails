import 'package:flutter/material.dart';

import '../app.dart';
import '../core/course.dart';
import '../core/geo.dart';
import '../core/group.dart';
import '../state/run_session.dart';
import 'status_style.dart';

/// Everyone in the event, furthest along first, with alerts on top, plus a
/// checkpoint board. Returns the id of a participant to show on the map.
Future<String?> showGroupSheet(BuildContext context, RunSession session) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => _GroupSheet(session: session, scroll: scroll),
      ),
    ),
  );
}

class _GroupSheet extends StatefulWidget {
  const _GroupSheet({required this.session, required this.scroll});

  final RunSession session;
  final ScrollController scroll;

  @override
  State<_GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<_GroupSheet> {
  /// Course filter; null shows everyone.
  String? _course;
  bool _board = false;

  RunSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _course = s.courseList.length > 1 ? s.course?.id : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courses = s.courseList;
    final selected = _course == null ? null : s.courses[_course];
    final people = s.group.byProgress(course: _course);

    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '${s.event?.name ?? 'Group'} · ${people.length} '
            '${people.length == 1 ? 'person' : 'people'}',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (courses.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _chip('All', null),
                for (final c in courses) _chip(c.name, c.id),
              ],
            ),
          ),
        if (selected != null && selected.checkpoints.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.groups),
                  label: Text('Runners'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.flag),
                  label: Text('Checkpoints'),
                ),
              ],
              selected: {_board},
              onSelectionChanged: (v) => setState(() => _board = v.first),
            ),
          ),
        if (_board && selected != null)
          ..._checkpointBoard(context, selected)
        else
          ..._runners(context, people),
      ],
    );
  }

  Widget _chip(String label, String? id) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    child: ChoiceChip(
      label: Text(label),
      selected: _course == id,
      onSelected: (_) => setState(() {
        _course = id;
        if (id == null) _board = false;
      }),
    ),
  );

  List<Widget> _runners(BuildContext context, List<Participant> people) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final spread = s.group.spread(course: _course);
    final alerts = s.alerts
        .where((a) => _course == null || a.participant.latest.course == _course)
        .toList();
    return [
      if (spread != null && spread.$1 != spread.$2 && _course != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Front: ${spread.$1.name} at ${formatDistance(spread.$1.latest.along!)} · '
            'Back: ${spread.$2.name} at ${formatDistance(spread.$2.latest.along!)} · '
            'Gap ${formatDistance(spread.$1.latest.along! - spread.$2.latest.along!)}',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      if (alerts.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final a in alerts)
          ListTile(
            dense: true,
            tileColor: _alertColor(a.kind).withValues(alpha: 0.12),
            leading: Icon(_alertIcon(a.kind), color: _alertColor(a.kind)),
            title: Text(
              '${a.participant.name}: ${a.kind.label}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(a.detail),
            onTap: () => Navigator.pop(context, a.participant.id),
          ),
      ],
      const Divider(height: 24),
      if (people.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Nobody has shared a position yet. Runners appear '
            'here as soon as their phone gets a GPS fix and a signal.',
          ),
        ),
      for (final p in people)
        _PersonTile(
          participant: p,
          isMe: p.id == s.myId,
          now: now,
          policy: s.alertPolicy,
          course: s.courses[p.latest.course],
          showCourse: _course == null && s.courseList.length > 1,
          onTap: () => Navigator.pop(context, p.id),
        ),
    ];
  }

  List<Widget> _checkpointBoard(BuildContext context, Course course) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final rows = s.group.checkpointBoard(course, now);
    final total = s.group.byProgress(course: course.id).length;
    return [
      const SizedBox(height: 8),
      for (final row in rows)
        ExpansionTile(
          leading: CircleAvatar(
            backgroundColor: row.missed.isNotEmpty
                ? TrailColors.danger
                : theme.colorScheme.primary,
            foregroundColor: Colors.white,
            child: Text('${row.passed.length}'),
          ),
          title: Text(
            row.checkpoint.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            [
              '${formatDistance(row.checkpoint.along)} · '
                  '${row.passed.length}/$total through',
              if (row.cutoff != null) 'cut-off ${clock(row.cutoff!)}',
              if (row.missed.isNotEmpty) '${row.missed.length} missed',
            ].join(' · '),
          ),
          children: [
            for (final (p, at) in row.passed)
              ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle, color: TrailColors.ok),
                title: Text(p.name),
                trailing: Text(clock(at)),
                onTap: () => Navigator.pop(context, p.id),
              ),
            for (final p in row.missed)
              ListTile(
                dense: true,
                leading: const Icon(Icons.cancel, color: TrailColors.danger),
                title: Text(p.name),
                trailing: const Text('missed'),
                onTap: () => Navigator.pop(context, p.id),
              ),
            for (final p in row.pending)
              ListTile(
                dense: true,
                leading: const Icon(Icons.more_horiz),
                title: Text(p.name),
                trailing: Text(
                  p.latest.next == row.checkpoint.id && p.latest.eta != null
                      ? 'ETA ${clock(p.latest.eta!)}'
                      : '',
                ),
                onTap: () => Navigator.pop(context, p.id),
              ),
          ],
        ),
    ];
  }

  static Color _alertColor(AlertKind k) => switch (k) {
    AlertKind.sos ||
    AlertKind.offRoute ||
    AlertKind.cutoffMissed => TrailColors.danger,
    _ => TrailColors.warning,
  };

  static IconData _alertIcon(AlertKind k) => switch (k) {
    AlertKind.sos => Icons.sos,
    AlertKind.offRoute => Icons.wrong_location,
    AlertKind.wrongWay => Icons.u_turn_left,
    AlertKind.cutoffMissed => Icons.timer_off,
    AlertKind.noSignal => Icons.signal_cellular_connected_no_internet_0_bar,
    AlertKind.stopped => Icons.pause_circle_outline,
    AlertKind.cutoffRisk => Icons.timer,
    AlertKind.lowBattery => Icons.battery_alert,
  };
}

/// `09:05`.
String clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.participant,
    required this.isMe,
    required this.now,
    required this.policy,
    required this.course,
    required this.showCourse,
    required this.onTap,
  });

  final Participant participant;
  final bool isMe;
  final DateTime now;
  final AlertPolicy policy;
  final Course? course;
  final bool showCourse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = participant.latest;
    final style = ParticipantStyle.of(participant, now, policy);
    final length = course?.route.length;
    final facts = [
      if (showCourse && course != null) course!.name,
      if (r.along != null)
        length == null
            ? formatDistance(r.along!)
            : '${formatDistance(r.along!)} of ${formatDistance(length)}',
      if (r.offBy != null && r.offBy! > 30) '${formatDistance(r.offBy!)} off',
      '${formatAgo(participant.lastHeard, now)} ago',
      if (r.battery != null) '${r.battery}% battery',
    ];
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: style.color,
        foregroundColor: Colors.white,
        child: Text(initials(participant.name)),
      ),
      title: Text(
        '${participant.name}${isMe ? ' (you)' : ''}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text('${r.role.label} · ${facts.join(' · ')}'),
      trailing: Chip(
        avatar: Icon(style.icon, size: 16, color: style.color),
        label: Text(style.label),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: style.color.withValues(alpha: 0.5)),
      ),
    );
  }
}
