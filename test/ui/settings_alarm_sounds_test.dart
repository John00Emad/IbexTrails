// Settings: hear each alarm sound before you need it on the trail.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/app.dart';
import 'package:ibex_trails/services/alarm_audio.dart';
import 'package:ibex_trails/services/notifications.dart';
import 'package:ibex_trails/services/settings.dart';
import 'package:ibex_trails/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PreviewNotifier extends Notifier {
  final played = <AlarmSound>[];

  @override
  Future<void> preview(AlarmSound sound) async => played.add(sound);
}

void main() {
  Future<_PreviewNotifier> open(
    WidgetTester tester, {
    TargetPlatform? platform,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final settings = (await tester.runAsync(AppSettings.load))!;
    final notifier = _PreviewNotifier();
    await tester.pumpWidget(
      AppScope(
        settings: settings,
        notifier: notifier,
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Alarm sounds'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    return notifier;
  }

  testWidgets('each alarm sound plays from settings', (tester) async {
    final notifier = await open(tester);
    expect(find.textContaining('full alarm volume'), findsOneWidget);
    for (final sound in AlarmSound.values) {
      await tester.scrollUntilVisible(
        find.text(sound.meaning),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      // The row is built, but its title may still be off screen or under
      // the app bar.
      await tester.ensureVisible(find.text(sound.label));
      await tester.pump();
      await tester.tap(find.text(sound.label));
    }
    expect(notifier.played, AlarmSound.values);
  });

  testWidgets('iPhone users are told to turn the volume up', (tester) async {
    await open(tester, platform: TargetPlatform.iOS);
    expect(find.textContaining('turn it up before you run'), findsOneWidget);
  });
}
