import 'package:flutter/material.dart';

import '../app.dart';
import '../core/geo.dart';
import '../core/group.dart';
import '../state/run_session.dart';
import 'status_style.dart';

/// Everyone in the event, furthest along first, with alerts on top.
/// Returns the id of a participant to show on the map, if one was tapped.
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
        builder: (context, _) => _GroupList(session: session, scroll: scroll),
      ),
    ),
  );
}

class _GroupList extends StatelessWidget {
  const _GroupList({required this.session, required this.scroll});

  final RunSession session;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final people = session.group.byProgress();
    final spread = session.group.spread();
    final alerts = session.alerts;

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '${session.event?.name ?? 'Group'} · ${people.length} '
            '${people.length == 1 ? 'person' : 'people'}',
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (spread != null && spread.$1 != spread.$2)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
              tileColor:
                  (a.kind == AlertKind.sos || a.kind == AlertKind.offRoute
                          ? TrailColors.danger
                          : TrailColors.warning)
                      .withValues(alpha: 0.12),
              leading: Icon(
                _alertIcon(a.kind),
                color: a.kind == AlertKind.sos || a.kind == AlertKind.offRoute
                    ? TrailColors.danger
                    : TrailColors.warning,
              ),
              title: Text('${a.participant.name}: ${a.kind.label}'),
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
            isMe: p.id == session.myId,
            now: now,
            policy: session.alertPolicy,
            routeLength: session.route?.length,
            onTap: () => Navigator.pop(context, p.id),
          ),
      ],
    );
  }

  static IconData _alertIcon(AlertKind k) => switch (k) {
    AlertKind.sos => Icons.sos,
    AlertKind.offRoute => Icons.wrong_location,
    AlertKind.wrongWay => Icons.u_turn_left,
    AlertKind.noSignal => Icons.signal_cellular_connected_no_internet_0_bar,
    AlertKind.stopped => Icons.pause_circle_outline,
    AlertKind.lowBattery => Icons.battery_alert,
  };
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.participant,
    required this.isMe,
    required this.now,
    required this.policy,
    required this.routeLength,
    required this.onTap,
  });

  final Participant participant;
  final bool isMe;
  final DateTime now;
  final AlertPolicy policy;
  final double? routeLength;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = participant.latest;
    final style = ParticipantStyle.of(participant, now, policy);
    final facts = [
      if (r.along != null)
        routeLength == null
            ? formatDistance(r.along!)
            : '${formatDistance(r.along!)} of ${formatDistance(routeLength!)}',
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
      title: Text('${participant.name}${isMe ? ' (you)' : ''}'),
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
