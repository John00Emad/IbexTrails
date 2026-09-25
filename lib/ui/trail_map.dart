import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app.dart';
import '../brand.dart';
import '../core/geo.dart';
import '../core/route.dart';
import '../core/turns.dart';
import '../services/map_tiles.dart';
import '../services/settings.dart';
import '../state/run_session.dart';
import 'status_style.dart';

LatLng ll(GeoPoint p) => LatLng(p.lat, p.lon);

/// The live map: route, waypoints, you, and everyone else in the event.
class TrailMap extends StatefulWidget {
  const TrailMap({
    super.key,
    required this.session,
    required this.controller,
    required this.style,
    required this.follow,
    required this.onFollowChanged,
    this.selected,
    this.onSelect,
  });

  final RunSession session;
  final MapController controller;
  final MapStyle style;
  final bool follow;
  final ValueChanged<bool> onFollowChanged;

  /// Participant whose trail is highlighted.
  final String? selected;
  final ValueChanged<String?>? onSelect;

  @override
  State<TrailMap> createState() => _TrailMapState();
}

class _TrailMapState extends State<TrailMap> {
  bool _ready = false;
  TrailRoute? _arrowsFor;
  List<Marker> _arrows = const [];

  RunSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
  }

  @override
  void didUpdateWidget(TrailMap old) {
    super.didUpdateWidget(old);
    if (old.session != s) {
      old.session.removeListener(_onSession);
      s.addListener(_onSession);
    }
    if (widget.follow && !old.follow) _centerOnMe();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (widget.follow) _centerOnMe();
  }

  void _centerOnMe() {
    final f = s.fix;
    if (!_ready || f == null) return;
    final zoom = math.max(widget.controller.camera.zoom, 15.0);
    widget.controller.move(LatLng(f.latitude, f.longitude), zoom);
  }

  List<Marker> _directionArrows(TrailRoute route, Color color) {
    if (_arrowsFor == route) return _arrows;
    final spacing = math.max(600.0, route.length / 25);
    final markers = <Marker>[];
    for (var d = spacing / 2; d < route.length; d += spacing) {
      final a = route.pointAt(math.max(0, d - 10));
      final b = route.pointAt(math.min(route.length, d + 10));
      final bearing = bearingBetween(a, b);
      markers.add(
        Marker(
          point: ll(route.pointAt(d)),
          width: 18,
          height: 18,
          child: Transform.rotate(
            angle: bearing * math.pi / 180,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: TrailColors.routeCasing, width: 1.5),
              ),
              child: const Icon(
                Icons.navigation,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }
    _arrowsFor = route;
    return _arrows = markers;
  }

  MapOptions _options() {
    final route = s.route;
    final f = s.fix;
    CameraFit? fit;
    if (route != null) {
      final (sw, ne) = route.bounds;
      fit = CameraFit.bounds(
        bounds: LatLngBounds(ll(sw), ll(ne)),
        padding: const EdgeInsets.fromLTRB(40, 140, 40, 260),
        maxZoom: 16,
      );
    }
    return MapOptions(
      initialCenter: f != null
          ? LatLng(f.latitude, f.longitude)
          : const LatLng(20, 0),
      initialZoom: f != null ? 15 : 2,
      initialCameraFit: fit,
      minZoom: 3,
      maxZoom: 19,
      interactionOptions: const InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
      onMapReady: () {
        _ready = true;
        if (widget.follow) _centerOnMe();
      },
      onPositionChanged: (camera, hasGesture) {
        if (hasGesture && widget.follow) widget.onFollowChanged(false);
      },
      onTap: (_, _) => widget.onSelect?.call(null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = s.route;
    final match = s.match;
    final f = s.fix;
    final now = DateTime.now();
    final src = tileSourceFor(widget.style);

    final layers = <Widget>[MapTiles.layer(widget.style)];

    // Route: already-run part greyed, remaining part in trail orange.
    if (route != null) {
      final pts = route.points.map(ll).toList();
      List<LatLng> done = const [], todo = pts;
      if (match != null) {
        final i = route.segmentIndexAt(match.along);
        final cut = ll(route.pointAt(match.along));
        done = [...pts.take(i + 1), cut];
        todo = [cut, ...pts.skip(i + 1)];
      }
      layers.add(
        PolylineLayer(
          polylines: [
            if (done.length > 1)
              Polyline(
                points: done,
                color: TrailColors.routeDone,
                strokeWidth: 5,
                borderColor: Colors.white,
                borderStrokeWidth: 1.5,
              ),
            Polyline(
              points: todo,
              color: TrailColors.route,
              strokeWidth: 5,
              // Dark casing keeps the line visible on pale desert tiles.
              borderColor: TrailColors.routeCasing.withValues(alpha: 0.85),
              borderStrokeWidth: 2,
            ),
          ],
        ),
      );
      layers.add(
        MarkerLayer(markers: _directionArrows(route, TrailColors.route)),
      );
      // Only the turns that are easy to miss, to keep the map readable.
      final turns = [
        for (final t in s.course?.turns ?? const <Turn>[])
          if (t.kind == TurnKind.sharp || t.kind == TurnKind.uTurn) t,
      ];
      if (turns.isNotEmpty) {
        layers.add(
          MarkerLayer(
            markers: [
              for (final t in turns)
                Marker(
                  point: ll(route.pointAt(t.along)),
                  width: 26,
                  height: 26,
                  child: Tooltip(
                    message: t.label,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Brand.night, width: 2),
                      ),
                      child: Icon(
                        t.kind == TurnKind.uTurn
                            ? (t.isRight
                                  ? Icons.u_turn_right
                                  : Icons.u_turn_left)
                            : (t.isRight
                                  ? Icons.turn_sharp_right
                                  : Icons.turn_sharp_left),
                        size: 16,
                        color: Brand.night,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }

    // Highlighted trail of a selected participant.
    final sel = widget.selected == null ? null : s.group[widget.selected!];
    if (sel != null && sel.track.length > 1) {
      layers.add(
        PolylineLayer(
          polylines: [
            Polyline(
              points: [for (final p in sel.track) LatLng(p.lat, p.lon)],
              color: ParticipantStyle.of(sel, now, s.alertPolicy).color,
              strokeWidth: 3,
              pattern: const StrokePattern.dotted(),
            ),
          ],
        ),
      );
    }

    // Your own breadcrumb trail.
    if (s.recorded.length > 1) {
      layers.add(
        PolylineLayer(
          polylines: [
            Polyline(
              points: s.recorded.map(ll).toList(),
              color: TrailColors.me.withValues(alpha: 0.7),
              strokeWidth: 3,
            ),
          ],
        ),
      );
    }

    // Guide line back to the route when off course.
    if (f != null && match != null && match.offRoute) {
      layers.add(
        PolylineLayer(
          polylines: [
            Polyline(
              points: [LatLng(f.latitude, f.longitude), ll(match.nearest)],
              color: TrailColors.danger,
              strokeWidth: 4,
              pattern: StrokePattern.dashed(segments: const [12, 8]),
            ),
          ],
        ),
      );
    }

    if (route != null) {
      layers.add(
        MarkerLayer(
          markers: [
            // Checkpoints when the course has them (they come from the
            // waypoints), otherwise the plain GPX waypoints.
            if (s.course?.checkpoints.isNotEmpty ?? false)
              for (final cp in s.course!.checkpoints)
                Marker(
                  point: ll(s.course!.pointOf(cp)),
                  width: 130,
                  height: 44,
                  alignment: const Alignment(0, -0.6),
                  child: _WaypointPin(
                    name: cp.name,
                    passed: s.checkpoints?.passed.containsKey(cp.id) ?? false,
                  ),
                )
            else
              for (final w in route.waypoints)
                Marker(
                  point: ll(w.point),
                  width: 120,
                  height: 44,
                  alignment: const Alignment(0, -0.6),
                  child: _WaypointPin(name: w.name),
                ),
            Marker(
              point: ll(route.start),
              width: 30,
              height: 30,
              child: const _RoundIcon(Icons.flag, TrailColors.ok),
            ),
            if (!route.isLoop)
              Marker(
                point: ll(route.finish),
                width: 30,
                height: 30,
                child: const _RoundIcon(Icons.sports_score, Colors.black87),
              ),
          ],
        ),
      );
    }

    // Other participants.
    final others = s.group.participants.where((p) => p.id != s.myId).toList();
    if (others.isNotEmpty) {
      layers.add(
        MarkerLayer(
          markers: [
            for (final p in others)
              Marker(
                point: LatLng(p.latest.lat, p.latest.lon),
                width: 110,
                height: 58,
                alignment: const Alignment(0, 0.45),
                child: GestureDetector(
                  onTap: () => widget.onSelect?.call(p.id),
                  child: _PersonPin(
                    name: p.name,
                    style: ParticipantStyle.of(p, now, s.alertPolicy),
                    selected: p.id == widget.selected,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // You.
    if (f != null) {
      final me = LatLng(f.latitude, f.longitude);
      layers.add(
        CircleLayer(
          circles: [
            CircleMarker(
              point: me,
              radius: f.accuracy,
              useRadiusInMeter: true,
              color: TrailColors.me.withValues(alpha: 0.12),
              borderColor: TrailColors.me.withValues(alpha: 0.4),
              borderStrokeWidth: 1,
            ),
          ],
        ),
      );
      layers.add(
        MarkerLayer(
          markers: [
            Marker(
              point: me,
              width: 40,
              height: 40,
              child: _MeDot(heading: f.speed > 0.7 ? f.heading : null),
            ),
          ],
        ),
      );
    }

    layers.add(
      Scalebar(
        textStyle: Theme.of(context).textTheme.labelMedium!
            .copyWith(color: Colors.black87, fontWeight: FontWeight.w600),
        lineColor: Colors.black87,
        alignment: Alignment.topLeft,
        padding: EdgeInsets.fromLTRB(12, 8, 8, 8),
        length: ScalebarLength.s,
      ),
    );
    layers.add(_Attribution(src.attribution));

    return FlutterMap(
      mapController: widget.controller,
      options: _options(),
      children: layers,
    );
  }
}

/// Compact attribution that wraps instead of overflowing on narrow phones
/// and stays clear of the map buttons on the right.
class _Attribution extends StatelessWidget {
  const _Attribution(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(120, MediaQuery.sizeOf(context).width - 96),
        ),
        child: ColoredBox(
          color: Colors.white.withValues(alpha: 0.8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              text,
              style: const TextStyle(fontSize: 10, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon(this.icon, this.color);
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
    ),
    child: Icon(icon, color: Colors.white, size: 16),
  );
}

class _WaypointPin extends StatelessWidget {
  const _WaypointPin({required this.name, this.passed = false});
  final String name;
  final bool passed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: Brand.night,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black26)],
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        Icon(
          passed ? Icons.check_circle : Icons.location_on,
          size: 20,
          color: passed ? TrailColors.ok : Brand.oasis,
        ),
      ],
    );
  }
}

class _PersonPin extends StatelessWidget {
  const _PersonPin({
    required this.name,
    required this.style,
    required this.selected,
  });

  final String name;
  final ParticipantStyle style;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: style.color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.yellowAccent : Colors.white,
              width: selected ? 3 : 2,
            ),
            boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
          ),
          child: Text(
            initials(name),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ),
      ],
    );
  }
}

class _MeDot extends StatelessWidget {
  const _MeDot({this.heading});
  final double? heading;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            child: const Icon(
              Icons.navigation,
              color: TrailColors.me,
              size: 40,
            ),
          ),
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: TrailColors.me,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
          ),
        ),
      ],
    );
  }
}
