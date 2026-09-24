import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../state/run_session.dart';

String _mapsLink(double lat, double lon) =>
    'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

/// Emergency options: alert the group, call or text the organizer, share
/// coordinates through any app.
Future<void> showSosSheet(BuildContext context, RunSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: session,
      builder: (context, _) => _SosSheet(session: session),
    ),
  );
}

class _SosSheet extends StatelessWidget {
  const _SosSheet({required this.session});
  final RunSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = session.fix;
    final phone = session.event?.organizerPhone;
    final coords = f == null
        ? null
        : '${f.latitude.toStringAsFixed(5)}, ${f.longitude.toStringAsFixed(5)}';
    final message = f == null
        ? null
        : 'I need help. My location: ${_mapsLink(f.latitude, f.longitude)} '
              '($coords, ±${f.accuracy.round()} m)';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Emergency', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            if (coords != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.my_location),
                  title: SelectableText(
                    coords,
                    style: theme.textTheme.titleLarge,
                  ),
                  subtitle: Text(
                    'Your position (±${f!.accuracy.round()} m). '
                    'Read this out if you call for help.',
                  ),
                ),
              )
            else
              const Card(
                child: ListTile(
                  leading: Icon(Icons.gps_not_fixed),
                  title: Text('Waiting for GPS…'),
                ),
              ),
            const SizedBox(height: 8),
            if (session.isEvent)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: session.sos
                      ? Colors.grey.shade700
                      : TrailColors.danger,
                ),
                onPressed: () => session.setSos(!session.sos),
                icon: Icon(session.sos ? Icons.cancel : Icons.sos),
                label: Text(
                  session.sos ? 'Cancel SOS' : 'Send SOS to the group',
                ),
              ),
            if (session.isEvent)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  session.sos
                      ? 'The organizer and group can see that you need help '
                            'and where you are.'
                      : 'Alerts the organizer, sweepers and runners and '
                            'marks you in red on everyone\'s map.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (phone != null && phone.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                icon: const Icon(Icons.call),
                label: Text('Call organizer ($phone)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: message == null
                    ? null
                    : () => launchUrl(
                        Uri(
                          scheme: 'sms',
                          path: phone,
                          queryParameters: {'body': message},
                        ),
                      ),
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Text my location to organizer'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'SMS often gets through when mobile data does not.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            OutlinedButton.icon(
              onPressed: message == null
                  ? null
                  : () => SharePlus.instance.share(ShareParams(text: message)),
              icon: const Icon(Icons.share_location),
              label: const Text('Share my location via…'),
            ),
          ],
        ),
      ),
    );
  }
}
