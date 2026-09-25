import 'package:flutter/material.dart';

import '../app.dart';
import '../core/course.dart';
import '../core/geo.dart';
import '../core/group.dart';
import '../core/protocol.dart';
import '../state/run_session.dart';
import 'status_style.dart';

enum GroupView { runners, checkpoints, headcount }

/// Everyone in the event, furthest along first, with alerts on top, plus a
/// checkpoint board and a headcount. Returns the id of a participant to show
/// on the map.
Future<String?> showGroupSheet(
  BuildContext context,
  RunSession session, {
  GroupView view = GroupView.runners,
}) {
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
        builder: (context, _) =>
            _GroupSheet(session: session, scroll: scroll, view: view),
      ),
    ),
  );
}

class _GroupSheet extends StatefulWidget {
  const _GroupSheet({
    required this.session,
    required this.scroll,
    required this.view,
  });

  final RunSession session;
  final ScrollController scroll;
  final GroupView view;

  @override
  State<_GroupSheet> createState() => _GroupSheetState();
}

class _GroupSheetState extends State<_GroupSheet> {
  /// Course filter; null shows everyone.
  String? _course;
  late GroupView _view = widget.view;

  RunSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    // The headcount starts with everyone; the other views with my distance.
    _course = s.courseList.length > 1 && _view != GroupView.headcount
        ? s.course?.id
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courses = s.courseList;
    final selected = _course == null ? null : s.courses[_course];
    final people = s.group.byProgress(course: _course);
    final hasBoard = selected != null && selected.checkpoints.isNotEmpty;
    final view = _view == GroupView.checkpoints && !hasBoard
        ? GroupView.runners
        : _view;

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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: SegmentedButton<GroupView>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: GroupView.runners,
                icon: Icon(Icons.groups),
                label: Text('Runners'),
              ),
              if (hasBoard)
                const ButtonSegment(
                  value: GroupView.checkpoints,
                  icon: Icon(Icons.flag),
                  label: Text('Checkpoints'),
                ),
              const ButtonSegment(
                value: GroupView.headcount,
                icon: Icon(Icons.fact_check_outlined),
                label: Text('Headcount'),
              ),
            ],
            selected: {view},
            onSelectionChanged: (v) => setState(() => _view = v.first),
          ),
        ),
        ...switch (view) {
          GroupView.checkpoints => _checkpointBoard(context, selected!),
          GroupView.headcount => _headcount(context),
          GroupView.runners => _runners(context, people),
        },
      ],
    );
  }

  List<Widget> _headcount(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final hc = s.headcount(courseId: _course);
    Widget tile(String label, int n, Color color) => Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              '$n',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    Widget person(Participant p, String detail, {bool canTick = false}) =>
        ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: ParticipantStyle.of(p, now, s.alertPolicy).color,
            foregroundColor: Colors.white,
            child: Text(initials(p.name), style: const TextStyle(fontSize: 12)),
          ),
          title: Text(
            p.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(detail),
          onTap: () => Navigator.pop(context, p.id),
          trailing: canTick && s.isOrganizer
              ? TextButton(
                  onPressed: () => _markSafe(context, p),
                  child: const Text('Mark safe'),
                )
              : null,
        );
    String lastSeen(Participant p) =>
        'last heard ${formatAgo(p.lastHeard, now)} ago'
        '${p.latest.along == null ? '' : ' at ${formatDistance(p.latest.along!)}'}';

    return [
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            tile(
              'On course',
              hc.onCourse.length + hc.notStarted.length,
              theme.colorScheme.primary,
            ),
            tile('Finished', hc.finished.length, TrailColors.ok),
            tile('Safely out', hc.safeOut.length, Colors.blueGrey),
            tile(
              'Unaccounted',
              hc.unaccounted.length,
              hc.unaccounted.isEmpty ? Colors.grey : TrailColors.danger,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          hc.total == 0
              ? 'Nobody has joined yet.'
              : hc.allIn
              ? 'Everyone is accounted for: ${hc.accountedFor} of ${hc.total}.'
              : '${hc.accountedFor} of ${hc.total} accounted for.',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: hc.allIn ? TrailColors.ok : null,
          ),
        ),
      ),
      if (hc.unaccounted.isNotEmpty) ...[
        header('Unaccounted: check on these first'),
        for (final p in hc.unaccounted)
          person(
            p,
            p.latest.status == RunnerStatus.left
                ? 'closed the app without confirming they are safe'
                : 'no signal: ${lastSeen(p)}',
            canTick: true,
          ),
      ],
      if (hc.onCourse.isNotEmpty) ...[
        header('On course'),
        for (final p in hc.onCourse) person(p, lastSeen(p), canTick: true),
      ],
      if (hc.notStarted.isNotEmpty) ...[
        header('At the start'),
        for (final p in hc.notStarted) person(p, lastSeen(p), canTick: true),
      ],
      if (hc.finished.isNotEmpty) ...[
        header('Finished'),
        for (final p in hc.finished)
          person(p, 'finished at ${clock(p.latest.time)}'),
      ],
      if (hc.safeOut.isNotEmpty) ...[
        header('Safely out'),
        for (final p in hc.safeOut)
          ListTile(
            dense: true,
            leading: const Icon(Icons.verified_user, color: Colors.blueGrey),
            title: Text(p.name),
            subtitle: Text(
              s.accountedFor[p.id] ?? 'confirmed they are off the course',
            ),
            trailing: s.isOrganizer && s.accountedFor.containsKey(p.id)
                ? TextButton(
                    onPressed: () => s.markAccountedFor(p.id, null),
                    child: const Text('Undo'),
                  )
                : null,
          ),
      ],
    ];
  }

  Future<void> _markSafe(BuildContext context, Participant p) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Mark ${p.name} as safe?'),
        content: TextField(
          controller: note,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            hintText: 'e.g. Picked up by car at CP2',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark safe'),
          ),
        ],
      ),
    );
    if (ok == true) {
      s.markAccountedFor(
        p.id,
        note.text.trim().isEmpty
            ? 'Marked safe by organizer'
            : note.text.trim(),
      );
    }
    note.dispose();
  }

  Widget _chip(String label, String? id) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    child: ChoiceChip(
      label: Text(label),
      selected: _course == id,
      onSelected: (_) => setState(() => _course = id),
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
    AlertKind.cutoffMissed ||
    AlertKind.leftUnconfirmed ||
    AlertKind.behindSweeper => TrailColors.danger,
    _ => TrailColors.warning,
  };

  static IconData _alertIcon(AlertKind k) => switch (k) {
    AlertKind.sos => Icons.sos,
    AlertKind.offRoute => Icons.wrong_location,
    AlertKind.wrongWay => Icons.u_turn_left,
    AlertKind.cutoffMissed => Icons.timer_off,
    AlertKind.leftUnconfirmed => Icons.person_off,
    AlertKind.behindSweeper => Icons.hiking,
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
