import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../core/geo.dart';
import '../core/gpx.dart';
import '../core/route.dart';
import '../core/run_stats.dart';
import '../services/map_tiles.dart';
import '../services/route_library.dart';
import '../services/run_library.dart';
import '../services/settings.dart';
import '../state/run_session.dart';
import 'elevation_profile.dart';
import 'group_sheet.dart';
import 'run_screen.dart';
import 'trail_map.dart';

const _gpxMime = 'application/gpx+xml';

enum _Action { save, addRoute, rename, delete }

/// One recorded run: its track on the map, its numbers, and running it
/// again.
class RunDetailScreen extends StatefulWidget {
  const RunDetailScreen({super.key, required this.run});

  final SavedRun run;

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  late SavedRun _run = widget.run;
  RunDetails? _details;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    RunLibrary.open(widget.run).then(
      (d) {
        if (mounted) setState(() => _details = d);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// The run as a clean GPX file under its current name (a file cut off
  /// when the app was closed mid-run comes out whole).
  Uint8List _gpx(RunDetails d) => utf8.encode(
    writeGpx(name: _run.name, points: d.gpx.track, times: d.gpx.times),
  );

  Future<void> _share(RunDetails d) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(_gpx(d), mimeType: _gpxMime)],
        // Shared as "Wadi loop 2026-10-03.gpx" rather than run_<time>.gpx.
        fileNameOverrides: [_run.exportName],
        subject: _run.name,
      ),
    );
  }

  /// The system "Save as" dialog: Downloads, Drive, Files...
  Future<void> _saveToPhone(RunDetails d) async {
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save run as GPX',
        fileName: _run.exportName,
        bytes: _gpx(d),
        mimeType: _gpxMime,
      );
      if (saved != null && mounted) _say('Saved ${_run.exportName}');
    } on Object catch (e) {
      if (mounted) _say('Could not save: $e');
    }
  }

  /// Makes the run available wherever a route is chosen, e.g. as a
  /// distance in a group run.
  Future<void> _addToRoutes(RunDetails d) async {
    try {
      await RouteLibrary.import(
        utf8.decode(_gpx(d)),
        fileName: '${_run.name}.gpx',
      );
      if (mounted) _say('Added to your saved routes');
    } on Object catch (e) {
      if (mounted) _say('Could not add the route: $e');
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _run.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename run'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == _run.name || !mounted) return;
    try {
      final renamed = await RunLibrary.rename(_run, trimmed);
      if (mounted) setState(() => _run = renamed);
    } on Object catch (e) {
      if (mounted) _say('Could not rename: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this run?'),
        content: Text(
          '${_run.name} is removed from this phone. Copies you saved or '
          'shared are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: TrailColors.danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await RunLibrary.delete(_run);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) _say('Could not delete: $e');
    }
  }

  /// Navigates this run's track as a route, with off-route alerts.
  Future<void> _runAgain(RunDetails d) async {
    final app = AppScope.of(context);
    final route = d.route.name == _run.name
        ? d.route
        : d.route.renamed(_run.name);
    setState(() => _busy = true);
    try {
      await openRun(
        context,
        () => RunSession.solo(app.settings, app.notifier, route: route),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onMenu(_Action a, RunDetails d) {
    switch (a) {
      case _Action.save:
        _saveToPhone(d);
      case _Action.addRoute:
        _addToRoutes(d);
      case _Action.rename:
        _rename();
      case _Action.delete:
        _delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _details;
    final start = _run.start.toLocal();
    return Scaffold(
      appBar: AppBar(
        title: Text(_run.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share),
            onPressed: d == null ? null : () => _share(d),
          ),
          PopupMenuButton<_Action>(
            enabled: d != null,
            onSelected: (a) => _onMenu(a, d!),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _Action.save,
                child: ListTile(
                  leading: Icon(Icons.save_alt),
                  title: Text('Save to phone (GPX)'),
                ),
              ),
              PopupMenuItem(
                value: _Action.addRoute,
                child: ListTile(
                  leading: Icon(Icons.route),
                  title: Text('Add to saved routes'),
                ),
              ),
              PopupMenuItem(
                value: _Action.rename,
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Rename'),
                ),
              ),
              PopupMenuItem(
                value: _Action.delete,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: d == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Could not open this run: $_error',
                        textAlign: TextAlign.center,
                      ),
                    ),
            )
          : Column(
              children: [
                SizedBox(
                  height: math.min(
                    340,
                    MediaQuery.sizeOf(context).height * 0.4,
                  ),
                  child: _RunMap(
                    route: d.route,
                    style: AppScope.of(context).settings.mapStyle,
                  ),
                ),
                if (_busy) const LinearProgressIndicator(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      Text(
                        '${MaterialLocalizations.of(context).formatFullDate(start)}'
                        ' · ${clock(start)}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _StatsGrid(
                        stats: d.stats,
                        hasElevation: d.route.hasElevation,
                      ),
                      if (d.route.hasElevation) ...[
                        const SizedBox(height: 16),
                        ElevationProfile(route: d.route, height: 96),
                      ],
                      if (d.stats.splits.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _Splits(splits: d.stats.splits),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _runAgain(d),
                  icon: const Icon(Icons.explore),
                  label: const Text('Run this route'),
                ),
              ),
            ),
    );
  }
}

/// The run's track on the map, fitted to the screen.
class _RunMap extends StatelessWidget {
  const _RunMap({required this.route, required this.style});

  final TrailRoute route;
  final MapStyle style;

  @override
  Widget build(BuildContext context) {
    final (sw, ne) = route.bounds;
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: LatLngBounds(ll(sw), ll(ne)),
          padding: const EdgeInsets.all(36),
          maxZoom: 16,
        ),
        minZoom: 3,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        MapTiles.layer(style),
        PolylineLayer(
          polylines: [
            Polyline(
              points: route.points.map(ll).toList(),
              color: TrailColors.route,
              strokeWidth: 5,
              borderColor: TrailColors.routeCasing.withValues(alpha: 0.85),
              borderStrokeWidth: 2,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            if (!route.isLoop)
              Marker(
                point: ll(route.finish),
                width: 30,
                height: 30,
                child: const RoundIcon(Icons.sports_score, Colors.black87),
              ),
            Marker(
              point: ll(route.start),
              width: 30,
              height: 30,
              child: const RoundIcon(Icons.flag, TrailColors.ok),
            ),
          ],
        ),
        MapAttribution(tileSourceFor(style).attribution),
      ],
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats, required this.hasElevation});

  final RunStats stats;
  final bool hasElevation;

  @override
  Widget build(BuildContext context) {
    String time(Duration? d) => d == null ? '–' : formatDuration(d);
    String metres(double m) => hasElevation ? '${m.round()} m' : '–';
    Widget row(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [for (final t in tiles) Expanded(child: t)]),
    );
    return Column(
      children: [
        row([
          StatTile('Distance', formatDistance(stats.distance), null),
          StatTile('Time', time(stats.elapsed), null),
          StatTile('Pace', time(stats.pace), stats.pace == null ? null : '/km'),
        ]),
        row([
          StatTile('Moving', time(stats.moving), null),
          StatTile('Climb', metres(stats.ascent), null),
          StatTile('Descent', metres(stats.descent), null),
        ]),
      ],
    );
  }
}

/// Time for each kilometre, the fastest highlighted.
class _Splits extends StatelessWidget {
  const _Splits({required this.splits});

  final List<Duration> splits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fastest = splits.reduce((a, b) => a <= b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SPLITS',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < splits.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    'km ${i + 1}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  formatDuration(splits[i]),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: splits[i] == fastest && splits.length > 1
                        ? FontWeight.w900
                        : FontWeight.w600,
                    color: splits[i] == fastest && splits.length > 1
                        ? TrailColors.route
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
