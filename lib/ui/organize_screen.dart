import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/route.dart';
import '../state/run_session.dart';
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
  TrailRoute? _route;
  bool _busy = false;

  @override
  void dispose() {
    _eventName.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _chooseRoute() async {
    final r = await pickRoute(context);
    if (r != null) setState(() => _route = r);
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
        route: _route,
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
            Text('Route', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_route == null)
              OutlinedButton.icon(
                onPressed: _chooseRoute,
                icon: const Icon(Icons.route),
                label: const Text('Choose a GPX route'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              )
            else
              RouteSummary(route: _route!, onChange: _chooseRoute),
            const SizedBox(height: 4),
            Text(
              'The route is sent to everyone who joins, so they can navigate '
              'it and get off-route alerts. You can also add it later.',
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
