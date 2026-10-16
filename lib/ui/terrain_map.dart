import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../brand.dart';
import '../core/geo.dart';
import '../services/map_layers.dart';
import '../services/tile_proxy.dart';
import '../state/run_session.dart';
import 'terrain_scene.dart';
import 'trail_map.dart';

/// Camera of the 3D map. Commands sent before the page is ready are kept
/// (the last one wins) and applied once it is.
class TerrainController implements TrailMapCamera {
  Future<void> Function(String js)? _run;
  Map<String, Object?>? _pending;

  bool get attached => _run != null;

  void _attach(Future<void> Function(String js) run) {
    _run = run;
    final p = _pending;
    _pending = null;
    if (p != null) camera(p);
  }

  void _detach() => _run = null;

  /// A raw `ibex.camera` command.
  void camera(Map<String, Object?> cmd) {
    final run = _run;
    if (run == null) {
      _pending = cmd;
      return;
    }
    unawaited(run('ibex.camera(${jsonEncode(cmd)})'));
  }

  @override
  void fitBounds(GeoPoint sw, GeoPoint ne, {double? pitch}) => camera({
    'type': 'fit',
    'bounds': [
      TerrainScene.pos(sw.lat, sw.lon),
      TerrainScene.pos(ne.lat, ne.lon),
    ],
    'padding': {
      'top': mapFitPadding.top,
      'bottom': mapFitPadding.bottom,
      'left': mapFitPadding.left,
      'right': mapFitPadding.right,
    },
    'pitch': ?pitch,
    'animate': attached,
  });

  @override
  void centerOn(GeoPoint p, {double minZoom = 15, double? pitch}) => camera({
    'type': 'center',
    'lon': p.lon,
    'lat': p.lat,
    'minZoom': minZoom,
    'pitch': ?pitch,
  });

  /// Flat and north-up, or tilted for the 3D look.
  void toggleTilt() => camera({'type': 'toggleTilt'});
}

/// The 3D terrain map: same content as [TrailMap], drawn by MapLibre GL JS
/// in a web view, on elevation tiles with hillshade and contours.
class TerrainMap extends StatefulWidget {
  const TerrainMap({
    super.key,
    required this.session,
    required this.controller,
    required this.map,
    required this.follow,
    required this.onFollowChanged,
    this.selected,
    this.onSelect,
  });

  final RunSession session;
  final TerrainController controller;
  final ResolvedMap map;
  final bool follow;
  final ValueChanged<bool> onFollowChanged;
  final String? selected;
  final ValueChanged<String?>? onSelect;

  @override
  State<TerrainMap> createState() => _TerrainMapState();
}

class _TerrainMapState extends State<TerrainMap> {
  TileProxy? _proxy;
  WebViewController? _web;
  bool _ready = false;
  bool _failed = false;

  Timer? _throttle;
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);
  String? _sentLayers;
  Object? _sentRoute;
  Object? _sentCourse;
  int _sentRecorded = 0;

  RunSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_schedule);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final proxy = await TileProxy.start(layers: () => widget.map);
      if (!mounted) {
        await proxy.close();
        return;
      }
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(Brand.sand);
      await web.addJavaScriptChannel(
        'IbexBridge',
        onMessageReceived: (m) => _onMessage(m.message),
      );
      await web.setNavigationDelegate(
        NavigationDelegate(
          // The page never leaves the app's own server.
          onNavigationRequest: (r) => r.url.startsWith(proxy.origin)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
      await web.loadRequest(Uri.parse(proxy.pageUrl));
      if (!mounted) {
        await proxy.close();
        return;
      }
      setState(() {
        _proxy = proxy;
        _web = web;
      });
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(TerrainMap old) {
    super.didUpdateWidget(old);
    if (old.session != s) {
      old.session.removeListener(_schedule);
      s.addListener(_schedule);
    }
    if (old.controller != widget.controller) {
      old.controller._detach();
      if (_ready) widget.controller._attach(_js);
    }
    _pushLayers();
    if (old.selected != widget.selected) _flush();
    if (widget.follow && !old.follow) _centerOnMe();
  }

  @override
  void dispose() {
    s.removeListener(_schedule);
    _throttle?.cancel();
    widget.controller._detach();
    unawaited(_proxy?.close());
    super.dispose();
  }

  Future<void> _js(String code) async {
    final web = _web;
    if (web == null || !mounted) return;
    try {
      await web.runJavaScript(code);
    } on Object {
      // The page is reloading; it says "ready" again when it is back.
    }
  }

  void _onMessage(String raw) {
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(raw) as Map).cast();
    } on Object {
      return;
    }
    switch (msg['type']) {
      case 'ready':
        _ready = true;
        _sentLayers = null;
        _sentRoute = null;
        _sentCourse = null;
        _sentRecorded = 0;
        _flush();
        _initialCamera();
        widget.controller._attach(_js);
      case 'select':
        widget.onSelect?.call(msg['id'] as String?);
      case 'gesture':
        if (widget.follow) widget.onFollowChanged(false);
      case 'resendTrack':
        _sentRecorded = 0;
        _schedule();
      case 'error':
        if (mounted) setState(() => _failed = true);
    }
  }

  void _initialCamera() {
    // A command sent while loading (e.g. "fit the route") wins.
    if (widget.controller._pending != null) return;
    final f = s.fix;
    final route = s.route;
    if (widget.follow && f != null) {
      widget.controller.centerOn(GeoPoint(f.latitude, f.longitude), pitch: 60);
    } else if (route != null) {
      final (sw, ne) = route.bounds;
      widget.controller.fitBounds(sw, ne, pitch: 50);
    }
  }

  void _centerOnMe() {
    final f = s.fix;
    if (!_ready || f == null) return;
    widget.controller.centerOn(GeoPoint(f.latitude, f.longitude));
  }

  void _pushLayers() {
    final proxy = _proxy;
    if (!_ready || proxy == null) return;
    final cfg = jsonEncode(TerrainScene.layers(widget.map, proxy.tileTemplate));
    if (cfg == _sentLayers) return;
    _sentLayers = cfg;
    unawaited(_js('ibex.setLayers($cfg)'));
  }

  /// Sends changes at most about once a second: GPS fixes and group
  /// updates arrive far more often than the map needs.
  void _schedule() {
    if (!_ready || (_throttle?.isActive ?? false)) return;
    final wait =
        const Duration(seconds: 1) - DateTime.now().difference(_lastFlush);
    _throttle = Timer(wait.isNegative ? Duration.zero : wait, _flush);
  }

  void _flush() {
    if (!_ready || !mounted) return;
    _throttle?.cancel();
    _lastFlush = DateTime.now();
    _pushLayers();
    if (s.route != _sentRoute || s.course != _sentCourse) {
      _sentRoute = s.route;
      _sentCourse = s.course;
      _sentRecorded = 0;
      unawaited(
        _js(
          'ibex.setRoute(${jsonEncode(TerrainScene.route(s.route, s.course))})',
        ),
      );
    }
    final live = TerrainScene.live(
      s,
      now: DateTime.now(),
      recordedFrom: _sentRecorded,
      selected: widget.selected,
    );
    _sentRecorded = s.recorded.length;
    unawaited(_js('ibex.update(${jsonEncode(live)})'));
    if (widget.follow) _centerOnMe();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Brand.sand)),
        if (web != null) Positioned.fill(child: WebViewWidget(controller: web)),
        if (_failed)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '3D view unavailable on this phone. Switch back with the '
                '2D button.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        else if (!_ready)
          const Center(child: CircularProgressIndicator()),
        MapAttribution(widget.map.attribution(in3d: true)),
      ],
    );
  }
}
