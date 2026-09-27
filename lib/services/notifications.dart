import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fuel.dart';
import 'settings.dart';

/// Notification action ids.
abstract final class NoteAction {
  static const fuelAte = 'fuel_ate';
  static const fuelSnooze = 'fuel_snooze';
  static const fuelCategory = 'fuel';
}

/// Name under which the running app listens for notification actions.
const actionPortName = 'ibextrails_notification_actions';

/// Runs in a separate background isolate when a notification button is
/// tapped without opening the app (e.g. "Ate it" on the lock screen).
///
/// If the app is running (it usually is during a run, kept alive by the
/// location service), the action goes straight to it. Otherwise it is
/// queued in SharedPreferences for the next session to pick up.
@pragma('vm:entry-point')
Future<void> onBackgroundNotificationAction(NotificationResponse r) =>
    deliverNotificationAction(
      r.actionId,
      r.payload,
      DateTime.now(),
      registerPlugins: true,
    );

@visibleForTesting
Future<void> deliverNotificationAction(
  String? actionId,
  String? payload,
  DateTime at, {
  bool registerPlugins = false,
}) async {
  final message = <String, Object?>{
    'a': actionId,
    'p': payload,
    't': at.millisecondsSinceEpoch,
  };
  final port = IsolateNameServer.lookupPortByName(actionPortName);
  if (port != null) {
    port.send(message);
    return;
  }
  if (registerPlugins) DartPluginRegistrant.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(pendingActionsKey) ?? <String>[];
  list.add(jsonEncode(message));
  await prefs.setStringList(pendingActionsKey, list);
}

/// Local notifications for alerts that must get through while the phone is
/// in a pocket: off route, wrong way, SOS from a group member, etc.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Receives notification actions (button taps) while the app is
  /// running. Set by the active run.
  void Function(String? actionId, String? payload, DateTime at)? onAction;

  ReceivePort? _actionPort;

  /// Lets the background isolate that handles button taps hand them to
  /// this (UI) isolate directly.
  void listenForActions() {
    if (_actionPort != null) return;
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(actionPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, actionPortName);
    port.listen((message) {
      if (message is! Map) return;
      onAction?.call(
        message['a'] as String?,
        message['p'] as String?,
        DateTime.fromMillisecondsSinceEpoch(message['t'] as int),
      );
    });
    _actionPort = port;
  }

  static const _alertChannel = AndroidNotificationDetails(
    'alerts',
    'Navigation & safety alerts',
    channelDescription: 'Off route, wrong way, SOS and group alerts',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.alarm,
    visibility: NotificationVisibility.public,
    enableVibration: true,
  );

  static const _infoChannel = AndroidNotificationDetails(
    'info',
    'Run updates',
    channelDescription: 'Back on route, announcements, connection changes',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  Future<void> init() async {
    if (kIsWeb) return;
    listenForActions();
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
            notificationCategories: [
              DarwinNotificationCategory(
                NoteAction.fuelCategory,
                actions: [
                  DarwinNotificationAction.plain(NoteAction.fuelAte, 'Ate it'),
                  DarwinNotificationAction.plain(
                    NoteAction.fuelSnooze,
                    'In 5 min',
                  ),
                ],
              ),
            ],
          ),
        ),
        onDidReceiveNotificationResponse: (r) =>
            onAction?.call(r.actionId, r.payload, DateTime.now()),
        onDidReceiveBackgroundNotificationResponse:
            onBackgroundNotificationAction,
      );
      _ready = true;
    } on Object catch (e) {
      debugPrint('Notifications unavailable: $e');
    }
  }

  /// Asks for permission to show notifications (Android 13+, iOS).
  Future<void> requestPermission() async {
    if (!_ready) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, sound: true, badge: false);
  }

  /// Loud, vibrating alert. Reusing an [id] replaces the earlier one.
  Future<void> alert(int id, String title, String body) async {
    if (!_ready) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _alertChannel.channelId,
          _alertChannel.channelName,
          channelDescription: _alertChannel.channelDescription,
          importance: _alertChannel.importance,
          priority: _alertChannel.priority,
          category: _alertChannel.category,
          visibility: _alertChannel.visibility,
          vibrationPattern: Int64List.fromList([0, 600, 250, 600, 250, 600]),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }

  /// Quiet informational notification.
  Future<void> info(int id, String title, String body) async {
    if (!_ready) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: _infoChannel,
        iOS: DarwinNotificationDetails(presentAlert: true),
      ),
    );
  }

  /// Fuel reminder with "Ate it" / "In 5 min" buttons. The payload carries
  /// the suggested servings so "Ate it" logs exactly those.
  Future<void> fuel(FuelReminder r) async {
    if (!_ready) return;
    final payload = jsonEncode({
      's': [
        for (final (item, n) in r.suggestion) [item.id, n],
      ],
    });
    await _plugin.show(
      id: NoteId.fuel,
      title: r.title,
      body: r.body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'fuel',
          'Fuel & hydration reminders',
          channelDescription: 'When to eat and drink, from your fuel plan',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          vibrationPattern: Int64List.fromList([0, 300, 150, 300]),
          actions: [
            if (r.suggestion.isNotEmpty)
              const AndroidNotificationAction(NoteAction.fuelAte, 'Ate it'),
            const AndroidNotificationAction(NoteAction.fuelSnooze, 'In 5 min'),
          ],
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          categoryIdentifier: NoteAction.fuelCategory,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }

  Future<void> cancel(int id) async {
    if (_ready) await _plugin.cancel(id: id);
  }
}

/// Stable notification ids.
abstract final class NoteId {
  static const offRoute = 1;
  static const wrongWay = 2;
  static const announcement = 3;
  static const connection = 4;
  static const jump = 5;
  static const fuel = 6;
  static const checkpoint = 7;
  static const cutoff = 8;
  static const turn = 9;
  static const allIn = 10;

  /// Group alerts get ids derived from participant + kind.
  static int group(String key) => 1000 + (key.hashCode & 0x3fffffff) % 100000;
}
