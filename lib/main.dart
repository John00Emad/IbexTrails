import 'package:flutter/material.dart';

import 'app.dart';
import 'services/notifications.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final notifier = Notifier();
  await notifier.init();
  runApp(IbexTrailsApp(settings: settings, notifier: notifier));
}
