import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for alerts that must get through while the phone is
/// in a pocket: off route, wrong way, SOS from a group member, etc.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

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
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
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

  /// Group alerts get ids derived from participant + kind.
  static int group(String key) => 1000 + (key.hashCode & 0x3fffffff) % 100000;
}
