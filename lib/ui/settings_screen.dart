import 'package:flutter/material.dart';

import '../app.dart';
import '../services/settings.dart';
import 'fuel_plan_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppSettings s = AppScope.of(context).settings;
  late final _name = TextEditingController(text: s.displayName);
  late final _phone = TextEditingController(text: s.phone);
  late final _host = TextEditingController(text: s.relayHost);
  late final _port = TextEditingController(text: '${s.relayPort}');

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  RelayPreset? get _preset {
    for (final p in relayPresets) {
      if (p.host == s.relayHost &&
          p.port == s.relayPort &&
          p.tls == s.relayTls) {
        return p;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _Section('You'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Your name'),
                textCapitalization: TextCapitalization.words,
                onChanged: (v) => s.displayName = v,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _phone,
                decoration: const InputDecoration(
                  labelText: 'Phone number (shared when you organize)',
                ),
                keyboardType: TextInputType.phone,
                onChanged: (v) => s.phone = v,
              ),
            ),
            _Section('Navigation'),
            ListTile(
              title: const Text('Off-route alert distance'),
              subtitle: Text(
                'Alert when more than ${s.offRouteMeters.round()} m from the '
                'route. Use a larger value for wide or poorly mapped trails.',
              ),
            ),
            Slider(
              value: s.offRouteMeters,
              min: 25,
              max: 150,
              divisions: 25,
              label: '${s.offRouteMeters.round()} m',
              onChanged: (v) => s.offRouteMeters = v,
            ),
            SwitchListTile(
              title: const Text('Keep screen on while running'),
              subtitle: const Text(
                'Uses more battery. Alerts work with the '
                'screen off either way.',
              ),
              value: s.keepScreenOn,
              onChanged: (v) => s.keepScreenOn = v,
            ),
            for (final m in MapStyle.values)
              ListTile(
                leading: Icon(
                  m == s.mapStyle
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(m.label),
                onTap: () => s.mapStyle = m,
              ),
            _Section('Fuelling'),
            ListTile(
              leading: const Icon(Icons.bolt),
              title: const Text('Fuel plan'),
              subtitle: Text(
                s.fuelPlan.enabled
                    ? '${s.fuelPlan.carbsPerHour.round()} g carbs/h · '
                          'reminders every ${s.fuelPlan.intervalMin} min'
                    : 'Reminders off',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const FuelPlanScreen()),
              ),
            ),
            _Section('Group tracking'),
            ListTile(
              title: const Text('Send my position every'),
              trailing: DropdownButton<int>(
                value: s.reportSeconds,
                items: [
                  for (final v in const [10, 20, 30, 60])
                    DropdownMenuItem(value: v, child: Text('$v s')),
                ],
                onChanged: (v) {
                  if (v != null) s.reportSeconds = v;
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Applies to the next run. Status changes such as '
                'off route or SOS are always sent immediately.',
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              title: const Text('Relay server'),
              subtitle: const Text(
                'Everyone in an event must use the same relay. Messages are '
                'end-to-end encrypted; the relay only passes them on.',
              ),
              isThreeLine: true,
            ),
            for (final p in relayPresets)
              ListTile(
                leading: Icon(
                  p == _preset
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(p.label),
                subtitle: Text('${p.host}:${p.port}'),
                onTap: () {
                  s
                    ..relayHost = p.host
                    ..relayPort = p.port
                    ..relayTls = p.tls;
                  _host.text = p.host;
                  _port.text = '${p.port}';
                },
              ),
            ExpansionTile(
              title: const Text('Custom relay (MQTT)'),
              subtitle: _preset == null
                  ? Text('${s.relayHost}:${s.relayPort}')
                  : null,
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                TextField(
                  controller: _host,
                  decoration: const InputDecoration(labelText: 'Host'),
                  keyboardType: TextInputType.url,
                  onChanged: (v) => s.relayHost = v,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _port,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    final port = int.tryParse(v);
                    if (port != null) s.relayPort = port;
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('TLS'),
                  value: s.relayTls,
                  onChanged: (v) => s.relayTls = v,
                ),
              ],
            ),
            _Section('About'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Text(
                'IbexTrails is free and has no accounts. Group positions go '
                'through a public MQTT relay, encrypted with a key derived '
                'from the event code, so only people with the code can read '
                'them. Maps © OpenStreetMap contributors; topo style © '
                'OpenTopoMap.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
