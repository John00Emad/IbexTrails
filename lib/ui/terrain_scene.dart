import 'dart:math' as math;
import 'dart:ui' show Color;

import '../core/course.dart';
import '../core/geo.dart';
import '../core/route.dart';
import '../core/turns.dart';
import '../services/map_layers.dart';
import '../state/run_session.dart';
import 'status_style.dart';

/// What the 3D view draws, as JSON for its web page (`assets/map3d`).
///
/// Built here rather than in the page so it follows the same rules as the
/// 2D map and can be unit-tested.
abstract final class TerrainScene {
  /// GeoJSON position, rounded to ~10 cm to keep the messages small.
  static List<double> pos(double lat, double lon) => [_r(lon), _r(lat)];
  static double _r(double v) => (v * 1e6).roundToDouble() / 1e6;
  static List<double> _p(GeoPoint p) => pos(p.lat, p.lon);

  static String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Layers for `ibex.setLayers`. [tiles] gives a layer's tile URL template
  /// (on the app's tile proxy).
  static Map<String, Object?> layers(
    ResolvedMap map,
    String Function(MapLayer) tiles,
  ) => {
    'base': {
      'id': map.base.id,
      'tiles': tiles(map.base),
      'maxzoom': map.base.maxNativeZoom,
    },
    'overlays': [
      for (final (l, opacity) in map.overlays)
        {
          'id': l.id,
          'render': l.render3d.name,
          'opacity': opacity,
          if (l.render3d == Render3d.raster) ...{
            'tiles': tiles(l),
            'maxzoom': l.maxNativeZoom,
          },
        },
    ],
    'dem': {
      'id': map.elevation.id,
      'tiles': tiles(map.elevation),
      'maxzoom': map.elevation.maxNativeZoom,
      'encoding': map.elevation.demEncoding,
    },
    'exaggeration': map.setup.exaggeration,
  };

  /// The route for `ibex.setRoute`: line, start/finish and the turns that
  /// are easy to miss. Null without a route.
  static Map<String, Object?>? route(TrailRoute? route, Course? course) {
    if (route == null) return null;
    final (sw, ne) = route.bounds;
    return {
      'coords': [for (final p in route.points) _p(p)],
      'start': _p(route.start),
      'finish': route.isLoop ? null : _p(route.finish),
      'turns': [
        for (final t in course?.turns ?? const <Turn>[])
          if (t.kind == TurnKind.sharp || t.kind == TurnKind.uTurn)
            {
              ..._lonLat(route.pointAt(t.along)),
              'uTurn': t.kind == TurnKind.uTurn,
              'right': t.isRight,
              'label': t.label,
            },
      ],
      'bounds': [_p(sw), _p(ne)],
    };
  }

  static Map<String, double> _lonLat(GeoPoint p) => {
    'lon': _r(p.lon),
    'lat': _r(p.lat),
  };

  /// Everything that moves, for `ibex.update`. Only the recorded track
  /// points from [recordedFrom] on are included (the page keeps the rest).
  static Map<String, Object?> live(
    RunSession s, {
    required DateTime now,
    required int recordedFrom,
    String? selected,
  }) {
    final route = s.route;
    final match = s.match;
    final f = s.fix;
    final course = s.course;

    Map<String, Object?>? cut;
    if (route != null && match != null) {
      final at = route.pointAt(match.along);
      cut = {'i': route.segmentIndexAt(match.along), ..._lonLat(at)};
    }

    // Checkpoints when the course has them, otherwise the GPX waypoints.
    final pins = <Map<String, Object?>>[
      if (route != null)
        if (course?.checkpoints.isNotEmpty ?? false)
          for (final cp in course!.checkpoints)
            {
              ..._lonLat(course.pointOf(cp)),
              'name': cp.name,
              'passed': s.checkpoints?.passed.containsKey(cp.id) ?? false,
            }
        else
          for (final w in route.waypoints)
            {..._lonLat(w.point), 'name': w.name, 'passed': false},
    ];

    final people = [
      for (final p in s.group.participants)
        if (p.id != s.myId)
          {
            'id': p.id,
            'name': p.name,
            'initials': initials(p.name),
            'color': hex(ParticipantStyle.of(p, now, s.alertPolicy).color),
            'selected': p.id == selected,
            'lon': _r(p.latest.lon),
            'lat': _r(p.latest.lat),
          },
    ];

    final sel = selected == null ? null : s.group[selected];
    final trail = sel != null && sel.track.length > 1
        ? {
            'color': hex(ParticipantStyle.of(sel, now, s.alertPolicy).color),
            'coords': [for (final p in sel.track) pos(p.lat, p.lon)],
          }
        : null;

    final from = recordedFrom > s.recorded.length ? 0 : recordedFrom;
    return {
      'cut': cut,
      'me': f == null
          ? null
          : {
              'lon': _r(f.longitude),
              'lat': _r(f.latitude),
              'acc': f.accuracy,
              'heading': f.speed > 0.7 ? f.heading : null,
            },
      'accuracy': f == null
          ? null
          : circle(f.latitude, f.longitude, f.accuracy),
      'people': people,
      'pins': pins,
      'trail': trail,
      'recordedFrom': from,
      'recorded': [for (final p in s.recorded.skip(from)) _p(p)],
      'offRoute': f != null && match != null && match.offRoute
          ? [pos(f.latitude, f.longitude), _p(match.nearest)]
          : null,
    };
  }

  /// Closed ring approximating a circle of [radiusM] metres.
  static List<List<double>> circle(
    double lat,
    double lon,
    double radiusM, {
    int segments = 48,
  }) {
    const mPerDegLat = earthRadiusM * math.pi / 180;
    final dLat = radiusM / mPerDegLat;
    final dLon = dLat / math.cos(lat * math.pi / 180);
    return [
      for (var k = 0; k <= segments; k++)
        pos(
          lat + dLat * math.sin(2 * math.pi * k / segments),
          lon + dLon * math.cos(2 * math.pi * k / segments),
        ),
    ];
  }
}
