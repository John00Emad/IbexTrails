// Every alert type has its own sound, bundled with both apps and played as
// loud as each platform allows.
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ibex_trails/core/fuel.dart';
import 'package:ibex_trails/services/alarm_audio.dart';
import 'package:ibex_trails/services/notifications.dart';

const _notifications = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const _alarmAudio = MethodChannel('ibextrails/alarm_audio');

/// Checks [wav] is 16-bit mono PCM and returns (seconds, peak 0..1).
(double, double) _measure(Uint8List wav) {
  final b = ByteData.sublistView(wav);
  String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
  expect([tag(0), tag(8), tag(12), tag(36)], ['RIFF', 'WAVE', 'fmt ', 'data']);
  expect(b.getUint16(20, Endian.little), 1, reason: 'PCM');
  expect(b.getUint16(22, Endian.little), 1, reason: 'mono');
  expect(b.getUint16(34, Endian.little), 16, reason: '16-bit');
  final samples = b.getUint32(40, Endian.little) ~/ 2;
  var peak = 0;
  for (var i = 0; i < samples; i++) {
    final s = b.getInt16(44 + 2 * i, Endian.little).abs();
    if (s > peak) peak = s;
  }
  return (samples / b.getUint32(24, Endian.little), peak / 32768);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each sound is different and has a channel of its own', () {
    final files = {for (final s in AlarmSound.values) s.file};
    final channels = {for (final s in AlarmSound.values) s.channelId};
    expect(files, hasLength(AlarmSound.values.length));
    expect(channels, hasLength(AlarmSound.values.length));
    // Android keeps the sound a channel was created with, forever.
    expect(channels.intersection(Notifier.replacedChannels.toSet()), isEmpty);
  });

  test('each sound plays from its channel, on the alarm stream', () {
    for (final sound in AlarmSound.values) {
      final d = Notifier.androidDetails(sound);
      expect(d.channelId, sound.channelId);
      expect(d.playSound, isTrue);
      expect(
        (d.sound! as RawResourceAndroidNotificationSound).sound,
        sound.file,
      );
      expect(d.audioAttributesUsage, AudioAttributesUsage.alarm);
      expect(d.importance.value, greaterThanOrEqualTo(Importance.high.value));
    }
  });

  test('each sound is bundled with both apps, at full scale', () {
    final keep = File('android/app/src/main/res/raw/keep.xml')
        .readAsStringSync();
    final xcode = File('ios/Runner.xcodeproj/project.pbxproj')
        .readAsStringSync();
    for (final sound in AlarmSound.values) {
      final wav = File('android/app/src/main/res/raw/${sound.file}.wav')
          .readAsBytesSync();
      expect(
        File('ios/Runner/Sounds/${sound.file}.wav').readAsBytesSync(),
        wav,
        reason: 'the same sound on iPhone',
      );
      // Release builds drop resources only referenced by name.
      expect(keep, contains('@raw/${sound.file}'));
      expect(xcode, contains('${sound.file}.wav in Resources'));

      final (seconds, peak) = _measure(wav);
      // The Android volume boost lasts [AlarmSound.length].
      final length = sound.length.inMilliseconds / 1000;
      expect(
        seconds,
        inInclusiveRange(length - 0.2, length),
        reason: sound.file,
      );
      expect(peak, greaterThan(0.85), reason: sound.file);
    }
  });

  group('an alert', () {
    late List<MethodCall> calls;
    late bool iosPlays;

    setUp(() {
      calls = [];
      iosPlays = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_notifications, (c) async {
        calls.add(c);
        return c.method == 'initialize' ? true : null;
      });
      messenger.setMockMethodCallHandler(_alarmAudio, (c) async {
        calls.add(c);
        return c.method == 'play' ? iosPlays : null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(_notifications, null);
        messenger.setMockMethodCallHandler(_alarmAudio, null);
        debugDefaultTargetPlatformOverride = null;
        IsolateNameServer.removePortNameMapping(actionPortName);
      });
    });

    Future<Notifier> ready(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      if (platform == TargetPlatform.iOS) {
        IOSFlutterLocalNotificationsPlugin.registerWith();
      } else {
        AndroidFlutterLocalNotificationsPlugin.registerWith();
      }
      final notifier = Notifier();
      await notifier.init();
      calls.clear();
      return notifier;
    }

    List<Map<Object?, Object?>> shown() => [
      for (final c in calls)
        if (c.method == 'show')
          (c.arguments as Map)['platformSpecifics'] as Map<Object?, Object?>,
    ];

    test('Android: the channels the sounds replaced are removed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      await Notifier().init();
      expect([
        for (final c in calls)
          if (c.method == 'deleteNotificationChannel') c.arguments,
      ], Notifier.replacedChannels);
    });

    test('Android: the alarm volume goes up before the sound plays', () async {
      final notifier = await ready(TargetPlatform.android);
      await notifier.alert(NoteId.offRoute, 'Off route', 'You are 80 m off.');

      expect(calls.map((c) => c.method), ['boostAlarmVolume', 'show']);
      expect(calls.first.arguments, {
        'channel': 'alarms',
        'ms': AlarmSound.alarm.length.inMilliseconds + 3000,
      });
      final android = shown().single;
      expect(android['channelId'], 'alarms');
      expect(android['sound'], 'ibex_alarm');
      expect(android['audioAttributesUsage'], AudioAttributesUsage.alarm.value);
    });

    test('Android: SOS and fuel reminders sound different', () async {
      final notifier = await ready(TargetPlatform.android);
      await notifier.alert(
        NoteId.group('r2/sos/'),
        'Sara: SOS',
        'A group member needs help.',
        sound: AlarmSound.sos,
      );
      await notifier.fuel(
        const FuelReminder(
          carbs: 25,
          fluidMl: 0,
          suggestion: [(FuelItem(id: 'gel', name: 'Gel', carbs: 25), 1)],
        ),
      );

      expect(
        [for (final c in calls) c.method],
        ['boostAlarmVolume', 'show', 'boostAlarmVolume', 'show'],
      );
      expect(shown().map((n) => n['sound']), ['ibex_sos', 'ibex_fuel']);
      expect(shown().map((n) => n['channelId']), ['sos', 'fuel_reminders']);
      expect(shown().last['actions'], hasLength(2), reason: 'Ate it, In 5 min');
    });

    test(
      'iOS: the app plays the sound and the notification is quiet',
      () async {
        final notifier = await ready(TargetPlatform.iOS);
        await notifier.alert(NoteId.offRoute, 'Off route', 'You are 80 m off.');

        expect(calls.map((c) => c.method), ['play', 'show']);
        expect(calls.first.arguments, {'name': 'ibex_alarm'});
        expect(shown().single['presentSound'], isFalse);
        expect(shown().single['sound'], isNull, reason: 'it would play twice');
      },
    );

    test("iOS: when the app can't play it, the notification does", () async {
      iosPlays = false;
      final notifier = await ready(TargetPlatform.iOS);
      await notifier.alert(
        NoteId.group('r2/sos/'),
        'Sara: SOS',
        'A group member needs help.',
        sound: AlarmSound.sos,
      );

      expect(shown().single['presentSound'], isTrue);
      expect(shown().single['sound'], 'ibex_sos.wav');
    });
  });
}
