import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/event_code.dart';
import '../core/protocol.dart';
import '../state/run_session.dart';
import 'run_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  late final _name = TextEditingController(
    text: AppScope.of(context).settings.displayName,
  );
  Role _role = Role.runner;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    // Find a code anywhere in a pasted invitation message.
    final match = RegExp(r'[A-Za-z2-9]{5}-?[A-Za-z2-9]{5}').allMatches(text);
    for (final m in match) {
      final code = normalizeEventCode(m.group(0)!);
      if (code != null) {
        _code.text = formatEventCode(code);
        return;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No event code found on the clipboard')),
      );
    }
  }

  Future<void> _join() async {
    if (!_form.currentState!.validate()) return;
    final app = AppScope.of(context);
    app.settings.displayName = _name.text;
    setState(() => _busy = true);
    try {
      final session = await RunSession.join(
        app.settings,
        app.notifier,
        code: _code.text,
        role: _role,
      );
      if (!mounted) {
        session.dispose();
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => RunScreen(session: session)),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not join: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a group run')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _code,
              decoration: InputDecoration(
                labelText: 'Event code',
                hintText: 'ABCDE-FGHJK',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _paste,
                ),
              ),
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              style: const TextStyle(
                fontSize: 20,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
              validator: (v) => normalizeEventCode(v ?? '') == null
                  ? 'Codes have 10 letters/digits, like ABCDE-FGHJK'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Your name',
                helperText: 'Shown to the organizer and the group',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'The organizer needs to know who you are'
                  : null,
            ),
            const SizedBox(height: 24),
            Text(
              'I am joining as',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<Role>(
              segments: const [
                ButtonSegment(
                  value: Role.runner,
                  icon: Icon(Icons.directions_run),
                  label: Text('Runner'),
                ),
                ButtonSegment(
                  value: Role.sweeper,
                  icon: Icon(Icons.cleaning_services_outlined),
                  label: Text('Sweeper'),
                ),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              _role == Role.sweeper
                  ? 'Sweepers run at the back and also get alerts when '
                        'someone is off route, stopped or out of signal.'
                  : 'Your position is shared with the group while you run.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _busy ? null : _join,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }
}
