import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/group.dart';
import '../core/protocol.dart';

/// How a participant should look on the map and in lists.
class ParticipantStyle {
  const ParticipantStyle(this.color, this.label, this.icon);
  final Color color;
  final String label;
  final IconData icon;

  static ParticipantStyle of(Participant p, DateTime now, AlertPolicy policy) {
    final r = p.latest;
    switch (r.status) {
      case RunnerStatus.sos:
        return const ParticipantStyle(TrailColors.danger, 'SOS', Icons.sos);
      case RunnerStatus.left:
        return r.safe
            ? const ParticipantStyle(
                Colors.blueGrey,
                'Safely out',
                Icons.verified_user,
              )
            : const ParticipantStyle(
                TrailColors.danger,
                'Left, unconfirmed',
                Icons.person_off,
              );
      case RunnerStatus.finished:
        return const ParticipantStyle(
          Colors.blueGrey,
          'Finished',
          Icons.sports_score,
        );
      case RunnerStatus.offRoute:
        return const ParticipantStyle(
          TrailColors.danger,
          'Off route',
          Icons.wrong_location,
        );
      case RunnerStatus.wrongWay:
        return const ParticipantStyle(
          TrailColors.warning,
          'Wrong way',
          Icons.u_turn_left,
        );
      case RunnerStatus.ok:
        break;
    }
    if (now.difference(p.lastHeard) > policy.noSignalAfter) {
      return const ParticipantStyle(
        Colors.grey,
        'No signal',
        Icons.signal_cellular_connected_no_internet_0_bar,
      );
    }
    return switch (r.role) {
      Role.organizer => const ParticipantStyle(
        Brand.night,
        'Organizer',
        Icons.flag,
      ),
      Role.sweeper => const ParticipantStyle(
        Color(0xFF6B4FA8),
        'Sweeper',
        Icons.hiking,
      ),
      Role.runner => const ParticipantStyle(
        TrailColors.ok,
        'On route',
        Icons.directions_run,
      ),
    };
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first.characters.take(2).toString().toUpperCase();
  }
  return (parts.first.characters.first + parts.last.characters.first)
      .toUpperCase();
}
