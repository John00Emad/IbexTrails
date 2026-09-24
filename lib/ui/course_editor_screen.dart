import 'package:flutter/material.dart';

import '../core/course.dart';
import '../core/geo.dart';
import 'group_sheet.dart' show clock;

/// Organizer: set a course's name, start time and checkpoints with
/// cut-offs. Returns the edited course, or null if cancelled.
class CourseEditorScreen extends StatefulWidget {
  const CourseEditorScreen({super.key, required this.course});

  final Course course;

  @override
  State<CourseEditorScreen> createState() => _CourseEditorScreenState();
}

class _CourseEditorScreenState extends State<CourseEditorScreen> {
  late final _name = TextEditingController(text: widget.course.name);
  late DateTime? _start = widget.course.start;
  late List<Checkpoint> _cps = List.of(widget.course.checkpoints);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Course get _result => widget.course.copyWith(
    name: _name.text.trim().isEmpty ? widget.course.name : _name.text.trim(),
    checkpoints: _cps,
    start: _start,
    clearStart: _start == null,
  );

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final base = _start ?? DateTime(now.year, now.month, now.day, 6);
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    setState(
      () => _start = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _editCheckpoint(int index) async {
    final edited = await showModalBottomSheet<Checkpoint>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CheckpointForm(
        checkpoint: _cps[index],
        courseLength: widget.course.route.length,
        start: _start,
      ),
    );
    if (edited != null) {
      setState(() {
        _cps[index] = edited;
        _cps.sort((a, b) => a.along.compareTo(b.along));
      });
    }
  }

  Future<void> _addCheckpoint() async {
    var n = _cps.length + 1;
    while (_cps.any((c) => c.id == 'cp$n')) {
      n++;
    }
    final fresh = Checkpoint(
      id: 'cp$n',
      name: 'CP$n',
      kind: CheckpointKind.aid,
      along: widget.course.route.length / 2,
    );
    final created = await showModalBottomSheet<Checkpoint>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CheckpointForm(
        checkpoint: fresh,
        courseLength: widget.course.route.length,
        start: _start,
      ),
    );
    if (created != null) {
      setState(() {
        _cps = [..._cps, created]..sort((a, b) => a.along.compareTo(b.along));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = widget.course.route;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Course & checkpoints'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _result),
            child: const Text('SAVE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCheckpoint,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add checkpoint'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Distance name',
              hintText: 'e.g. 25 km',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${formatDistance(route.length)} · D+ ${route.totalAscent.round()} m',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(
                _start == null
                    ? 'No fixed start'
                    : 'Start ${MaterialLocalizations.of(context).formatMediumDate(_start!)} · ${clock(_start!)}',
              ),
              subtitle: Text(
                _start == null
                    ? 'Cut-offs count from when each runner starts.'
                    : 'Cut-offs count from this start (wave start).',
              ),
              trailing: _start == null
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _start = null),
                    ),
              onTap: _pickStart,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Checkpoints',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          if (_cps.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No checkpoints yet. Waypoints in the GPX file become '
                'checkpoints automatically, or add them here.',
              ),
            ),
          for (var i = 0; i < _cps.length; i++)
            Card(
              child: ListTile(
                leading: Icon(_kindIcon(_cps[i].kind)),
                title: Text(
                  _cps[i].name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  [
                    '${_cps[i].kind.label} · ${formatDistance(_cps[i].along)}',
                    if (_cps[i].cutoff != null)
                      'cut-off ${_hm(_cps[i].cutoff!)}'
                          '${_start == null ? '' : ' (${clock(_start!.add(_cps[i].cutoff!))})'}',
                  ].join(' · '),
                ),
                onTap: () => _editCheckpoint(i),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _cps.removeAt(i)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

IconData _kindIcon(CheckpointKind k) => switch (k) {
  CheckpointKind.checkpoint => Icons.flag,
  CheckpointKind.water => Icons.water_drop,
  CheckpointKind.aid => Icons.restaurant,
  CheckpointKind.medical => Icons.medical_services,
};

String _hm(Duration d) =>
    '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}';

class _CheckpointForm extends StatefulWidget {
  const _CheckpointForm({
    required this.checkpoint,
    required this.courseLength,
    required this.start,
  });

  final Checkpoint checkpoint;
  final double courseLength;
  final DateTime? start;

  @override
  State<_CheckpointForm> createState() => _CheckpointFormState();
}

class _CheckpointFormState extends State<_CheckpointForm> {
  late final _name = TextEditingController(text: widget.checkpoint.name);
  late final _km = TextEditingController(
    text: (widget.checkpoint.along / 1000).toStringAsFixed(2),
  );
  late CheckpointKind _kind = widget.checkpoint.kind;
  late Duration? _cutoff = widget.checkpoint.cutoff;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _km.dispose();
    super.dispose();
  }

  Future<void> _pickCutoff() async {
    final initial = _cutoff ?? const Duration(hours: 2);
    final t = await showTimePicker(
      context: context,
      helpText: 'Cut-off: hours and minutes after the start',
      initialEntryMode: TimePickerEntryMode.input,
      initialTime: TimeOfDay(
        hour: initial.inHours.clamp(0, 23),
        minute: initial.inMinutes.remainder(60),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t != null) {
      setState(() => _cutoff = Duration(hours: t.hour, minutes: t.minute));
    }
  }

  void _save() {
    final km = double.tryParse(_km.text.replaceAll(',', '.'));
    if (km == null || km < 0 || km * 1000 > widget.courseLength + 1) {
      setState(
        () => _error =
            'Between 0 and ${(widget.courseLength / 1000).toStringAsFixed(2)} km',
      );
      return;
    }
    Navigator.pop(
      context,
      widget.checkpoint.copyWith(
        name: _name.text.trim().isEmpty ? widget.checkpoint.name : _name.text,
        kind: _kind,
        along: km * 1000,
        cutoff: _cutoff,
        clearCutoff: _cutoff == null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _km,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Distance from start (km)',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final k in CheckpointKind.values)
                ChoiceChip(
                  avatar: Icon(_kindIcon(k), size: 18),
                  label: Text(k.label),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer_outlined),
            title: Text(
              _cutoff == null ? 'No cut-off' : 'Cut-off ${_hm(_cutoff!)}',
            ),
            subtitle: Text(
              _cutoff != null && widget.start != null
                  ? 'Closes at ${clock(widget.start!.add(_cutoff!))}'
                  : 'Time allowed from the start to reach this point',
            ),
            trailing: _cutoff == null
                ? TextButton(onPressed: _pickCutoff, child: const Text('Set'))
                : IconButton(
                    tooltip: 'Remove cut-off',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _cutoff = null),
                  ),
            onTap: _pickCutoff,
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: const Text('Done')),
        ],
      ),
    );
  }
}
