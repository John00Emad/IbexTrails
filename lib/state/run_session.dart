import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../core/crypto.dart';
import '../core/event_code.dart';
import '../core/geo.dart';
import '../core/gpx.dart';
import '../core/group.dart';
import '../core/protocol.dart';
import '../core/route.dart';
import '../core/route_matcher.dart';
import '../services/location_service.dart';
import '../services/notifications.dart';
import '../services/relay_client.dart';
import '../services/route_library.dart';
import '../services/settings.dart';

/// One run: navigation along an optional route, plus (in a group event)
/// sharing your position and seeing everyone else's.
class RunSession extends ChangeNotifier {
  RunSession._({
    required this.settings,
    required this.notifier,
    required this.role,
    this.code,
    this.locationSource,
  });

  /// Replaces the device GPS, for tests and simulations.
  @visibleForTesting
  final Stream<Position> Function()? locationSource;

  final AppSettings settings;
  final Notifier notifier;
  final Role role;

  /// Normalized event code, or null for a solo run.
  final String? code;

  bool get isEvent => code != null;
  bool get isOrganizer => isEvent && role == Role.organizer;

  /// Organizer and sweepers get alerts about other people.
  bool get watchesGroup => role == Role.organizer || role == Role.sweeper;

  String get myId => settings.participantId;
  String get myName =>
      settings.displayName.isEmpty ? role.label : settings.displayName;

  // ---- Event / network --------------------------------------------------
  EventCipher? _cipher;
  EventTopics? topics;
  RelayClient? relay;
  EventInfo? event;
  bool eventEnded = false;
  Announcement? announcement;
  final group = Group();
  List<GroupAlert> alerts = const [];
  final _latch = AlertLatch();
  final alertPolicy = const AlertPolicy();
  bool _eventInfoDirty = false;
  final DateTime joinedAt = DateTime.now();

  // ---- Navigation --------------------------------------------------------
  TrailRoute? route;
  RouteMatcher? _matcher;
  RouteMatch? match;
  Position? fix;
  String? locationError;
  DateTime? startedAt;
  double distanceRun = 0;
  final List<GeoPoint> recorded = [];
  final List<DateTime> recordedTimes = [];
  bool sos = false;
  int? battery;

  // ---- Reporting ---------------------------------------------------------
  final List<TrailPoint> _pendingTrail = [];
  RunnerStatus? _lastSentStatus;
  Timer? _reportTimer;
  Timer? _alertTimer;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<RelayMessage>? _messageSub;
  bool _disposed = false;

  // ------------------------------------------------------------------------
  // Construction
  // ------------------------------------------------------------------------

  /// Navigate a route on your own. No network needed.
  static Future<RunSession> solo(
    AppSettings settings,
    Notifier notifier, {
    TrailRoute? route,
    @visibleForTesting Stream<Position> Function()? locationSource,
  }) async {
    final s = RunSession._(
      settings: settings,
      notifier: notifier,
      role: Role.runner,
      locationSource: locationSource,
    );
    if (route != null) s._setRoute(route);
    await s._startTracking();
    return s;
  }

  /// Create a new group event. The returned session's [code] is what
  /// participants enter to join.
  static Future<RunSession> organize(
    AppSettings settings,
    Notifier notifier, {
    required String eventName,
    TrailRoute? route,
    @visibleForTesting Stream<Position> Function()? locationSource,
  }) async {
    final code = normalizeEventCode(generateEventCode())!;
    final s = RunSession._(
      settings: settings,
      notifier: notifier,
      role: Role.organizer,
      code: code,
      locationSource: locationSource,
    );
    // Round-trip through the share encoding so the organizer navigates the
    // exact same geometry as everyone else (progress must be comparable).
    final shared = route == null
        ? null
        : TrailRoute.fromShareJson(route.toShareJson());
    s.event = EventInfo(
      name: eventName,
      organizerId: settings.participantId,
      organizerName: s.myName,
      organizerPhone: settings.phone,
      updated: DateTime.now(),
      route: shared,
    );
    if (shared != null) s._setRoute(shared);
    s._eventInfoDirty = true;
    await s._connect();
    await s._startTracking();
    return s;
  }

  /// Join an existing event with the code from the organizer.
  static Future<RunSession> join(
    AppSettings settings,
    Notifier notifier, {
    required String code,
    required Role role,
    @visibleForTesting Stream<Position> Function()? locationSource,
  }) async {
    final normalized = normalizeEventCode(code);
    if (normalized == null) {
      throw const FormatException('That does not look like an event code');
    }
    final s = RunSession._(
      settings: settings,
      notifier: notifier,
      role: role,
      code: normalized,
      locationSource: locationSource,
    );
    await s._connect();
    await s._startTracking();
    return s;
  }

