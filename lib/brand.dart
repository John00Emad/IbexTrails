import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Everything that makes the app look like it belongs to the club: names,
/// palette and artwork. Swap values here (or drop in official logo assets)
/// without touching the rest of the UI.
abstract final class Brand {
  static const appName = 'IbexTrails';
  static const tagline = 'Run the wadis together.';
  static const subtitle =
      'Live group tracking and GPX navigation for Egypt\'s trail runners.';

  /// Clubs the app is being built for. Not shown until they approve.
  static const communities = ['Wadi Ibex', 'Ultra Ibex'];

  /// Line under the home screen header. Once the clubs approve, switch to:
  /// 'Made for the ${communities[0]} & ${communities[1]} trail family'.
  static const communityLine = 'Made for Egypt\'s trail running community';

  /// Suggested event names when organizing.
  static const eventIdeas = [
    'Wadi Degla long run',
    'Friday team run',
    'Wadi Rayan recce',
    'Sinai mountain session',
  ];

  // ---- Palette: Egyptian desert trails -----------------------------------

  /// Desert night sky. Headers, text on light backgrounds.
  static const night = Color(0xFF1B2330);

  /// Red granite of Sinai / Wadi Degla canyon walls. Primary.
  static const canyon = Color(0xFFB4532A);

  /// Desert sunrise. Route line and highlights (not for text on white).
  static const ember = Color(0xFFF26A1B);

  /// Dunes.
  static const sand = Color(0xFFE8D5B5);
  static const sandDeep = Color(0xFFC9A57A);

  /// Page background: sun-bleached limestone.
  static const limestone = Color(0xFFFAF5EC);

  /// Wadi Rayan lakes. Secondary accent.
  static const oasis = Color(0xFF1E7A74);

  static const fontFamily = 'Cairo';
}

// ---------------------------------------------------------------------------
// Ibex emblem
// ---------------------------------------------------------------------------

/// Profile of a Nubian ibex head with its crescent horn, in a 100×100 box.
/// Original artwork for the app; replace with an official logo if the club
/// provides one.
class IbexGlyph {
  IbexGlyph._();

  static Path head() => Path()
    ..moveTo(17, 63)
    ..cubicTo(19, 55, 27, 45, 37, 37)
    ..cubicTo(41, 34, 46, 31, 51, 31)
    ..cubicTo(56, 32, 60, 37, 62, 43)
    ..cubicTo(66, 55, 72, 72, 80, 100)
    ..lineTo(50, 100)
    ..cubicTo(49, 86, 46, 76, 41, 71)
    ..cubicTo(38, 75, 35, 81, 31, 86)
    ..cubicTo(30, 80, 29, 74, 28, 69)
    ..cubicTo(24, 69, 20, 67, 17, 63)
    ..close();

  static Path ear() => Path()
    ..moveTo(55, 38)
    ..quadraticBezierTo(66, 35, 71, 42)
    ..quadraticBezierTo(62, 45, 57, 42)
    ..close();

  // Horn outer (front) edge and inner (back) edge as cubic segments.
  static const _outer = [
    [Offset(38, 36), Offset(34, 18), Offset(44, 4), Offset(60, 3)],
    [Offset(60, 3), Offset(76, 2), Offset(88, 12), Offset(92, 28)],
  ];
  static const _inner = [
    [Offset(92, 28), Offset(84, 16), Offset(74, 11), Offset(63, 12)],
    [Offset(63, 12), Offset(52, 13), Offset(48, 22), Offset(52, 31)],
  ];

  static Path horn() {
    final p = Path()..moveTo(_outer[0][0].dx, _outer[0][0].dy);
    for (final c in [..._outer, ..._inner]) {
      p.cubicTo(c[1].dx, c[1].dy, c[2].dx, c[2].dy, c[3].dx, c[3].dy);
    }
    return p..close();
  }

  static Offset _bezier(List<Offset> c, double t) {
    final u = 1 - t;
    return c[0] * (u * u * u) +
        c[1] * (3 * u * u * t) +
        c[2] * (3 * u * t * t) +
        c[3] * (t * t * t);
  }

