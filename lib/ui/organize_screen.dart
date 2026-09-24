import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/course.dart';
import '../core/geo.dart';
import '../state/run_session.dart';
import 'course_editor_screen.dart';
import 'route_picker.dart';
import 'run_screen.dart';

class OrganizeScreen extends StatefulWidget {
  const OrganizeScreen({super.key});

  @override
  State<OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends State<OrganizeScreen> {
  final _form = GlobalKey<FormState>();
  late final _eventName = TextEditingController(text: 'Group trail run');
  late final _name = TextEditingController(
    text: AppScope.of(context).settings.displayName,
  );
  late final _phone = TextEditingController(
    text: AppScope.of(context).settings.phone,
  );
  final List<Course> _courses = [];
  bool _busy = false;

  @override
  void dispose() {
    _eventName.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _addCourse() async {
    final r = await pickRoute(context);
    if (r == null) return;
    var n = _courses.length + 1;
    while (_courses.any((c) => c.id == 'c$n')) {
      n++;
    }
    setState(() => _courses.add(Course.fromRoute(r, id: 'c$n')));
  }

  Future<void> _editCourse(int i) async {
    final edited = await Navigator.of(context).push<Course>(
      MaterialPageRoute(
        builder: (_) => CourseEditorScreen(course: _courses[i]),
      ),
    );
    if (edited != null) setState(() => _courses[i] = edited);
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    final app = AppScope.of(context);
    app.settings
      ..displayName = _name.text
      ..phone = _phone.text;
    setState(() => _busy = true);
    try {
      final session = await RunSession.organize(
        app.settings,
        app.notifier,
        eventName: _eventName.text.trim(),
        courses: _courses,
      );
      if (!mounted) {
        session.dispose();
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => RunScreen(session: session, showCodeOnStart: true),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not create event: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Organize a group run')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _eventName,
              decoration: const InputDecoration(
                labelText: 'Event name',
                prefixIcon: Icon(Icons.flag_outlined),
              ),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Give the run a name'
                  : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final idea in Brand.eventIdeas)
                  ActionChip(
                    label: Text(idea),
                    onPressed: () => setState(() => _eventName.text = idea),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Your name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Runners see this name'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(
                labelText: 'Your phone number (optional)',
                helperText:
                    'Lets runners call or text you from the SOS '
                    'screen. SMS works even without mobile data.',
                helperMaxLines: 2,
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 24),
            Text(
              'Courses',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _courses.length; i++)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.route, size: 32),
                  title: Text(
                    _courses[i].name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    [
                      formatDistance(_courses[i].route.length),
                      'D+ ${_courses[i].route.totalAscent.round()} m',
                      '${_courses[i].checkpoints.length} checkpoints',
                    ].join(' · '),
                  ),
                  onTap: () => _editCourse(i),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => setState(() => _courses.removeAt(i)),
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _addCourse,
              icon: const Icon(Icons.add),
              label: Text(
                _courses.isEmpty ? 'Add a GPX route' : 'Add another distance',
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Add one route, or one per distance (e.g. 10, 25 and 50 km). '
              'Runners pick theirs when joining. Tap a course to set its '
              'start time, checkpoints and cut-offs.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text('Create event'),
            ),
          ],
        ),
      ),
    );
  }
}
