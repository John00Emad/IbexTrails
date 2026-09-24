import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../core/checkpoints.dart';
import '../core/course.dart';
import '../core/crypto.dart';
import '../core/event_code.dart';
import '../core/fuel.dart';
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
    this.startedAt,
  }) {
    notifier.onAction = (action, payload) =>
        handleNotificationAction(action, payload, DateTime.now());
  }

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

  // ---- Courses & checkpoints --------------------------------------------
  /// Courses (distances) received or created, by id.
  final Map<String, Course> courses = {};
  final Map<String, DateTime> _courseUpdated = {};
  final Set<String> _dirtyCourses = {};

  /// The course this device is navigating.
  Course? course;
  CheckpointTracker? checkpoints;
  CheckpointOutlook? outlook;
  final Set<String> _riskNotified = {};
  final Set<String> _missedNotified = {};

  // ---- Fuelling (private to this device) ---------------------------------
  FuelCoach? fuel;

  /// Reminder currently shown in the app, until logged or dismissed.
  FuelReminder? fuelReminder;

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
  Timer? _tick;
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
    // A solo run always starts fresh.
    settings.setRunData('fuel:solo', null);
    settings.setRunData('cp:solo', null);
    if (route != null) s._useCourse(Course.fromRoute(route, id: _localCourse));
    await s._startTracking();
    return s;
  }

  /// Create a new group event. The returned session's [code] is what
  /// participants enter to join.
  static Future<RunSession> organize(
    AppSettings settings,
    Notifier notifier, {
    required String eventName,
    List<Course> courses = const [],
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
    final now = DateTime.now();
    for (final c in courses) {
      // Round-trip through the share encoding so the organizer navigates
      // the exact same geometry as everyone else (progress must match).
      final shared = Course.fromShareJson(c.toShareJson());
      s.courses[shared.id] = shared;
      s._courseUpdated[shared.id] = now;
      s._dirtyCourses.add(shared.id);
    }
    s.event = EventInfo(
      name: eventName,
      organizerId: settings.participantId,
      organizerName: s.myName,
      organizerPhone: settings.phone,
      updated: now,
      courses: [for (final c in s.courses.values) c.info],
    );
    if (s.courses.isNotEmpty) s.selectCourse(s.courses.keys.first);
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
    DateTime? startedAt,
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
      startedAt: startedAt,
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
  ) => join(
    settings,
    notifier,
    code: active.code,
    role: active.role,
    startedAt: active.startedAt,
  );

  String get displayCode => code == null ? '' : formatEventCode(code!);

  // ------------------------------------------------------------------------
  // Location
  // ------------------------------------------------------------------------

  Future<void> _startTracking() async {
    startedAt ??= DateTime.now();
    if (fuel == null) _startFuel();
    _tick ??= Timer.periodic(const Duration(seconds: 10), (_) => _onTick());
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
      _updateCheckpoints(match!, here, DateTime.now());
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

  void _updateCheckpoints(RouteMatch m, GeoPoint here, DateTime now) {
    final tracker = checkpoints;
    if (tracker == null) return;
    final passed = tracker.update(m, here, now);
    outlook = tracker.outlook(now, runnerStart: startedAt);
    if (passed.isNotEmpty) {
      settings.setRunData('cp:$_runKey:${course!.id}', {
        for (final e in tracker.passed.entries)
          e.key: e.value.millisecondsSinceEpoch,
      });
      final cp = passed.last;
      final cutoff = course!.cutoffTime(cp, runnerStart: startedAt);
      final spare = cutoff == null
          ? ''
          : ' · ${_minutes(cutoff.difference(now))} before the cut-off';
      notifier.info(
        NoteId.checkpoint,
        '${cp.name} ✓',
        'Passed at ${_clock(now)}$spare.',
      );
      _publishReport();
    }
    final o = outlook;
    if (o != null && o.atRisk && !o.isMissed(now)) {
      if (_riskNotified.add(o.checkpoint.id)) {
        HapticFeedback.heavyImpact();
        notifier.alert(
          NoteId.cutoff,
          'Behind cut-off pace',
          'At this pace you reach ${o.checkpoint.name} at ${_clock(o.eta)}, '
              '${_minutes(-o.margin!)} after the ${_clock(o.cutoff!)} cut-off.',
        );
      }
    }
  }

  void _checkMissedCutoffs(DateTime now) {
    final tracker = checkpoints;
    if (tracker == null) return;
    for (final cp in tracker.missed(now, runnerStart: startedAt)) {
      if (!_missedNotified.add(cp.id)) continue;
      notifier.alert(
        NoteId.cutoff,
        'Cut-off passed: ${cp.name}',
        'The cut-off was ${_clock(course!.cutoffTime(cp, runnerStart: startedAt)!)}. '
            'Check in with the organizer.',
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

  static const _localCourse = 'local';

  /// Key for per-run saved state.
  String get _runKey => code ?? 'solo';

  /// Courses in the order the organizer listed them.
  List<Course> get courseList {
    final order = [for (final c in event?.courses ?? const []) c.id];
    int rank(Course c) {
      final i = order.indexOf(c.id);
      return i < 0 ? order.length : i;
    }

    return courses.values.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  /// The event offers several distances and this runner hasn't picked one.
  bool get needsCourseChoice =>
      isEvent && course == null && courseList.length > 1;

  /// Switch to course [id] (e.g. the 25 km).
  void selectCourse(String id) {
    final c = courses[id];
    if (c == null) return;
    _useCourse(c);
    if (code != null) settings.setCourseFor(code!, id);
    _publishReport();
    notifyListeners();
  }

  /// Navigate [c]. With [keepProgress] (same course, updated by the
  /// organizer) route matching and checkpoint passes carry over.
  void _useCourse(Course c, {bool keepProgress = false}) {
    final sameRoute =
        keepProgress &&
        route != null &&
        listEquals(route!.points, c.route.points);
    final previous = checkpoints;
    course = c;
    if (!sameRoute) _setRoute(c.route);
    final tracker = CheckpointTracker(c);
    if (keepProgress && previous != null) {
      tracker.restore({
        for (final e in previous.passed.entries)
          if (c.checkpoints.any((cp) => cp.id == e.key)) e.key: e.value,
      });
    } else {
      final saved = settings.runData('cp:$_runKey:${c.id}');
      if (saved is Map) {
        tracker.restore({
          for (final e in saved.entries)
            e.key as String: DateTime.fromMillisecondsSinceEpoch(
              (e.value as num).toInt(),
            ),
        });
      }
      _riskNotified.clear();
      _missedNotified.clear();
    }
    checkpoints = tracker;
    outlook = null;
  }

  /// Picks the course automatically when there is no real choice, or the
  /// runner already chose one earlier.
  void _autoSelectCourse() {
    if (course != null || courses.isEmpty) return;
    final saved = code == null ? null : settings.courseFor(code!);
    if (saved != null && courses.containsKey(saved)) {
      selectCourse(saved);
    } else if (event != null && event!.courses.length <= 1) {
      selectCourse(courses.keys.first);
    }
  }

  /// Load a route locally. For the organizer this adds it as a course and
  /// shares it with the group; for others it only affects this device.
  void useRoute(TrailRoute r) {
    if (isOrganizer) {
      addCourse(r);
    } else {
      _useCourse(Course.fromRoute(r, id: _localCourse));
    }
    notifyListeners();
  }

  /// Organizer: add a distance to the event and switch to it.
  void addCourse(TrailRoute r) {
    var n = courses.length + 1;
    while (courses.containsKey('c$n')) {
      n++;
    }
    final shared = Course.fromShareJson(
      Course.fromRoute(r, id: 'c$n').toShareJson(),
    );
    updateCourse(shared);
    selectCourse(shared.id);
  }

  /// Organizer: publish a new or edited course (name, start, checkpoints).
  void updateCourse(Course c) {
    courses[c.id] = c;
    _courseUpdated[c.id] = DateTime.now();
    _dirtyCourses.add(c.id);
    if (course?.id == c.id) _useCourse(c, keepProgress: true);
    final e = event;
    event = EventInfo(
      name: e?.name ?? 'Group run',
      organizerId: myId,
      organizerName: myName,
      organizerPhone: settings.phone,
      updated: DateTime.now(),
      courses: [for (final c in courseList) c.info],
    );
    _eventInfoDirty = true;
    _flushEventInfo();
    notifyListeners();
  }

  // ------------------------------------------------------------------------
  // Fuelling. Never leaves this device.
  // ------------------------------------------------------------------------

  void _startFuel() {
    final start = startedAt ?? DateTime.now();
    final saved = settings.runData('fuel:$_runKey');
    var log = FuelLog();
    if (saved is Map && saved['start'] == start.millisecondsSinceEpoch) {
      log = FuelLog.fromJson(saved['log'] as List);
    }
    fuel = FuelCoach(plan: settings.fuelPlan, log: log, start: start);
  }

  void _saveFuel() {
    final f = fuel;
    if (f == null) return;
    settings.setRunData('fuel:$_runKey', {
      'start': f.start.millisecondsSinceEpoch,
      'log': f.log.toJson(),
    });
  }

  /// The next aid station or water point, with arrival time.
  UpcomingStop? get _upcomingStop {
    final tracker = checkpoints;
    final m = match;
    if (tracker == null || m == null) return null;
    for (final cp in course!.checkpoints) {
      if (cp.along < m.along || tracker.passed.containsKey(cp.id)) continue;
      if (!cp.kind.refuels) continue;
      return UpcomingStop(
        cp.name,
        tracker.pace.arrival(DateTime.now(), m.along, cp.along),
      );
    }
    return null;
  }

  void logFuel(FuelItem item, {int servings = 1, DateTime? at}) {
    final f = fuel;
    if (f == null) return;
    for (var i = 0; i < servings; i++) {
      f.log.add(FuelEntry.of(item, at ?? DateTime.now()));
    }
    fuelReminder = null;
    notifier.cancel(NoteId.fuel);
    _saveFuel();
    notifyListeners();
  }

  void undoFuel() {
    fuel?.log.undo();
    _saveFuel();
    notifyListeners();
  }

  void snoozeFuel([Duration by = const Duration(minutes: 5)]) {
    fuel?.snooze(DateTime.now(), by);
    fuelReminder = null;
    notifier.cancel(NoteId.fuel);
    notifyListeners();
  }

  void dismissFuelReminder() {
    fuelReminder = null;
    notifyListeners();
  }

  /// Handles a notification button ("Ate it", "In 5 min").
  void handleNotificationAction(String? action, String? payload, DateTime at) {
    final f = fuel;
    if (f == null) return;
    if (action == NoteAction.fuelSnooze) {
      f.snooze(at, const Duration(minutes: 5));
      fuelReminder = null;
    } else if (action == NoteAction.fuelAte && payload != null) {
      try {
        final servings = (jsonDecode(payload) as Map)['s'] as List;
        for (final s in servings.cast<List>()) {
          final item = f.plan.item(s[0] as String);
          if (item != null) {
            logFuel(item, servings: (s[1] as num).toInt(), at: at);
          }
        }
      } on Object {
        return;
      }
    }
    notifyListeners();
  }

  Future<void> _onTick() async {
    if (_disposed) return;
    final now = DateTime.now();
    for (final a in await settings.takePendingActions()) {
      handleNotificationAction(
        a['a'] as String?,
        a['p'] as String?,
        DateTime.fromMillisecondsSinceEpoch((a['t'] as num).toInt()),
      );
    }
    _checkMissedCutoffs(now);
    final f = fuel;
    if (f != null) {
      f.plan = settings.fuelPlan;
      final r = f.due(now, stop: _upcomingStop);
      if (r != null) {
        fuelReminder = r;
        HapticFeedback.mediumImpact();
        notifier.fuel(r);
      }
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

  /// Publishes the event info and any changed courses (organizer only).
  Future<void> _flushEventInfo() async {
    final info = event;
    final r = relay;
    if (info == null || r == null || !isOrganizer || !r.isOnline) return;
    for (final id in _dirtyCourses.toList()) {
      final c = courses[id];
      if (c == null) continue;
      final payload = await _cipher!.seal(
        CourseUpdate(c, _courseUpdated[id]!).toJson(),
      );
      if (r.publish(
        topics!.course(id),
        payload,
        retain: true,
        reliable: true,
      )) {
        _dirtyCourses.remove(id);
      }
    }
    if (!_eventInfoDirty) return;
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
      course: course?.id == _localCourse ? null : course?.id,
      passes: checkpoints?.passed ?? const {},
      next: outlook?.checkpoint.id,
      eta: outlook?.eta,
      started: startedAt,
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
      final legacy = info.legacyRoute;
      if (legacy != null && courses.isEmpty) {
        courses['c1'] = Course.fromRoute(legacy, id: 'c1');
      }
      _autoSelectCourse();
      notifyListeners();
      return;
    }

    final cid = t.courseOf(m.topic);
    if (cid != null) {
      if (m.payload.isEmpty) {
        courses.remove(cid);
      } else {
        final u = CourseUpdate.fromJson(await cipher.open(m.payload));
        if (u == null || u.course.id != cid) return;
        final prev = _courseUpdated[cid];
        if (prev != null && !u.updated.isAfter(prev)) return;
        courses[cid] = u.course;
        _courseUpdated[cid] = u.updated;
        if (course?.id == cid) _useCourse(u.course, keepProgress: true);
        _autoSelectCourse();
      }
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
        .alerts(DateTime.now(), alertPolicy, courseOf: (id) => courses[id])
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
        for (final id in courses.keys) {
          r.clearRetained(topics!.course(id));
        }
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
    await notifier.cancel(NoteId.fuel);
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
    _tick?.cancel();
    notifier.onAction = null;
    relay?.state.removeListener(_onRelayState);
    relay?.dispose();
    super.dispose();
  }
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _minutes(Duration d) {
  final m = d.inMinutes.abs();
  return m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
}
