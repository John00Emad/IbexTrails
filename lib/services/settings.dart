import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/protocol.dart';

/// A relay (MQTT broker) the app can use to exchange encrypted messages.
class RelayPreset {
  const RelayPreset(this.label, this.host, this.port, {this.tls = true});
  final String label;
  final String host;
  final int port;
  final bool tls;
}

/// Free public brokers. Payloads are end-to-end encrypted, so the broker
/// only relays opaque bytes. Groups can also run their own (e.g. Mosquitto).
const relayPresets = [
  RelayPreset('EMQX public broker', 'broker.emqx.io', 8883),
  RelayPreset('HiveMQ public broker', 'broker.hivemq.com', 8883),
  RelayPreset('Mosquitto test broker', 'test.mosquitto.org', 8886),
];

enum MapStyle {
  topo('OpenTopoMap (contours & trails)'),
  osm('OpenStreetMap');

  const MapStyle(this.label);
  final String label;
}

/// The event this device is currently part of, remembered so a run survives
/// the app being closed or the phone restarting.
class ActiveEvent {
  const ActiveEvent({
    required this.code,
    required this.role,
    required this.startedAt,
  });

  final String code;
  final Role role;
  final DateTime startedAt;
}

/// Persistent user preferences.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  /// Random, stable, anonymous id for this install.
  String get participantId {
    var id = _prefs.getString('participantId');
    if (id == null) {
      final rng = math.Random.secure();
      id = List.generate(
        8,
        (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _prefs.setString('participantId', id);
    }
    return id;
  }

  String get displayName => _prefs.getString('displayName') ?? '';
  set displayName(String v) => _set('displayName', v.trim());

  String get phone => _prefs.getString('phone') ?? '';
  set phone(String v) => _set('phone', v.trim());

  String get relayHost =>
      _prefs.getString('relayHost') ?? relayPresets.first.host;
  set relayHost(String v) => _set('relayHost', v.trim());

  int get relayPort => _prefs.getInt('relayPort') ?? relayPresets.first.port;
  set relayPort(int v) => _set('relayPort', v);

  bool get relayTls => _prefs.getBool('relayTls') ?? relayPresets.first.tls;
  set relayTls(bool v) => _set('relayTls', v);

  /// Off-route alarm distance in metres.
  double get offRouteMeters => _prefs.getDouble('offRouteMeters') ?? 50;
  set offRouteMeters(double v) => _set('offRouteMeters', v);

  /// Seconds between location reports to the group.
  int get reportSeconds => _prefs.getInt('reportSeconds') ?? 20;
  set reportSeconds(int v) => _set('reportSeconds', v);

  MapStyle get mapStyle =>
      MapStyle.values.asNameMap()[_prefs.getString('mapStyle')] ??
      MapStyle.topo;
  set mapStyle(MapStyle v) => _set('mapStyle', v.name);

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? false;
  set keepScreenOn(bool v) => _set('keepScreenOn', v);

  ActiveEvent? get activeEvent {
    final code = _prefs.getString('activeCode');
    final started = _prefs.getInt('activeStarted');
    if (code == null || started == null) return null;
    return ActiveEvent(
      code: code,
      role: Role.fromCode(_prefs.getString('activeRole')),
      startedAt: DateTime.fromMillisecondsSinceEpoch(started),
    );
  }

  set activeEvent(ActiveEvent? e) {
    if (e == null) {
      _prefs
        ..remove('activeCode')
        ..remove('activeRole')
        ..remove('activeStarted');
    } else {
      _prefs
        ..setString('activeCode', e.code)
        ..setString('activeRole', e.role.code)
        ..setInt('activeStarted', e.startedAt.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  void _set(String key, Object value) {
    switch (value) {
      case String v:
        _prefs.setString(key, v);
      case int v:
        _prefs.setInt(key, v);
      case double v:
        _prefs.setDouble(key, v);
      case bool v:
        _prefs.setBool(key, v);
    }
    notifyListeners();
  }
}
