import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The delete zone at the top of Home: the page itself turning into a
/// whirlpool, seen at a slant, with no drawn lines.
///
/// It is made of soft layers of the page's own (darkened) colour. Each
/// layer carries a few smeared crests; inner layers turn faster than outer
/// ones (as water does), so the crests wind into spirals that sink into a
/// dark eye. It is the page's colour until a card comes near: [near] (0–1)
/// warms it to [red]. [gulp] (0–1) widens and deepens it while it swallows.
class NoorWhirlpoolPainter extends CustomPainter {
  NoorWhirlpoolPainter({
    required this.turn,
    required this.near,
    required this.gulp,
    required this.page,
    required this.dark,
    this.red = const Color(0xFFD64545),
    this.centre = const Offset(0.5, 0.42),
  });

  /// 0–1, one full turn of the outer water.
  final double turn;
  final double near;
  final double gulp;

  /// The page colour, and whether the page is dark.
  final Color page;
  final bool dark;
  final Color red;

  /// The eye, as a fraction of the size.
  final Offset centre;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * centre.dx, size.height * centre.dy);
    final reach = size.width * (0.7 + 0.1 * gulp);

    // The water's colour: the page darkened (or lifted, at night), warming
    // to red as a card comes near.
    final shade = dark ? Colors.black : const Color(0xFF3A2418);
    final tone = Color.lerp(shade, red, near.clamp(0.0, 1.0))!;
    final depth = 0.55 + 0.35 * near + 0.25 * gulp;

    canvas.save();
    // Seen at a slant: a wide, shallow ellipse.
    canvas.translate(c.dx, c.dy);
    canvas.scale(1, 0.3);

    // The basin: the page sinking towards the middle.
    canvas.drawCircle(
      Offset.zero,
      reach,
      Paint()
        ..shader = RadialGradient(colors: [
          tone.withOpacity(0.55 * depth),
          tone.withOpacity(0.22 * depth),
          tone.withOpacity(0.06 * depth),
          tone.withOpacity(0),
        ], stops: const [
          0,
          0.25,
          0.6,
          1
        ]).createShader(Rect.fromCircle(center: Offset.zero, radius: reach)),
    );

    // The turning water: broad, blurred bands winding into the middle,
    // dark crests and light troughs by turns. They thin and fade before
    // the eye, so nothing ever meets in a point or shows an edge.
    const arms = 6;
    for (var i = 0; i < arms; i++) {
      final crest = i.isEven;
      final band = Path();
      const steps = 36;
      final outer = <Offset>[], inner = <Offset>[];
      for (var k = 0; k <= steps; k++) {
        final f = k / steps; // 0 at the rim → 1 near the eye
        final r = reach * (0.96 - 0.76 * f);
        // Inner water turns faster: the arm winds as it sinks.
        final theta = (turn * (1 + 2.2 * f) + i / arms) * 2 * math.pi + f * 3.4;
        final half = (0.30 - 0.18 * f) * (math.pi / arms) * 2;
        outer.add(Offset(math.cos(theta - half), math.sin(theta - half)) * r);
        inner.add(Offset(math.cos(theta + half), math.sin(theta + half)) * r);
      }
      band.moveTo(outer.first.dx, outer.first.dy);
      for (final p in outer.skip(1)) {
        band.lineTo(p.dx, p.dy);
      }
      for (final p in inner.reversed) {
        band.lineTo(p.dx, p.dy);
      }
      band.close();
      final a = (crest ? 0.30 : 0.16) * depth;
      canvas.drawPath(
        band,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, reach * 0.07)
          ..color = crest
              ? tone.withOpacity(a)
              : Colors.white.withOpacity(dark ? a * 0.35 : a * 0.9),
      );
    }

    // The eye: dark and soft, the bottom of the funnel.
    final eye = reach * (0.10 + 0.05 * gulp);
    canvas.drawCircle(
      Offset.zero,
      eye * 2.4,
      Paint()
        ..shader = RadialGradient(colors: [
          (dark ? Colors.black : const Color(0xFF1F120B))
              .withOpacity(0.85 * depth.clamp(0.0, 1.0)),
          tone.withOpacity(0.35 * depth),
          tone.withOpacity(0),
        ], stops: const [
          0,
          0.4,
          1
        ]).createShader(
            Rect.fromCircle(center: Offset.zero, radius: eye * 2.4)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(NoorWhirlpoolPainter old) =>
      old.turn != turn ||
      old.near != near ||
      old.gulp != gulp ||
      old.page != page ||
      old.dark != dark;
}
