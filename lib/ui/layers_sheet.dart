import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/map_layers.dart';
import '../services/map_tiles.dart';
import '../services/settings.dart';

/// Base map, overlays and 3D, like the layer panel of a hiking app.
Future<void> showLayersSheet(BuildContext context, AppSettings settings) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scroll) =>
            LayersPanel(settings: settings, controller: scroll),
      ),
    );

/// "OpenTopoMap + Hillshade · 3D", for summaries.
String describeMapSetup(AppSettings settings) {
  final map = settings.resolvedMap;
  return [
        map.base.name,
        for (final (l, _) in map.overlays) l.name,
      ].join(' + ') +
      (map.terrain3d ? ' · 3D' : '');
}

class LayersPanel extends StatelessWidget {
  const LayersPanel({super.key, required this.settings, this.controller});

  final AppSettings settings;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final setup = settings.mapSetup;
        final map = settings.resolvedMap;
        void update(MapSetup next) => settings.mapSetup = next;
        bool hasKey(MapLayer l) =>
            !l.provider.needsKey || settings.mapKey(l.provider).isNotEmpty;

        Future<void> pick(MapLayer l, MapSetup Function() next) async {
          if (!hasKey(l) && !await editMapKey(context, settings, l.provider)) {
            return;
          }
          update(next());
        }