  /// Re-enter an event after the app was closed.
  static Future<RunSession> resume(
    AppSettings settings,
    Notifier notifier,
    ActiveEvent active,
  ) => join(settings, notifier, code: active.code, role: active.role);

  String get displayCode => code == null ? '' : formatEventCode(code!);

  // ------------------------------------------------------------------------
  // Location
  // ------------------------------------------------------------------------

  Future<void> _startTracking() async {
    startedAt ??= DateTime.now();
    final source = locationSource;
    if (source == null) {
      await notifier.requestPermission();
      try {
        await LocationService.ensurePermission();
      } on LocationUnavailable catch (e) {
        locationError = e.message;
        notifyListeners();
        return;
      }
    }
    locationError = null;
    _positionSub = (source ?? LocationService.track)().listen(
      _onFix,
      onError: (Object e) {
        locationError = 'Location error: $e';
        notifyListeners();
      },
    );
    if (isEvent) {
      _reportTimer = Timer.periodic(
        Duration(seconds: settings.reportSeconds),
        (_) => _publishReport(),
      );
    }
  }

  /// Retry after the user fixed permissions/GPS.
  Future<void> retryLocation() async {
    await _positionSub?.cancel();
    _reportTimer?.cancel();
    await _startTracking();
    notifyListeners();
  }

  void _onFix(Position p) {
    final here = GeoPoint(p.latitude, p.longitude, p.altitude);
    final prevFix = fix;
    fix = p;

    // Distance and recording, ignoring jitter and very poor fixes.
    if (p.accuracy <= 35) {
      final last = recorded.isEmpty ? null : recorded.last;
      final step = last == null ? double.infinity : distanceBetween(last, here);
      if (step >= 5) {
        if (last != null) distanceRun += step;
        recorded.add(here);
        recordedTimes.add(p.timestamp);
        _pendingTrail.add(TrailPoint(here.lat, here.lon, p.timestamp));
        if (_pendingTrail.length > 60) {
          // Keep every other point: a coarser trail is better than none.
          final thinned = [
            for (var i = 0; i < _pendingTrail.length; i += 2) _pendingTrail[i],
          ];
          _pendingTrail
            ..clear()
            ..addAll(thinned);
        }
      }
    }

    final matcher = _matcher;
    if (matcher != null) {
      matcher.offRouteThreshold = settings.offRouteMeters;
      final before = match;
      match = matcher.update(here, accuracy: p.accuracy);
      _reactToMatch(before, match!);
    }

    if (prevFix == null && isEvent) _publishReport();
    if (_lastSentStatus != null && status != _lastSentStatus) _publishReport();
    notifyListeners();
  }

  void _reactToMatch(RouteMatch? before, RouteMatch now) {
    if (now.offRoute && !(before?.offRoute ?? false)) {
      HapticFeedback.heavyImpact();
      final dir = fix == null
          ? ''
          : ' Head ${compassName(bearingBetween(GeoPoint(fix!.latitude, fix!.longitude), now.nearest))} to get back.';
      notifier.alert(
        NoteId.offRoute,
        'Off route',
        'You are ${formatDistance(now.distance)} from the route.$dir',
      );
    } else if (!now.offRoute && (before?.offRoute ?? false)) {
      notifier.cancel(NoteId.offRoute);
      notifier.info(
        NoteId.offRoute,
        'Back on route',
        '${formatDistance(route!.length - now.along)} to go.',
      );
    }
    if (now.wrongWay && !(before?.wrongWay ?? false)) {
      HapticFeedback.heavyImpact();
      notifier.alert(
        NoteId.wrongWay,
        'Wrong way?',
        'You are heading back along the route.',
      );
    } else if (!now.wrongWay && (before?.wrongWay ?? false)) {
      notifier.cancel(NoteId.wrongWay);
    }
    if (now.jump > 500 && !now.finished) {
      notifier.alert(
        NoteId.jump,
        'Check your route',
        'You joined the route ${formatDistance(now.jump)} further along '
            'than expected. Did you take a wrong turn?',
      );
    }
    if (now.finished && !(before?.finished ?? false)) {
      final t = startedAt == null
          ? ''
          : ' in ${formatDuration(DateTime.now().difference(startedAt!))}';
      notifier.info(
        NoteId.offRoute,
        'Finished!',
        '${formatDistance(distanceRun)}$t. Well done!',
      );
    }
  }

