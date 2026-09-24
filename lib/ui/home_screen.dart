import 'package:flutter/material.dart';

import '../app.dart';
import '../core/event_code.dart';
import '../core/route.dart';
import '../services/settings.dart';
import '../state/run_session.dart';
import 'join_screen.dart';
import 'organize_screen.dart';
import 'route_picker.dart';
import 'run_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;

  Future<void> _openRun(Future<RunSession> Function() start) async {
    setState(() => _busy = true);
    try {
      final session = await start();
      if (!mounted) {
        session.dispose();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RunScreen(session: session)),
      );
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not start: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _solo() async {
    final app = AppScope.of(context);
    final TrailRoute? route = await pickRoute(context);
    if (route == null || !mounted) return;
    await _openRun(
      () => RunSession.solo(app.settings, app.notifier, route: route),
    );
  }

  Future<void> _resume(ActiveEvent active) async {
    final app = AppScope.of(context);
    await _openRun(() => RunSession.resume(app.settings, app.notifier, active));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('IbexTrails'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app.settings,
        builder: (context, _) {
          final active = app.settings.activeEvent;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy) const LinearProgressIndicator(),
              const _Hero(),
              const SizedBox(height: 16),
              if (active != null) ...[
                Card(
                  color: theme.colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.directions_run),
                    title: const Text('You are in a group run'),
                    subtitle: Text(
                      '${formatEventCode(active.code)} · ${active.role.label}',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => app.settings.activeEvent = null,
                          child: const Text('Forget'),
                        ),
                        FilledButton.tonal(
                          onPressed: _busy ? null : () => _resume(active),
                          child: const Text('Rejoin'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              _ActionCard(
                icon: Icons.groups_2_outlined,
                title: 'Organize a group run',
                subtitle:
                    'Share a GPX route and see where everyone is, '
                    'with alerts if someone goes off route.',
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const OrganizeScreen(),
                        ),
                      ),
              ),
              _ActionCard(
                icon: Icons.login,
                title: 'Join a group run',
                subtitle:
                    'Enter the event code from your organizer. '
                    'The route is sent to your phone automatically.',
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const JoinScreen(),
                        ),
                      ),
              ),
              _ActionCard(
                icon: Icons.explore_outlined,
                title: 'Navigate solo',
                subtitle:
                    'Follow a GPX route with off-route and wrong-way '
                    'alerts. Works without mobile data.',
                onTap: _busy ? null : _solo,
              ),
              const SizedBox(height: 24),
              Text(
                'Free and open: no accounts, no subscriptions. Group '
                'locations are end-to-end encrypted with the event code.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [TrailColors.forest, theme.colorScheme.primary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.terrain, size: 56, color: Colors.white),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Run together.',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Never lose the trail.',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(subtitle, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