  static Offset _tangent(List<Offset> c, double t) {
    final u = 1 - t;
    return (c[1] - c[0]) * (3 * u * u) +
        (c[2] - c[1]) * (6 * u * t) +
        (c[3] - c[2]) * (3 * t * t);
  }

  /// Knobs on the front of the horn: short notches from the outer edge
  /// pointing into the horn. Draw them clipped to [horn].
  static List<(Offset, Offset)> ridges() {
    final out = <(Offset, Offset)>[];
    for (final (seg, t) in const [
      (0, 0.3),
      (0, 0.55),
      (0, 0.8),
      (1, 0.1),
      (1, 0.35),
    ]) {
      final o = _bezier(_outer[seg], t);
      final d = _tangent(_outer[seg], t);
      // Right-hand normal in screen coordinates points into the horn.
      final n = Offset(-d.dy, d.dx) / d.distance;
      out.add((o - n, o + n * 5));
    }
    return out;
  }

  static const eye = Offset(38.5, 45);
}

/// Paints the ibex glyph scaled into [rect].
void paintIbex(
  Canvas canvas,
  Rect rect, {
  required Color color,
  required Color cutout,
}) {
  canvas.save();
  canvas.translate(rect.left, rect.top);
  canvas.scale(rect.width / 100, rect.height / 100);
  final fill = Paint()
    ..color = color
    ..isAntiAlias = true;
  canvas.drawPath(IbexGlyph.horn(), fill);
  canvas.drawPath(IbexGlyph.ear(), fill);
  canvas.drawPath(IbexGlyph.head(), fill);
  final cut = Paint()
    ..color = cutout
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round;
  canvas.save();
  canvas.clipPath(IbexGlyph.horn());
  for (final (a, b) in IbexGlyph.ridges()) {
    canvas.drawLine(a, b, cut);
  }
  canvas.restore();
  canvas.drawCircle(IbexGlyph.eye, 2.3, Paint()..color = cutout);
  canvas.restore();
}

/// Round badge with the ibex, used as the in-app logo.
class IbexBadge extends StatelessWidget {
  const IbexBadge({super.key, this.size = 48, this.onDark = true});

  final double size;

  /// Light ring for dark backgrounds; dark ring for light ones.
  final bool onDark;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _BadgePainter(onDark)),
  );
}

class _BadgePainter extends CustomPainter {
  _BadgePainter(this.onDark);
  final bool onDark;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final circle = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Brand.ember, Brand.canyon],
        ).createShader(circle),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(circle.deflate(r * 0.06)));
    paintIbex(
      canvas,
      Rect.fromLTWH(r * 0.12, r * 0.18, r * 1.9, r * 1.9),
      color: Brand.limestone,
      cutout: Brand.canyon,
    );
    canvas.restore();
    canvas.drawCircle(
      c,
      r * 0.97,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.06
        ..color = onDark ? Brand.limestone : Brand.night,
    );
  }

  @override
  bool shouldRepaint(_BadgePainter old) => old.onDark != onDark;
}

// ---------------------------------------------------------------------------
// Landscape backdrop
// ---------------------------------------------------------------------------

/// Dusk over the desert: Sinai peaks, canyon walls, dunes and a trail
/// winding towards the mountains.
class DesertBackdrop extends StatelessWidget {
  const DesertBackdrop({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: const _DesertPainter(), child: child);
}

class _DesertPainter extends CustomPainter {
  const _DesertPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final full = Offset.zero & size;

