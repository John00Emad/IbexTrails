import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import '../core/geo.dart';
import 'run_session.dart';

/// Which way your arrow on the map points, in degrees from north.
///
/// Running, it's your direction of travel from GPS, which stays steady
/// while the phone bounces in your hand. Standing or walking slowly, when
/// GPS has no direction, it's the way the phone faces, so at a junction you
/// see which way you're looking. A phone without a compass keeps the last
/// way you moved. Null until one of them knows: the map shows a dot then.
class MyHeading extends ValueNotifier<double?> {
  /// Follows [session]'s GPS fixes and, while the app is on screen, the
  /// [compass].
  MyHeading(this.session, {Stream<double> Function()? compass})
    : _compassSource = compass,
      super(null) {
    session.addListener(_onSession);
    if (compass != null) {
      // Only while the app is on screen: the sensor costs battery.
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) _listen();
    }
    _onSession();
  }

  /// GPS gives a direction from this speed (m/s), a slow walk...
  static const gpsFrom = 0.7;

  /// ...and takes over from the compass at this one, a brisk walk, until
  /// you slow below [gpsFrom] again.
  static const gpsOver = 1.4;

  final RunSession session;
  final Stream<double> Function()? _compassSource;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<double>? _compassSub;

  Position? _fix;
  double? _gps;
  double? _compass;
  bool _gpsLeads = false;

  void _onSession() {
    final f = session.fix;
    if (f == null || identical(f, _fix)) return;
    _fix = f;
    // iPhones give a negative heading when they don't know it.
    final moving = f.speed >= gpsFrom && f.heading >= 0;
    if (moving) _gps = f.heading % 360;
    _gpsLeads = moving && (_gpsLeads || f.speed >= gpsOver);
    _update();
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _listen();
    } else {
      _pause();
    }
  }

  void _listen() {
    _compassSub ??= _compassSource!().listen(
      (h) {
        _compass = h;
        _update();
      },
      // A phone without a compass: nothing else comes.
      onError: (Object _) {},
    );
  }

  void _pause() {
    _compassSub?.cancel();
    _compassSub = null;
  }

  void _update() {
    final h = (_gpsLeads ? _gps : _compass) ?? _gps;
    final shown = value;
    // Wobbles under a degree aren't worth turning the arrow for.
    if (h == null || shown == null || headingChange(shown, h).abs() >= 1) {
      value = h;
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _lifecycle?.dispose();
    _pause();
    super.dispose();
  }
}