        final bases = layersOfKind(LayerKind.base);
        return ListView(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Map layers',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _Heading('Quick picks'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in mapPresets)
                    ChoiceChip(
                      label: Text(p.name),
                      tooltip: p.description,
                      selected: _matches(setup, p.setup),
                      onSelected: (_) => update(
                        p.setup.copyWith(
                          elevationId: setup.elevationId,
                          exaggeration: setup.exaggeration,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              secondary: const Icon(Icons.terrain),
              title: const Text('3D terrain'),
              subtitle: const Text(
                'Tilt and turn the map with two fingers. Uses more battery '
                'than the flat map.',
              ),
              value: setup.terrain3d,
              onChanged: (v) => update(setup.copyWith(terrain3d: v)),
            ),
            if (setup.terrain3d)
              ListTile(
                title: const Text('Exaggerate relief'),
                subtitle: Slider(
                  value: setup.exaggeration,
                  min: 1,
                  max: 2,
                  divisions: 10,
                  label: '${setup.exaggeration.toStringAsFixed(1)}×',
                  onChanged: (v) => update(setup.copyWith(exaggeration: v)),
                ),
                trailing: Text('${setup.exaggeration.toStringAsFixed(1)}×'),
              ),
            _Heading('Base map'),
            for (final l in bases.where((l) => !l.provider.needsKey))
              _LayerRadio(
                layer: l,
                selected: map.base.id == l.id,
                onTap: () => update(setup.copyWith(baseId: l.id)),
              ),
            const _Subheading('With your own key'),
            for (final l in bases.where((l) => l.provider.needsKey))
              _LayerRadio(
                layer: l,
                selected: map.base.id == l.id,
                locked: !hasKey(l),
                onTap: () => pick(l, () => setup.copyWith(baseId: l.id)),
              ),
            _Heading('Overlays'),
            for (final l in layersOfKind(LayerKind.overlay))
              _OverlayTile(
                layer: l,
                opacity: setup.overlays[l.id],
                in3d: setup.terrain3d,
                onChanged: (o) => update(setup.withOverlay(l.id, o)),
              ),
            _Heading('Elevation (3D, hillshade, contours)'),
            for (final l in layersOfKind(LayerKind.elevation))
              _LayerRadio(
                layer: l,
                selected: map.elevation.id == l.id,
                locked: !hasKey(l),
                onTap: () => pick(l, () => setup.copyWith(elevationId: l.id)),
              ),
            _Heading('Your map keys'),
            for (final p in MapProvider.values.where((p) => p.needsKey))
              ListTile(
                leading: Icon(
                  settings.mapKey(p).isEmpty ? Icons.key_off : Icons.key,
                ),
                title: Text(p.label),
                subtitle: Text(
                  settings.mapKey(p).isEmpty ? p.plan ?? '' : 'Key saved',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => editMapKey(context, settings, p),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Free layers need no account. Keys stay on this phone and '
                'are only sent to their provider, which bills you directly '
                'under your own plan. IbexTrails takes nothing.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }

  static bool _matches(MapSetup a, MapSetup b) =>
      a.baseId == b.baseId &&
      a.terrain3d == b.terrain3d &&
      a.overlays.keys.toSet().containsAll(b.overlays.keys) &&
      b.overlays.keys.toSet().containsAll(a.overlays.keys);
}

class _LayerRadio extends StatelessWidget {
  const _LayerRadio({
    required this.layer,
    required this.selected,
    required this.onTap,
    this.locked = false,
  });

  final MapLayer layer;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = layer;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(l.name),
      subtitle: Text(
        [
          l.description,
          if (locked) 'Add a ${l.provider.label} key',
          if (l.allowsBulkDownload) 'Can be saved offline',
        ].where((t) => t.isNotEmpty).join(' · '),
      ),
      trailing: locked ? const Icon(Icons.lock_outline) : null,
      onTap: onTap,
    );
  }
}

class _OverlayTile extends StatelessWidget {
  const _OverlayTile({
    required this.layer,
    required this.opacity,
    required this.in3d,
    required this.onChanged,
  });

  final MapLayer layer;
  final double? opacity;
  final bool in3d;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = layer;
    final on = opacity != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: Text(l.name),
          subtitle: Text(
            l.terrainOnly && !in3d
                ? '${l.description} · Shows in the 3D view'
                : l.description,
          ),
          value: on,
          onChanged: (v) => onChanged(v ? l.defaultOpacity : null),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              children: [
                const Icon(Icons.opacity, size: 18),
                Expanded(
                  child: Slider(
                    value: opacity!,
                    min: 0.1,
                    max: 1,
                    label: '${(opacity! * 100).round()}%',
                    divisions: 9,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Subheading extends StatelessWidget {
  const _Subheading(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );
}

// ---- Keys --------------------------------------------------------------

/// Lets the runner add, test or remove their key for [provider]. Returns
/// whether a key is saved afterwards.
Future<bool> editMapKey(
  BuildContext context,
  AppSettings settings,
  MapProvider provider,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) =>
        _KeyDialog(provider: provider, initial: settings.mapKey(provider)),
  );
  if (result != null) settings.setMapKey(provider, result);
  return settings.mapKey(provider).isNotEmpty;
}

/// Checks a key by fetching one tile from the provider.
Future<String> testMapKey(
  MapProvider provider,
  String key, {
  http.Client? client,
}) async {
  final layer = mapLayers.firstWhere((l) => l.provider == provider);
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.parse(layer.urlFor(2, 2, 1, key: key)),
          headers: {'User-Agent': 'flutter_map ($userAgentPackage)'},
        )
        .timeout(const Duration(seconds: 15));
    return switch (res.statusCode) {
      200 => 'Key works',
      401 || 403 => 'Key refused by ${provider.label} (HTTP ${res.statusCode})',
      _ => 'Couldn\'t check: HTTP ${res.statusCode}',
    };
  } on Object {
    return 'Couldn\'t check: no connection';
  } finally {
    if (client == null) c.close();
  }
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog({required this.provider, required this.initial});
  final MapProvider provider;
  final String initial;

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  late final _key = TextEditingController(text: widget.initial);
  String? _status;
  bool _testing = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    final status = await testMapKey(widget.provider, _key.text.trim());
    if (mounted) {
      setState(() {
        _testing = false;
        _status = status;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final url = p.keyUrl;
    return AlertDialog(
      title: Text('${p.label} key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${p.plan}. Usage is billed by ${p.label} under your own '
              'account; IbexTrails takes nothing. The key stays on this '
              'phone.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'API key'),
              onChanged: (_) => setState(() => _status = null),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (url != null)
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Get a key'),
                  ),
                TextButton.icon(
                  onPressed: _testing || _key.text.trim().isEmpty
                      ? null
                      : _test,
                  icon: const Icon(Icons.network_check),
                  label: const Text('Test'),
                ),
                if (_testing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_status != null) Text(_status!),
          ],
        ),
      ),
      actions: [
        if (widget.initial.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _key.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
