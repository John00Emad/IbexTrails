import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

enum RelayState { offline, connecting, online }

class RelayMessage {
  const RelayMessage(this.topic, this.payload, {required this.retained});
  final String topic;
  final Uint8List payload;
  final bool retained;
}

/// Thin wrapper around an MQTT connection that keeps trying to (re)connect
/// for as long as it is running. Runners drop in and out of coverage all the
/// time on trails, so connection loss is normal, not an error.
class RelayClient {
  RelayClient({
    required this.host,
    required this.port,
    required this.tls,
    required this.clientId,
  });

  final String host;
  final int port;
  final bool tls;
  final String clientId;

  final state = ValueNotifier(RelayState.offline);
  final _messages = StreamController<RelayMessage>.broadcast();
  final _subscriptions = <String>{};

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  bool _running = false;
  int _attempt = 0;
  Timer? _retry;

  /// Last error message, for display in settings/diagnostics.
  String? lastError;

  Stream<RelayMessage> get messages => _messages.stream;
  bool get isOnline => state.value == RelayState.online;

  /// Starts connecting in the background. Returns immediately.
  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> _connect() async {
    if (!_running) return;
    state.value = RelayState.connecting;
    final client = MqttServerClient.withPort(host, clientId, port)
      ..secure = tls
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 15000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..logging(on: false)
      ..setProtocolV311()
      ..onConnected = _onConnected
      ..onAutoReconnect = (() => state.value = RelayState.connecting)
      ..onAutoReconnected = _onConnected
      ..onDisconnected = _onDisconnected;
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();
    _client = client;
    try {
      await client.connect();
    } on Object catch (e) {
      lastError = e.toString();
      client.disconnect();
    }
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _attempt = 0;
      lastError = null;
      _updates = client.updates?.listen(_onUpdates);
      for (final t in _subscriptions) {
        client.subscribe(t, MqttQos.atLeastOnce);
      }
      state.value = RelayState.online;
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    state.value = RelayState.offline;
    if (!_running) return;
    _attempt++;
    final seconds = math.min(60, 2 << math.min(_attempt, 5));
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), () {
      _updates?.cancel();
      _updates = null;
      _connect();
    });
  }

  void _onConnected() => state.value = RelayState.online;

  void _onDisconnected() {
    // With autoReconnect the client handles it; this fires on a real stop.
    if (_running &&
        _client?.connectionStatus?.state != MqttConnectionState.connecting) {
      state.value = RelayState.offline;
    }
  }

  void _onUpdates(List<MqttReceivedMessage<MqttMessage>> batch) {
    for (final m in batch) {
      final msg = m.payload;
      if (msg is! MqttPublishMessage) continue;
      _messages.add(
        RelayMessage(
          m.topic,
          Uint8List.fromList(msg.payload.message.toList()),
          retained: msg.header?.retain ?? false,
        ),
      );
    }
  }

  void subscribe(String topic) {
    _subscriptions.add(topic);
    if (isOnline) _client?.subscribe(topic, MqttQos.atLeastOnce);
  }

  /// Publishes if online. Returns false (and drops the message) otherwise;
  /// callers keep their own latest state and republish on reconnect.
  bool publish(
    String topic,
    List<int> payload, {
    bool retain = false,
    bool reliable = false,
  }) {
    final client = _client;
    if (client == null || !isOnline) return false;
    try {
      client.publishMessage(
        topic,
        reliable ? MqttQos.atLeastOnce : MqttQos.atMostOnce,
        Uint8Buffer()..addAll(payload),
        retain: retain,
      );
      return true;
    } on Object catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  /// Clears a retained message.
  bool clearRetained(String topic) =>
      publish(topic, const [], retain: true, reliable: true);

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    await _updates?.cancel();
    _updates = null;
    _client?.autoReconnect = false;
    _client?.disconnect();
    _client = null;
    state.value = RelayState.offline;
  }

  Future<void> dispose() async {
    await stop();
    await _messages.close();
    state.dispose();
  }
}