    // Sky.
    canvas.drawRect(
      full,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Brand.night,
            Color(0xFF3B2C3C),
            Color(0xFFB9583A),
            Color(0xFFF0A05A),
          ],
          stops: [0, 0.38, 0.66, 0.8],
        ).createShader(full),
    );

    // Stars.
    final star = Paint()..color = Colors.white.withValues(alpha: 0.7);
    final rng = math.Random(7);
    for (var i = 0; i < 28; i++) {
      final p = Offset(rng.nextDouble() * w, rng.nextDouble() * h * 0.35);
      canvas.drawCircle(p, rng.nextDouble() * 1.1 + 0.3, star);
    }

    // Sun on the horizon with a glow.
    final sun = Offset(w * 0.86, h * 0.5);
    canvas.drawCircle(
      sun,
      h * 0.3,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Brand.ember.withValues(alpha: 0.55),
            Brand.ember.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: sun, radius: h * 0.3)),
    );
    canvas.drawCircle(sun, h * 0.09, Paint()..color = const Color(0xFFFFC46B));

    // Far Sinai peaks.
    _ridge(canvas, size, const [
      0.0,
      0.62,
      0.08,
      0.5,
      0.14,
      0.55,
      0.22,
      0.4,
      0.3,
      0.52,
      0.36,
      0.47,
      0.44,
      0.58,
      0.52,
      0.45,
      0.6,
      0.53,
      0.68,
      0.42,
      0.78,
      0.56,
      0.86,
      0.5,
      0.94,
      0.58,
      1.0,
      0.52,
    ], const Color(0xFF7A3B34));

    // Nearer canyon walls.
    _ridge(canvas, size, const [
      0.0,
      0.7,
      0.1,
      0.63,
      0.18,
      0.66,
      0.26,
      0.6,
      0.34,
      0.68,
      0.5,
      0.66,
      0.58,
      0.72,
      0.7,
      0.64,
      0.8,
      0.69,
      0.9,
      0.62,
      1.0,
      0.67,
    ], const Color(0xFF4E2A2A));

    // Dunes.
    final dune1 = Path()
      ..moveTo(0, h * 0.8)
      ..cubicTo(w * 0.25, h * 0.7, w * 0.45, h * 0.86, w * 0.7, h * 0.78)
      ..cubicTo(w * 0.85, h * 0.73, w * 0.95, h * 0.76, w, h * 0.74)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(dune1, Paint()..color = Brand.sandDeep);
    final dune2 = Path()
      ..moveTo(0, h * 0.9)
      ..cubicTo(w * 0.3, h * 0.82, w * 0.6, h * 0.95, w, h * 0.86)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(dune2, Paint()..color = Brand.sand);

    // Trail winding towards the mountains.
    final trail = Path()
      ..moveTo(w * 0.12, h)
      ..cubicTo(w * 0.3, h * 0.92, w * 0.18, h * 0.86, w * 0.36, h * 0.82)
      ..cubicTo(w * 0.5, h * 0.79, w * 0.46, h * 0.76, w * 0.56, h * 0.73);
    final dash = Paint()
      ..color = Brand.ember
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final metric in trail.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 12) {
        canvas.drawPath(metric.extractPath(d, d + 6), dash);
      }
    }
  }

  void _ridge(Canvas canvas, Size size, List<double> xy, Color color) {
    final p = Path()..moveTo(0, size.height);
    for (var i = 0; i < xy.length; i += 2) {
      p.lineTo(xy[i] * size.width, xy[i + 1] * size.height);
    }
    p
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DesertPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// App icon artwork
// ---------------------------------------------------------------------------

/// Square launcher-icon artwork: the ibex against a desert dusk with the sun
/// rising behind its horn. Rendered to PNGs by `test/tool/app_icon_test.dart`.
class AppIconPainter extends CustomPainter {
  const AppIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final full = Offset.zero & size;
    canvas.drawRect(
      full,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Brand.night, Color(0xFF3B2C3C), Brand.canyon],
          stops: [0, 0.55, 1],
        ).createShader(full),
    );
    final sun = Offset(s * 0.7, s * 0.3);
    canvas.drawCircle(
      sun,
      s * 0.3,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Brand.ember.withValues(alpha: 0.6),
            Brand.ember.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: sun, radius: s * 0.3)),
    );
    canvas.drawCircle(sun, s * 0.15, Paint()..color = const Color(0xFFFFC46B));
    paintIbex(
      canvas,
      Rect.fromLTWH(s * 0.08, s * 0.16, s * 0.86, s * 0.86),
      color: Brand.limestone,
      cutout: Brand.night,
    );
  }

  @override
  bool shouldRepaint(AppIconPainter oldDelegate) => false;
}
