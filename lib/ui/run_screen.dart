import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app.dart';
import '../brand.dart';
import '../core/geo.dart';
import '../core/group.dart';
import '../services/location_service.dart';
import '../services/map_tiles.dart';
import '../services/relay_client.dart';
import '../services/settings.dart';
import '../state/run_session.dart';
import 'elevation_profile.dart';
import 'group_sheet.dart';
import 'route_picker.dart';
import 'settings_screen.dart';
import 'sos_sheet.dart';
import 'status_style.dart';
import 'trail_map.dart';

class RunScreen extends StatefulWidget {
  const RunScreen({
    super.key,
    required this.session,
    this.showCodeOnStart = false,
  });

  final RunSession session;
  final bool showCodeOnStart;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

enum _MenuAction {
  announce,
  route,
  download,
  style,
  screen,
  save,
  settings,
  leave,
}

class _RunScreenState extends State<RunScreen> {
  final _map = MapController();
  bool _follow = true;
  String? _selected;
  String? _dismissedAnnouncement;
  late final Timer _clock;
  StreamSubscription<PrefetchProgress>? _prefetch;
  PrefetchProgress? _prefetchProgress;

  RunSession get s => widget.session;
  AppSettings get settings => s.settings;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (settings.keepScreenOn) WakelockPlus.enable();
    if (widget.showCodeOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showCode());
    }
  }

  @override
  void dispose() {
    _clock.cancel();
    _prefetch?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---- Actions -----------------------------------------------------------

  String get _invite =>
      'Join my trail run "${s.event?.name ?? 'Group run'}" on IbexTrails.\n'
      'Event code: ${s.displayCode}';

  Future<void> _showCode() async {
    if (!s.isEvent) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key),
        title: const Text('Event code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              s.displayCode,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(letterSpacing: 3, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Share this code with your group. Anyone with the '
              'code can join and see positions, so share it only with '
              'participants.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () {
              Navigator.pop(context);
              SharePlus.instance.share(ShareParams(text: _invite));
            },
            icon: const Icon(Icons.share),
            label: const Text('Share'),
          ),
        ],
      ),
    );
  }

  Future<void> _openGroup() async {
    final id = await showGroupSheet(context, s);
    if (id == null || !mounted) return;
    final p = s.group[id];
    if (p == null) return;
    setState(() {
      _selected = id;
      _follow = false;
    });
    _map.move(
      LatLng(p.latest.lat, p.latest.lon),
      math.max(_map.camera.zoom, 15),
    );
  }

  Future<void> _announce() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message the group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 140,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Regroup at the water point',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty || !mounted) return;
    final ok = await s.announce(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Message sent' : 'Offline: message not sent'),
      ),
    );
  }

  Future<void> _changeRoute() async {
    final r = await pickRoute(context);
    if (r == null) return;
    s.useRoute(r);
    final (sw, ne) = r.bounds;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(ll(sw), ll(ne)),
        padding: const EdgeInsets.fromLTRB(40, 140, 40, 260),
      ),
    );
    setState(() => _follow = false);
  }

  void _downloadMap() {
    final route = s.route;
    if (route == null) return;
    _prefetch?.cancel();
    setState(() => _prefetchProgress = const PrefetchProgress(0, 1, 0));
    _prefetch = MapTiles.prefetchRoute(route, settings.mapStyle).listen(
      (p) => setState(() => _prefetchProgress = p),
      onDone: () {
        final p = _prefetchProgress;
        setState(() => _prefetchProgress = null);
        if (!mounted || p == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              p.failed == 0
                  ? 'Map saved for offline use along the route'
                  : 'Map saved (${p.failed} tiles failed; try again with a '
                        'better connection)',
            ),
          ),
        );
      },
    );
  }

  Future<void> _chooseStyle() async {
    final style = await showDialog<MapStyle>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Map style'),
        children: [
          for (final m in MapStyle.values)
            ListTile(
              leading: Icon(
                m == settings.mapStyle
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(m.label),
              onTap: () => Navigator.pop(context, m),
            ),
        ],
      ),
    );
    if (style != null) setState(() => settings.mapStyle = style);
  }

  Future<void> _saveRecording() async {
    final file = await s.saveRecording();
    if (!mounted) return;
    if (file == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Nothing recorded yet')));
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/gpx+xml')],
        subject: 'IbexTrails run',
      ),
    );
  }

  Future<void> _leave() async {
    final endAll = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.isEvent ? 'Leave the run?' : 'Stop navigating?'),
        content: Text(
          s.isOrganizer
              ? 'Ending the event removes the route and everyone\'s positions '
                    'from the relay. Leaving keeps it running for the others.'
              : s.isEvent
              ? 'The group will see that you left.'
              : 'Your recorded track can be saved from the menu first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (s.isOrganizer)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Leave'),
            ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(context, s.isOrganizer),
            child: Text(
              s.isOrganizer
                  ? 'End event'
                  : s.isEvent
                  ? 'Leave'
                  : 'Stop',
            ),
          ),
        ],
      ),
    );
    if (endAll == null) return;
    await s.leave(endEvent: endAll);
    if (mounted) Navigator.of(context).pop();
  }

  void _onMenu(_MenuAction a) {
    switch (a) {
      case _MenuAction.announce:
        _announce();
      case _MenuAction.route:
        _changeRoute();
      case _MenuAction.download:
        _downloadMap();
      case _MenuAction.style:
        _chooseStyle();
      case _MenuAction.screen:
        final on = !settings.keepScreenOn;
        settings.keepScreenOn = on;
        WakelockPlus.toggle(enable: on);
        setState(() {});
      case _MenuAction.save:
        _saveRecording();
      case _MenuAction.settings:
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      case _MenuAction.leave:
        _leave();
    }
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: ListenableBuilder(
        listenable: s,
        builder: (context, _) => Scaffold(
          appBar: _appBar(context),
          body: Stack(
            children: [
              Positioned.fill(
                child: TrailMap(
                  session: s,
                  controller: _map,
                  style: settings.mapStyle,
                  follow: _follow,
                  onFollowChanged: (f) => setState(() => _follow = f),
                  selected: _selected,
                  onSelect: (id) => setState(() => _selected = id),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                top: 36,
                child: Column(children: _banners(context)),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: _MapButtons(
                  follow: _follow,
                  onFollow: () => setState(() => _follow = true),
                  onSos: () => showSosSheet(context, s),
                  sosActive: s.sos,
                ),
              ),
            ],
          ),
          bottomNavigationBar: _StatsPanel(session: s),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final title = s.event?.name ?? s.route?.name ?? 'Solo run';
    final alerts = s.alerts.length;
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, overflow: TextOverflow.ellipsis),
          if (s.isEvent) _ConnectionLine(session: s),
        ],
      ),
      leading: IconButton(
        tooltip: 'Leave',
        icon: const Icon(Icons.close),
        onPressed: _leave,
      ),
      actions: [
        if (s.isEvent)
          IconButton(
            tooltip: 'Share event code',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: _showCode,
          ),
        if (s.isEvent)
          IconButton(
            tooltip: 'Group',
            onPressed: _openGroup,
            icon: Badge(
              isLabelVisible: alerts > 0,
              label: Text('$alerts'),
              child: const Icon(Icons.groups),
            ),
          ),
        PopupMenuButton<_MenuAction>(
          onSelected: _onMenu,
          itemBuilder: (context) => [
            if (s.isOrganizer)
              const PopupMenuItem(
                value: _MenuAction.announce,
                child: ListTile(
                  leading: Icon(Icons.campaign_outlined),
                  title: Text('Message the group'),
                ),
              ),
            if (!s.isEvent || s.isOrganizer || s.route == null)
              PopupMenuItem(
                value: _MenuAction.route,
                child: ListTile(
                  leading: const Icon(Icons.route),
                  title: Text(
                    s.route == null
                        ? 'Load a GPX route'
                        : s.isOrganizer
                        ? 'Change & share route'
                        : 'Change route',
                  ),
                ),
              ),
            if (s.route != null)
              const PopupMenuItem(
                value: _MenuAction.download,
                child: ListTile(
                  leading: Icon(Icons.download_for_offline_outlined),
                  title: Text('Save map for offline'),
                ),
              ),
            const PopupMenuItem(
              value: _MenuAction.style,
              child: ListTile(
                leading: Icon(Icons.layers_outlined),
                title: Text('Map style'),
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.screen,
              child: ListTile(
                leading: Icon(
                  settings.keepScreenOn
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                ),
                title: const Text('Keep screen on'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.save,
              child: ListTile(
                leading: Icon(Icons.save_alt),
                title: Text('Export my track (GPX)'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.settings,
              child: ListTile(
                leading: Icon(Icons.settings_outlined),
                title: Text('Settings'),
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.leave,
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: Text(s.isOrganizer ? 'Leave / end event' : 'Leave'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _banners(BuildContext context) {
    final out = <Widget>[];
    final m = s.match;
    final f = s.fix;

    if (s.locationError != null) {
      out.add(
        _Banner(
          color: TrailColors.danger,
          icon: Icons.location_off,
          text: s.locationError!,
          actions: [
            TextButton(
              onPressed: () async {
                await LocationService.openSettings();
              },
              child: const Text(
                'SETTINGS',
                style: TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              onPressed: s.retryLocation,
              child: const Text('RETRY', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } else if (f == null) {
      out.add(
        const _Banner(
          color: Colors.black87,
          icon: Icons.gps_not_fixed,
          text: 'Waiting for GPS… Go outside with a clear view of the sky.',
        ),
      );
    }

    if (s.sos) {
      out.add(
        _Banner(
          color: TrailColors.danger,
          icon: Icons.sos,
          text: 'SOS active. The group can see where you are.',
          actions: [
            TextButton(
              onPressed: () => s.setSos(false),
              child: const Text(
                'CANCEL',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    if (m != null && f != null && m.offRoute) {
      final bearing = bearingBetween(
        GeoPoint(f.latitude, f.longitude),
        m.nearest,
      );
      out.add(
        _Banner(
          color: TrailColors.danger,
          leading: Transform.rotate(
            angle: bearing * math.pi / 180,
            child: const Icon(Icons.navigation, color: Colors.white, size: 30),
          ),
          text:
              'Off route: ${formatDistance(m.distance)} from the trail. '
              'The route is to the ${compassName(bearing)}.',
        ),
      );
    } else if (m != null && m.wrongWay) {
      out.add(
        const _Banner(
          color: TrailColors.warning,
          icon: Icons.u_turn_left,
          text: 'Wrong way? You are heading back along the route.',
        ),
      );
    }

    if (s.isEvent && s.route == null && !s.eventEnded) {
      final waited = DateTime.now().difference(s.joinedAt).inSeconds;
      out.add(
        _Banner(
          color: Colors.black87,
          icon: Icons.hourglass_top,
          text: s.event == null
              ? (waited > 20
                    ? 'No event found yet. Check the code with your organizer, '
                          'or wait for a mobile signal.'
                    : 'Connecting to the event…')
              : 'The organizer has not shared a route yet. You can load one '
                    'from the menu.',
        ),
      );
    }

    if (s.eventEnded) {
      out.add(
        const _Banner(
          color: Colors.black87,
          icon: Icons.flag,
          text: 'The organizer ended this event.',
        ),
      );
    }

    final a = s.announcement;
    if (a != null && a.id != _dismissedAnnouncement) {
      out.add(
        _Banner(
          color: Theme.of(context).colorScheme.primary,
          icon: Icons.campaign,
          text: '${a.from}: ${a.text}',
          actions: [
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => setState(() => _dismissedAnnouncement = a.id),
            ),
          ],
        ),
      );
    }

    if (s.watchesGroup && s.alerts.isNotEmpty) {
      final top = s.alerts.first;
      final urgent =
          top.kind == AlertKind.sos || top.kind == AlertKind.offRoute;
      out.add(
        _Banner(
          color: urgent ? TrailColors.danger : TrailColors.warning,
          icon: Icons.warning_amber,
          text:
              '${top.participant.name}: ${top.kind.label} (${top.detail})'
              '${s.alerts.length > 1 ? ' +${s.alerts.length - 1} more' : ''}',
          onTap: _openGroup,
        ),
      );
    }

    final p = _prefetchProgress;
    if (p != null) {
      out.add(
        _Banner(
          color: Colors.black87,
          icon: Icons.download,
          text:
              'Saving map for offline: ${p.done + p.failed} / ${p.total} tiles',
          actions: [
            TextButton(
              onPressed: () {
                _prefetch?.cancel();
                setState(() => _prefetchProgress = null);
              },
              child: const Text('STOP', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
    return out;
  }
}

class _ConnectionLine extends StatelessWidget {
  const _ConnectionLine({required this.session});
  final RunSession session;

  @override
  Widget build(BuildContext context) {
    final relay = session.relay;
    if (relay == null) return const SizedBox.shrink();
    return ValueListenableBuilder<RelayState>(
      valueListenable: relay.state,
      builder: (context, state, _) {
        final (color, text) = switch (state) {
          RelayState.online => (TrailColors.ok, 'Live'),
          RelayState.connecting => (TrailColors.warning, 'Connecting…'),
          RelayState.offline => (Colors.grey, 'No signal, will resend'),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '$text · ${session.displayCode}',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.white70, letterSpacing: 0.5),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.text,
    this.icon,
    this.leading,
    this.actions = const [],
    this.onTap,
  });

  final Color color;
  final String text;
  final IconData? icon;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: color,
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                leading ?? Icon(icon, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapButtons extends StatelessWidget {
  const _MapButtons({
    required this.follow,
    required this.onFollow,
    required this.onSos,
    required this.sosActive,
  });

  final bool follow;
  final VoidCallback onFollow;
  final VoidCallback onSos;
  final bool sosActive;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'follow',
          tooltip: 'Follow my position',
          onPressed: onFollow,
          child: Icon(follow ? Icons.my_location : Icons.location_searching),
        ),
        const SizedBox(height: 12),
        FloatingActionButton(
          heroTag: 'sos',
          tooltip: 'Emergency',
          backgroundColor: TrailColors.danger,
          foregroundColor: Colors.white,
          onPressed: onSos,
          child: Icon(sosActive ? Icons.sos : Icons.emergency_share),
        ),
      ],
    );
  }
}

/// Bottom panel with the numbers a runner glances at.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.session});
  final RunSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final theme = Theme.of(context);
    final route = s.route;
    final m = s.match;
    final elapsed = s.startedAt == null
        ? Duration.zero
        : DateTime.now().difference(s.startedAt!);
    final speed = s.fix?.speed ?? 0;
    final pace = speed > 0.5
        ? formatDuration(Duration(seconds: (1000 / speed).round()))
        : '–';

    final tiles = <Widget>[];
    if (route != null) {
      final along = m?.along ?? 0;
      tiles.addAll([
        _Stat(
          'Done ${(100 * along / route.length).clamp(0, 100).round()}%',
          formatDistance(along),
          null,
        ),
        _Stat('To go', formatDistance(route.length - along), null),
        if (route.hasElevation)
          _Stat(
            'Climb left',
            '${route.ascentRemaining(along).round()} m',
            null,
          ),
        _Stat('Time', formatDuration(elapsed), null),
      ]);
    } else {
      tiles.addAll([
        _Stat('Distance', formatDistance(s.distanceRun), null),
        _Stat('Time', formatDuration(elapsed), null),
        _Stat('Pace', pace, '/km'),
        _Stat(
          'Elevation',
          s.fix == null ? '–' : '${s.fix!.altitude.round()} m',
          null,
        ),
      ]);
    }

    final next = (route != null && m != null)
        ? route.nextWaypoint(m.along)
        : null;
    final others = <ProfileMarker>[
      if (route != null)
        for (final p in s.group.participants)
          if (p.id != s.myId && p.latest.along != null && p.isActive())
            ProfileMarker(
              p.latest.along!,
              ParticipantStyle.of(p, DateTime.now(), s.alertPolicy).color,
            ),
    ];

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [for (final t in tiles) Expanded(child: t)]),
              if (next != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_on,
                        size: 18,
                        color: Brand.oasis,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Next: ${next.waypoint.name} in '
                          '${formatDistance(next.distanceAhead)}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              if (route != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ElevationProfile(
                    route: route,
                    along: m?.along,
                    others: others,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.suffix);
  final String label;
  final String value;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
                if (suffix != null)
                  TextSpan(text: ' $suffix', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