  RunnerStatus get status {
    if (sos) return RunnerStatus.sos;
    final m = match;
    if (m == null) return RunnerStatus.ok;
    if (m.finished) return RunnerStatus.finished;
    if (m.offRoute) return RunnerStatus.offRoute;
    if (m.wrongWay) return RunnerStatus.wrongWay;
    return RunnerStatus.ok;
  }

  // ------------------------------------------------------------------------
  // Route
  // ------------------------------------------------------------------------

  void _setRoute(TrailRoute r) {
    route = r;
    _matcher = RouteMatcher(r, offRouteThreshold: settings.offRouteMeters);
    match = null;
    final f = fix;
    if (f != null) {
      match = _matcher!.update(
        GeoPoint(f.latitude, f.longitude),
        accuracy: f.accuracy,
      );
    }
  }

  /// Load a route locally. For the organizer this also shares it with the
  /// group; for others it only affects this device.
  void useRoute(TrailRoute r) {
    if (isOrganizer) {
      final shared = TrailRoute.fromShareJson(r.toShareJson());
      _setRoute(shared);
      event = EventInfo(
        name: event?.name ?? 'Group run',
        organizerId: myId,
        organizerName: myName,
        organizerPhone: settings.phone,
        updated: DateTime.now(),
        route: shared,
      );
      _eventInfoDirty = true;
      _flushEventInfo();
    } else {
      _setRoute(r);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------------
  // Network
  // ------------------------------------------------------------------------

  Future<void> _connect() async {
    _cipher = await EventCipher.forCode(code!);
    topics = EventTopics(_cipher!.topicId);
    final r = RelayClient(
      host: settings.relayHost,
      port: settings.relayPort,
      tls: settings.relayTls,
      clientId: 'ibx_${myId}_${math.Random().nextInt(1 << 16)}',
    );
    relay = r;
    _messageSub = r.messages.listen(_onRelayMessage);
    r.state.addListener(_onRelayState);
    r.subscribe(topics!.all);
    r.start();
    settings.activeEvent = ActiveEvent(
      code: code!,
      role: role,
      startedAt: joinedAt,
    );
    _alertTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _evaluateAlerts(),
    );
  }

  void _onRelayState() {
    if (relay?.isOnline ?? false) {
      _flushEventInfo();
      _publishReport();
    }
    notifyListeners();
  }

  Future<void> _flushEventInfo() async {
    final info = event;
    final r = relay;
    if (!_eventInfoDirty || info == null || r == null || !isOrganizer) return;
    final payload = await _cipher!.seal(info.toJson());
    if (r.publish(topics!.event, payload, retain: true, reliable: true)) {
      _eventInfoDirty = false;
    }
  }

  Future<void> _publishReport() async {
    final r = relay;
    final f = fix;
    if (r == null || f == null || !r.isOnline || _disposed) return;
    try {
      battery = await Battery().batteryLevel;
    } on Object {
      // Not available on this platform.
    }
    final m = match;
    final report = PositionReport(
      id: myId,
      name: myName,
      role: role,
      time: DateTime.now(),
      lat: f.latitude,
      lon: f.longitude,
      accuracy: f.accuracy,
      elevation: f.altitude,
      speed: f.speed >= 0 ? f.speed : null,
      along: m?.along,
      offBy: m?.distance,
      status: status,
      battery: battery,
      // The last trail point is the current position; don't repeat it.
      trail: _pendingTrail.length > 1
          ? _pendingTrail.sublist(0, _pendingTrail.length - 1)
          : const [],
    );
    final sent = _pendingTrail.length;
    final payload = await _cipher!.seal(report.toJson());
    if (r.publish(topics!.position(myId), payload, retain: true)) {
      _pendingTrail.removeRange(0, math.min(sent, _pendingTrail.length));
      _lastSentStatus = report.status;
      // Show ourselves in the group list immediately.
      group.apply(report, DateTime.now());
    }
  }

  Future<void> _onRelayMessage(RelayMessage m) async {
    final t = topics;
    final cipher = _cipher;
    if (t == null || cipher == null) return;

    if (m.topic == t.event) {
      if (m.payload.isEmpty) {
        if (!isOrganizer) {
          eventEnded = true;
          notifier.info(
            NoteId.announcement,
            'Event ended',
            'The organizer ended ${event?.name ?? 'the event'}.',
          );
          notifyListeners();
        }
        return;
      }
      final info = EventInfo.fromJson(await cipher.open(m.payload));
      if (info == null) return;
      final current = event;
      if (current != null && !info.updated.isAfter(current.updated)) return;
      event = info;
      eventEnded = false;
      final r = info.route;
      // The organizer keeps their own copy, except when resuming after the
      // app was closed.
      if (r != null && (!isOrganizer || route == null)) _setRoute(r);
      notifyListeners();
      return;
    }

    if (m.topic == t.announcement) {
      if (m.payload.isEmpty) return;
      final a = Announcement.fromJson(await cipher.open(m.payload));
      if (a == null || a.id == announcement?.id) return;
      announcement = a;
      final fresh =
          DateTime.now().difference(a.time) < const Duration(minutes: 30);
      if (fresh && !isOrganizer) {
        notifier.alert(NoteId.announcement, 'Message from ${a.from}', a.text);
      }
      notifyListeners();
      return;
    }

    final pid = t.participantOf(m.topic);
    if (pid != null) {
      if (m.payload.isEmpty) {
        group.remove(pid);
      } else {
        final report = PositionReport.fromJson(await cipher.open(m.payload));
        if (report == null || report.id != pid) return;
        if (group.apply(report, DateTime.now())) _evaluateAlerts();
      }
      notifyListeners();
    }
  }

  void _evaluateAlerts() {
    final all = group
        .alerts(DateTime.now(), alertPolicy)
        .where((a) => a.participant.id != myId)
        .toList();
    alerts = all;
    if (watchesGroup) {
      for (final a in _latch.newlyRaised(all)) {
        notifier.alert(
          NoteId.group(a.key),
          '${a.participant.name}: ${a.kind.label}',
          a.detail,
        );
      }
    } else {
      // Everyone hears about an SOS.
      for (final a in _latch.newlyRaised(
        all.where((a) => a.kind == AlertKind.sos).toList(),
      )) {
        notifier.alert(
          NoteId.group(a.key),
          '${a.participant.name}: SOS',
          'A group member needs help.',
        );
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------------

  void setSos(bool on) {
    sos = on;
    if (on) HapticFeedback.heavyImpact();
    _publishReport();
    notifyListeners();
  }

  /// Organizer broadcast. Returns false if offline.
  Future<bool> announce(String text) async {
    final r = relay;
    if (r == null || !isOrganizer) return false;
    final a = Announcement(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      from: myName,
      text: text.trim(),
      time: DateTime.now(),
    );
    final ok = r.publish(
      topics!.announcement,
      await _cipher!.seal(a.toJson()),
      retain: true,
      reliable: true,
    );
    if (ok) {
      announcement = a;
      notifyListeners();
    }
    return ok;
  }

  /// Saves what this device recorded as a GPX file.
  Future<File?> saveRecording() async {
    if (recorded.length < 2) return null;
    final name = event?.name ?? route?.name ?? 'IbexTrails run';
    return RouteLibrary.saveRecording(
      name,
      writeGpx(name: name, points: recorded, times: recordedTimes),
    );
  }

  /// Leave the run. The organizer can also [endEvent], which clears the
  /// event's data from the relay.
  Future<void> leave({bool endEvent = false}) async {
    final r = relay;
    if (r != null && r.isOnline) {
      if (endEvent && isOrganizer) {
        r.clearRetained(topics!.event);
        r.clearRetained(topics!.announcement);
        for (final p in group.participants) {
          r.clearRetained(topics!.position(p.id));
        }
      } else if (fix != null) {
        sos = false;
        final f = fix!;
        final report = PositionReport(
          id: myId,
          name: myName,
          role: role,
          time: DateTime.now(),
          lat: f.latitude,
          lon: f.longitude,
          status: RunnerStatus.left,
          along: match?.along,
        );
        r.publish(
          topics!.position(myId),
          await _cipher!.seal(report.toJson()),
          retain: true,
          reliable: true,
        );
      }
      // Give the last messages a moment to leave the device.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    settings.activeEvent = null;
    await notifier.cancel(NoteId.offRoute);
    await notifier.cancel(NoteId.wrongWay);
    dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _positionSub?.cancel();
    _messageSub?.cancel();
    _reportTimer?.cancel();
    _alertTimer?.cancel();
    relay?.state.removeListener(_onRelayState);
    relay?.dispose();
    super.dispose();
  }
}
