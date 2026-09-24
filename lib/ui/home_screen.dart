import 'package:flutter/material.dart';

import '../app.dart';
import '../brand.dart';
import '../core/event_code.dart';
import '../core/route.dart';
import '../services/settings.dart';
import '../state/run_session.dart';
import 'fuel_plan_screen.dart';
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
      body: ListenableBuilder(
        listenable: app.settings,
        builder: (context, _) {
          final active = app.settings.activeEvent;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _Hero(
                  onSettings: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                sliver: SliverList.list(
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    const _CommunityLine(),
                    const SizedBox(height: 12),
                    if (active != null) ...[
                      Card(
                        color: Brand.night,
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(
                            16,
                            8,
                            8,
                            8,
                          ),
                          leading: const Icon(
                            Icons.directions_run,
                            color: Brand.ember,
                            size: 32,
                          ),
                          title: const Text(
                            'You are in a group run',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          subtitle: Text(
                            '${formatEventCode(active.code)} · ${active.role.label}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    app.settings.activeEvent = null,
                                child: const Text(
                                  'Forget',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 40),
                                ),
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
                      icon: Icons.flag_outlined,
                      color: Brand.canyon,
                      title: 'Organize a group run',
                      subtitle:
                          'For race directors, coaches and captains. '
                          'Share the GPX and see every runner live, with '
                          'alerts if anyone strays.',
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
                      color: Brand.oasis,
                      title: 'Join a group run',
                      subtitle:
                          'Enter the event code from your organizer. '
                          'The route lands on your phone automatically.',
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
                      color: Brand.night,
                      title: 'Navigate solo',
                      subtitle:
                          'Follow a GPX route with off-route and '
                          'wrong-way alerts. No mobile data needed.',
                      onTap: _busy ? null : _solo,
                    ),
                    const SizedBox(height: 8),
                    const _WadiChecklist(),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.bolt, color: Brand.oasis),
                        title: const Text(
                          'Fuel plan',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          app.settings.fuelPlan.enabled
                              ? '${app.settings.fuelPlan.carbsPerHour.round()} g '
                                    'carbs per hour · reminders every '
                                    '${app.settings.fuelPlan.intervalMin} min'
                              : 'Reminders off',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const FuelPlanScreen(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Free: no accounts, no subscriptions. Group locations '
                      'are end-to-end encrypted with the event code.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return SizedBox(
      height: 300 + top,
      child: DesertBackdrop(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, top + 8, 8, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IbexBadge(size: 44),
                  const SizedBox(width: 12),
                  const Text(
                    Brand.appName,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Settings',
                    color: Colors.white,
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: onSettings,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                Brand.tagline,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  height: 1.15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 60),
                child: Text(
                  Brand.subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    shadows: const [
                      Shadow(blurRadius: 6, color: Colors.black54),
                    ],
                    fontSize: 15,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommunityLine extends StatelessWidget {
  const _CommunityLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const IbexBadge(size: 22, onDark: false),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            Brand.communityLine,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Brand.canyon, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Icon(Icons.arrow_forward_ios, size: 16, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A reminder of the basics before heading out into the desert.
class _WadiChecklist extends StatelessWidget {
  const _WadiChecklist();

  static const _items = [
    (Icons.water_drop_outlined, 'Enough water'),
    (Icons.battery_charging_full, 'Phone charged'),
    (Icons.download_for_offline_outlined, 'Map saved offline'),
    (Icons.hiking, 'Sweeper at the back'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.sand.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Before you head into the wadi',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: Brand.night,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (icon, text) in _items)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: Brand.canyon),
                      const SizedBox(width: 6),
                      Text(
                        text,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Brand.night,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
