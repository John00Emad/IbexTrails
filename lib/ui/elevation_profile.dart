import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/route.dart';

/// A marker drawn on the profile, e.g. another runner.
class ProfileMarker {
  const ProfileMarker(this.along, this.color);
  final double along;
  final Color color;
}

/// Elevation profile of the route with your position and, optionally, other
/// people's positions along it. Without elevation data it degrades to a
/// progress bar, which still shows how spread out the group is.
class ElevationProfile extends StatelessWidget {
  const ElevationProfile({
    super.key,
    required this.route,
    this.along,
    this.others = const [],
    this.height = 64,
  });

  final TrailRoute route;
  final double? along;
  final List<ProfileMarker> others;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ProfilePainter(
          route: route,
          along: along,
          others: others,
          fill: TrailColors.route.withValues(alpha: 0.25),
          line: TrailColors.route,
          done: scheme.onSurface.withValues(alpha: 0.35),
          label: Theme.of(context).textTheme.labelSmall!
              .copyWith(color: scheme.onSurfaceVariant, fontSize: 10),
          me: TrailColors.me,
          waypoint: scheme.tertiary,
        ),
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter({
    required this.route,
    required this.along,
    required this.others,
    required this.fill,
    required this.line,
    required this.done,
    required this.label,
    required this.me,
    required this.waypoint,
  });

  final TrailRoute route;
  final double? along;
  final List<ProfileMarker> others;
  final Color fill, line, done, me, waypoint;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    const labelWidth = 40.0;
    final chart = Rect.fromLTWH(
      labelWidth,
      4,
      size.width - labelWidth - 4,
      size.height - 10,
    );
    final len = route.length;
    double xOf(double d) => chart.left + chart.width * (d / len).clamp(0, 1);

    if (!route.hasElevation) {
      _paintBar(canvas, chart, xOf);
      return;
    }

    // Sample the route once per couple of pixels.
    final n = math.max(2, (chart.width / 2).round());
    final samples = [
      for (var i = 0; i <= n; i++) route.elevationAt(len * i / n) ?? 0,
    ];
    var lo = samples.reduce(math.min), hi = samples.reduce(math.max);
    if (hi - lo < 50) {
      final mid = (hi + lo) / 2;
      lo = mid - 25;
      hi = mid + 25;
    }
    double yOf(double ele) =>
        chart.bottom - chart.height * ((ele - lo) / (hi - lo));

    final path = Path()..moveTo(chart.left, chart.bottom);
    for (var i = 0; i <= n; i++) {
      path.lineTo(chart.left + chart.width * i / n, yOf(samples[i]));
    }
    path
      ..lineTo(chart.right, chart.bottom)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);

    final linePath = Path();
    for (var i = 0; i <= n; i++) {
      final p = Offset(chart.left + chart.width * i / n, yOf(samples[i]));
      i == 0 ? linePath.moveTo(p.dx, p.dy) : linePath.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Grey out the part already run.
    final a = along;
    if (a != null && a > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(chart.left, 0, xOf(a), size.height));
      canvas.drawPath(path, Paint()..color = done.withValues(alpha: 0.35));
      canvas.restore();
    }

    _paintWaypoints(canvas, chart, xOf);

    for (final o in others) {
      final x = xOf(o.along);
      final y = yOf(route.elevationAt(o.along) ?? lo);
      canvas.drawCircle(Offset(x, y), 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = o.color);
    }

    if (a != null) {
      final x = xOf(a);
      final y = yOf(route.elevationAt(a) ?? lo);
      canvas.drawLine(
        Offset(x, chart.top),
        Offset(x, chart.bottom),
        Paint()
          ..color = me.withValues(alpha: 0.6)
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(Offset(x, y), 6, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x, y), 4.5, Paint()..color = me);
    }

    _label(canvas, '${hi.round()} m', Offset(0, chart.top - 2));
    _label(canvas, '${lo.round()} m', Offset(0, chart.bottom - 12));
  }

  void _paintBar(Canvas canvas, Rect chart, double Function(double) xOf) {
    final bar = Rect.fromLTRB(
      chart.left,
      chart.center.dy - 4,
      chart.right,
      chart.center.dy + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar, const Radius.circular(4)),
      Paint()..color = fill,
    );
    final a = along;
    if (a != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(bar.left, bar.top, xOf(a), bar.bottom),
          const Radius.circular(4),
        ),
        Paint()..color = line,
      );
    }
    _paintWaypoints(canvas, chart, xOf);
    for (final o in others) {
      canvas.drawCircle(
        Offset(xOf(o.along), bar.center.dy),
        5,
        Paint()..color = o.color,
      );
    }
    if (a != null) {
      canvas.drawCircle(Offset(xOf(a), bar.center.dy), 7, Paint()..color = me);
    }
    _label(canvas, '0 km', Offset(0, bar.top - 4));
  }

  void _paintWaypoints(Canvas canvas, Rect chart, double Function(double) xOf) {
    final paint = Paint()
      ..color = waypoint
      ..strokeWidth = 2;
    for (final w in route.waypoints) {
      for (final pass in w.passes) {
        final x = xOf(pass);
        canvas.drawLine(
          Offset(x, chart.bottom),
          Offset(x, chart.bottom + 6),
          paint,
        );
      }
    }
  }

  void _label(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: label),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 40);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.route != route ||
      old.along != along ||
      old.others.length != others.length ||
      !_sameMarkers(old.others, others) ||
      old.line != line ||
      old.done != done;

  static bool _sameMarkers(List<ProfileMarker> a, List<ProfileMarker> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].along != b[i].along || a[i].color != b[i].color) return false;
    }
    return true;
  }
}
