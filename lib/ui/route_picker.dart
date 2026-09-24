import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/geo.dart';
import '../core/gpx.dart';
import '../core/route.dart';
import '../services/route_library.dart';

/// Opens the system file picker for a GPX file, saves it to the library and
/// returns the parsed route. Shows an error and returns null on failure.
Future<TrailRoute?> importGpxFile(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await FilePicker.pickFile(dialogTitle: 'Choose a GPX file');
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes, allowMalformed: true);
    return await RouteLibrary.import(text, fileName: file.name);
  } on GpxFormatException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open file: $e')));
  }
  return null;
}

/// Bottom sheet: import a new GPX file or choose a saved route.
Future<TrailRoute?> pickRoute(BuildContext context) {
  return showModalBottomSheet<TrailRoute>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _RoutePickerSheet(),
  );
}

class _RoutePickerSheet extends StatefulWidget {
  const _RoutePickerSheet();

  @override
  State<_RoutePickerSheet> createState() => _RoutePickerSheetState();
}

class _RoutePickerSheetState extends State<_RoutePickerSheet> {
  late Future<List<SavedRoute>> _saved = RouteLibrary.list();
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    final route = await importGpxFile(context);
    if (!mounted) return;
    setState(() => _busy = false);
    if (route != null) Navigator.pop(context, route);
  }

  Future<void> _open(SavedRoute s) async {
    setState(() => _busy = true);
    try {
      final route = await RouteLibrary.load(s);
      if (mounted) Navigator.pop(context, route);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not load route: $e')));
    }
  }

  Future<void> _delete(SavedRoute s) async {
    await RouteLibrary.delete(s);
    setState(() => _saved = RouteLibrary.list());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: FilledButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.file_open),
                label: const Text('Import GPX file'),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Saved routes',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Flexible(
              child: FutureBuilder<List<SavedRoute>>(
                future: _saved,
                builder: (context, snap) {
                  final items = snap.data ?? const [];
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (items.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No saved routes yet. Imported GPX files are kept '
                        'here so you can reuse them offline.',
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final s = items[i];
                      return ListTile(
                        leading: const Icon(Icons.route),
                        title: Text(s.name),
                        subtitle: Text(
                          'Added ${MaterialLocalizations.of(context).formatMediumDate(s.modified)}',
                        ),
                        onTap: _busy ? null : () => _open(s),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(s),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact description of a route: distance, climbing, waypoints.
class RouteSummary extends StatelessWidget {
  const RouteSummary({super.key, required this.route, this.onChange});

  final TrailRoute route;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final facts = [
      formatDistance(route.length),
      if (route.hasElevation) 'D+ ${route.totalAscent.round()} m',
      if (route.hasElevation) 'D− ${route.totalDescent.round()} m',
      if (route.isLoop) 'loop',
      if (route.waypoints.isNotEmpty) '${route.waypoints.length} waypoints',
    ];
    return Card(
      child: ListTile(
        leading: const Icon(Icons.route, size: 32),
        title: Text(route.name, style: text.titleMedium),
        subtitle: Text(facts.join(' · ')),
        trailing: onChange == null
            ? null
            : TextButton(onPressed: onChange, child: const Text('Change')),
      ),
    );
  }
}
