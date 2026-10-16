import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The sounds for alerts that have to be heard with the phone in a pocket,
/// over wind and music. Each one is different, so you know what happened
/// before you look, and none sounds like an ordinary notification.
///
/// They are bundled with the app in android/app/src/main/res/raw/ and
/// ios/Runner/Sounds/, made by test/tool/alarm_sounds_test.dart.
enum AlarmSound {
  /// Time to eat or drink: a bell chime.
  fuel(
    file: 'ibex_fuel',
    label: 'Fuel reminder',
    meaning: 'A chime: time to eat or drink',
    channelId: 'fuel_reminders',
    channelName: 'Fuel & hydration reminders',
    channelDescription: 'When to eat and drink, from your fuel plan',
    length: Duration(milliseconds: 2600),
    vibration: [0, 300, 150, 300],
  ),

  /// Off route, wrong way, cut-offs, messages from the organizer and alerts
  /// about other runners: fast beeps.
  alarm(
    file: 'ibex_alarm',
    label: 'Alarm',
    meaning:
        'Fast beeps: off route, wrong way, cut-offs, organizer messages '
        'and group alerts',
    channelId: 'alarms',
    channelName: 'Navigation & safety alarms',
    channelDescription:
        'Off route, wrong way, cut-offs, organizer messages and group alerts',
    length: Duration(milliseconds: 2600),
    vibration: [0, 600, 250, 600, 250, 600],
  ),

  /// Someone in the group pressed SOS: a siren.
  sos(
    file: 'ibex_sos',
    label: 'SOS',
    meaning: 'A siren: someone in the group needs help',
    channelId: 'sos',
    channelName: 'SOS alarms',
    channelDescription: 'A group member needs help',
    length: Duration(milliseconds: 3100),
    // S-O-S in Morse code.
    vibration: [
      0, 150, 100, 150, 100, 150, 300, //
      450, 100, 450, 100, 450, 300, //
      150, 100, 150, 100, 150,
    ],
  );

  const AlarmSound({
    required this.file,
    required this.label,
    required this.meaning,
    required this.channelId,
    required this.channelName,
    required this.channelDescription,
    required this.length,
    required this.vibration,
  });

  /// Sound file name, without the .wav extension.
  final String file;
  final String label;

  /// What the sound means, for the settings screen.
  final String meaning;

  /// Android notification channel. A channel's sound can never change once
  /// the channel exists, so each sound has its own.
  final String channelId;
  final String channelName;
  final String channelDescription;

  /// How long the sound plays.
  final Duration length;

  /// Android vibration pattern: off/on times in milliseconds.
  final List<int> vibration;
}

/// Makes the alarm sounds as loud as the phone allows.
class AlarmAudio {
  static const _channel = MethodChannel('ibextrails/alarm_audio');

  /// Call just before showing a notification that plays [sound]. Returns
  /// true if the app played the sound itself, so the notification must
  /// stay quiet.
  ///
  /// Android: the notification channel plays the sound on the alarm stream,
  /// which rings even on silent or vibrate. This turns the alarm volume up
  /// to the maximum while it plays, then back to where it was.
  ///
  /// iOS: apps can't change the volume, and the silent switch mutes
  /// notification sounds. So the app plays the sound itself at full volume,
  /// over any music (like its spoken turn warnings), and vibrates.
  Future<bool> play(AlarmSound sound) async {
    if (kIsWeb) return false;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          await _channel.invokeMethod<void>('boostAlarmVolume', {
            'channel': sound.channelId,
            'ms': (sound.length + const Duration(seconds: 3)).inMilliseconds,
          });
        case TargetPlatform.iOS:
          return await _channel.invokeMethod<bool>('play', {
                'name': sound.file,
              }) ??
              false;
        default:
          break;
      }
    } on Object catch (e) {
      debugPrint('Alarm audio unavailable: $e');
    }
    return false;
  }
}
