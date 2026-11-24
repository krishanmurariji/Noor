import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/audio_devices.dart';

/// A card that rises from the bottom of the screen when earbuds or
/// headphones connect or disconnect, shows them, and sinks away by itself.
/// Nothing stays on screen afterwards.
///
/// * Connected: the two earbuds glide in from either side, turn into place
///   and settle with a gentle float while a warm halo breathes behind them.
/// * Disconnected: they rest together, then drift apart and down, fading to
///   grey as the halo closes.
///
/// Tap it or swipe it down to dismiss sooner.
class BudsPopup {
  BudsPopup._();

  static OverlayEntry? _entry;

  static void showIn(OverlayState overlay, AudioDeviceEvent event) {
    _entry?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => BudsCard(
        event: event,
        onGone: () {
          if (identical(_entry, entry)) {
            entry.remove();
            _entry = null;
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    HapticFeedback.lightImpact();
  }
}

class BudsCard extends StatefulWidget {
  const BudsCard({super.key, required this.event, required this.onGone});
  final AudioDeviceEvent event;
  final VoidCallback onGone;

  @override
  State<BudsCard> createState() => _BudsCardState();
}

class _BudsCardState extends State<BudsCard> with TickerProviderStateMixin {
  /// The whole show: rise, buds, hold.
  late final AnimationController _show = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3800));

  /// Leaving: the card sinks away.
  late final AnimationController _leave = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));

  /// The buds' slow float (connected).
  late final AnimationController _float = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat();

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _show.forward().whenComplete(_close);
  }

  Future<void> _close() async {
    if (_closing || !mounted) return;
    _closing = true;
    _show.stop();
    await _leave.forward();
    if (mounted) widget.onGone();
  }

  @override
  void dispose() {
    _show.dispose();
    _leave.dispose();
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mq = MediaQuery.of(context);
    final width = math.min(mq.size.width - 20, 400.0);
    final e = widget.event;
    final name = e.name.isEmpty ? (e.wired ? 'Headphones' : 'Earbuds') : e.name;

    final card = dark ? const Color(0xFF1F1914) : const Color(0xFFFBF8F4);
    final ink = dark ? const Color(0xFFF6EFE8) : const Color(0xFF2B211A);
    final mute = dark ? const Color(0xFFB9AA9A) : const Color(0xFF8A7B6C);
    const gold = Color(0xFFD8B06A);

    return AnimatedBuilder(
      animation: Listenable.merge([_show, _leave, _float]),
      builder: (context, _) {
        final t = _show.value * 3800; // ms into the show
        double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

        final rise = Curves.easeOutBack.transform(seg(0, 520));
        final out = Curves.easeInCubic.transform(_leave.value);
        final shift = (1 - rise) * 320 + out * 340;
        final dim = 0.16 * seg(0, 300) * (1 - out);
        final textIn = Curves.easeOut.transform(seg(700, 1100));

        return Stack(children: [
          // A light dim behind, so the card reads as floating above.
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withOpacity(dim)),
            ),
          ),
          Positioned(
            left: (mq.size.width - width) / 2,
            width: width,
            bottom: 12 + mq.padding.bottom - shift,
            // A Material ancestor so the text gets the app's font and style.
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                onTap: _close,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 80) _close();
                },
                child: Semantics(
                  liveRegion: true,
                  label: '$name ${e.connected ? 'connected' : 'disconnected'}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(40),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        height: 330,
                        decoration: BoxDecoration(
                          color: card.withOpacity(0.96),
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(
                              color: gold.withOpacity(0.25), width: 0.8),
                        ),
                        child: Column(children: [
                          const SizedBox(height: 22),
                          Opacity(
                            opacity: Curves.easeOut.transform(seg(250, 650)),
                            child: Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: ink,
                                    fontSize: 18,
                                    letterSpacing: 0.2,
                                    fontWeight: FontWeight.w700)),
                          ),
                          Expanded(
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: BudsPainter(
                                ms: t,
                                float: _float.value,
                                connected: e.connected,
                                dark: dark,
                              ),
                            ),
                          ),
                          Opacity(
                            opacity: textIn,
                            child: Transform.translate(
                              offset: Offset(0, 6 * (1 - textIn)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: e.connected ? gold : mute,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                      e.connected
                                          ? 'Connected'
                                          : 'Disconnected',
                                      style: TextStyle(
                                          color: mute,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// The charging case and the earbuds, lit from the top left.
///
/// Connected: the case settles in, its lid opens, the buds rise out of their
/// slots and float above it in a warm glow; the case's light turns gold.
/// Disconnected: the buds sink back in, the lid closes and everything fades
/// to grey. [ms]: time into the show; [float]: 0–1 loop.
class BudsPainter extends CustomPainter {
  BudsPainter({
    required this.ms,
    required this.float,
    required this.connected,
    required this.dark,
  });

  final double ms;
  final double float;
  final bool connected;
  final bool dark;

  double _seg(double a, double b, [Curve c = Curves.easeInOutCubic]) =>
      c.transform(((ms - a) / (b - a)).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final cw = math.min(size.width * 0.46, size.height * 0.64);
    final ch = cw * 0.74;
    final caseCentre = Offset(size.width / 2, size.height * 0.95 - ch / 2);

    // Where things are in the show.
    double appear, lid, rise, grey, halo;
    if (connected) {
      appear = _seg(150, 650, Curves.easeOutBack);
      lid = _seg(600, 1150);
      rise = _seg(1050, 1950, Curves.easeOutCubic);
      grey = 0;
      halo = _seg(1500, 2200) * (0.85 + 0.15 * math.sin(float * 2 * math.pi));
    } else {
      appear = _seg(0, 450, Curves.easeOutCubic) * (1 - _seg(2500, 3300));
      rise = 1 - _seg(700, 1500);
      lid = 1 - _seg(1400, 1950);
      grey = _seg(1900, 2600);
      halo = (1 - _seg(500, 1300)) * _seg(0, 400);
    }
    if (appear <= 0) return;
    // The spring may overshoot for the motion; colours stay within 0–1.
    final fade = appear.clamp(0.0, 1.0).toDouble();
    final bob =
        connected ? math.sin(float * 2 * math.pi) * cw * 0.012 * rise : 0.0;

    canvas.save();
    // The whole set eases in from a little lower and smaller.
    canvas.translate(0, (1 - appear) * ch * 0.25);
    final scale = 0.9 + 0.1 * appear;
    canvas.translate(caseCentre.dx, caseCentre.dy);
    canvas.scale(scale);
    canvas.translate(-caseCentre.dx, -caseCentre.dy);

    const gold = Color(0xFFD8B06A);
    // Halo behind.
    if (halo > 0) {
      final hc = caseCentre - Offset(0, ch * 0.95);
      canvas.drawCircle(
          hc,
          cw * 0.75,
          Paint()
            ..shader = RadialGradient(colors: [
              gold.withOpacity((dark ? 0.30 : 0.24) * halo),
              gold.withOpacity(0),
            ]).createShader(Rect.fromCircle(center: hc, radius: cw * 0.75)));
    }

    final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: caseCentre, width: cw, height: ch),
        Radius.circular(ch * 0.46));
    final seamY = body.top + ch * 0.36;

    // Shadow on the card.
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(caseCentre.dx, body.bottom + ch * 0.05),
            width: cw * 1.05,
            height: ch * 0.16),
        Paint()
          ..color = Colors.black.withOpacity(0.22 * fade)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, ch * 0.08));

    // The lid, swinging back: it rises, flattens and shows its underside.
    _lid(canvas, body, seamY, lid, grey, fade);

    // The opening and the two slots.
    if (lid > 0.02) {
      final opening = Rect.fromCenter(
          center: Offset(caseCentre.dx, seamY),
          width: cw * 0.86,
          height: ch * 0.30 * lid);
      canvas.drawOval(
          opening,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1E2024), Color(0xFF3C4047)],
            ).createShader(opening));
      for (final side in [-1.0, 1.0]) {
        final well = Rect.fromCenter(
            center: Offset(caseCentre.dx + side * cw * 0.2, seamY),
            width: cw * 0.24,
            height: ch * 0.14 * lid);
        canvas.drawOval(well, Paint()..color = const Color(0xFF101114));
      }
    }

    // The buds, rising out of their slots.
    final budH = ch * 0.98;
    for (final right in [false, true]) {
      final side = right ? 1.0 : -1.0;
      final inCase =
          Offset(caseCentre.dx + side * cw * 0.2, seamY - budH * 0.02);
      final aloft =
          Offset(caseCentre.dx + side * cw * 0.3, body.top - budH * 0.62 + bob);
      final at = Offset.lerp(inCase, aloft, rise)!;
      final tilt = side * (0.05 + 0.25 * rise);
      if (rise > 0.02 || lid > 0.3) {
        // Inside the case the stems go down into it: nothing below its
        // floor ever shows.
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(-1e4, -1e4, 1e4, body.bottom - ch * 0.1));
        _bud(canvas, at, budH,
            right: right,
            tilt: tilt,
            alpha: fade,
            grey: grey,
            shadowBelow:
                rise > 0.6 ? Offset(at.dx, body.top - ch * 0.02) : null);
        canvas.restore();
      }
    }

    // The front of the case, over the buds' lower halves while inside.
    canvas.save();
    canvas.clipRect(
        Rect.fromLTRB(body.left - 2, seamY, body.right + 2, body.bottom + 2));
    _shell(canvas, body, grey, fade);
    canvas.restore();
    // A thin seam where the lid meets the case.
    canvas.drawLine(
        Offset(body.left + ch * 0.12, seamY),
        Offset(body.right - ch * 0.12, seamY),
        Paint()
          ..strokeWidth = 1
          ..color = Colors.black.withOpacity(0.12 * fade));
    // The status light.
    final led = Offset(caseCentre.dx, body.top + ch * 0.62);
    final ledOn = connected ? _seg(1300, 1700) : (1 - grey);
    canvas.drawCircle(
        led,
        ch * 0.035,
        Paint()
          ..color = Color.lerp(const Color(0xFF9BA0A8), gold, ledOn)!
              .withOpacity(fade));
    if (ledOn > 0) {
      canvas.drawCircle(
          led,
          ch * 0.08,
          Paint()
            ..color = gold.withOpacity(0.35 * ledOn * fade)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, ch * 0.04));
    }
    canvas.restore();
  }

  Color _g(Color c, double grey) =>
      Color.lerp(c, Color.lerp(c, const Color(0xFF9E9E9E), 0.7)!, grey)!;

  /// The glossy white shell of the case (body).
  void _shell(Canvas canvas, RRect body, double grey, double alpha) {
    canvas.drawRRect(
        body,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _g(const Color(0xFFFFFFFF), grey),
              _g(const Color(0xFFF1F2F4), grey),
              _g(const Color(0xFFCFD2D8), grey),
            ],
            stops: const [0, 0.55, 1],
          ).createShader(body.outerRect)
          ..color = Colors.white.withOpacity(alpha));
    // Light from the top left, and a soft shade on the right.
    canvas.drawRRect(
        body,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.6, -0.7),
            radius: 1.1,
            colors: [
              Colors.white.withOpacity(0.7 * alpha),
              Colors.white.withOpacity(0),
            ],
          ).createShader(body.outerRect));
    canvas.drawRRect(
        body,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.transparent,
              Colors.black.withOpacity(0.10 * alpha),
            ],
            stops: const [0.6, 1],
          ).createShader(body.outerRect));
  }

  /// The lid: closed it is the top of the case; opening, it swings back
  /// (rises and flattens) and its darker underside shows.
  void _lid(Canvas canvas, RRect body, double seamY, double open, double grey,
      double alpha) {
    final h = seamY - body.top;
    final squash = 1 - 0.55 * open;
    // Hinged at the back: it stays on the opening's far rim as it swings.
    final lift = body.height * 0.15 * open;
    final rect = Rect.fromLTRB(
        body.left, seamY - lift - h * squash, body.right, seamY - lift);
    final shape = RRect.fromRectAndCorners(rect,
        topLeft: Radius.elliptical(body.tlRadiusX, body.tlRadiusY * squash),
        topRight: Radius.elliptical(body.trRadiusX, body.trRadiusY * squash),
        bottomLeft: Radius.circular(h * 0.25 * open),
        bottomRight: Radius.circular(h * 0.25 * open));
    canvas.drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _g(
                  Color.lerp(
                      const Color(0xFFFFFFFF), const Color(0xFFD9DCE1), open)!,
                  grey),
              _g(
                  Color.lerp(
                      const Color(0xFFF0F1F4), const Color(0xFFB9BDC4), open)!,
                  grey),
            ],
          ).createShader(rect)
          ..color = Colors.white.withOpacity(alpha));
    if (open > 0.05) {
      // The underside's dark inner rim.
      canvas.drawRRect(
          shape.deflate(rect.height * 0.12),
          Paint()
            ..color = const Color(0xFF3A3E45).withOpacity(0.55 * open * alpha));
    }
  }

  /// One earbud, [h] tall from the top of the head to the end of the stem,
  /// head centred near [at]. The right bud is the left one mirrored.
  void _bud(Canvas canvas, Offset at, double h,
      {required bool right,
      required double tilt,
      required double alpha,
      required double grey,
      Offset? shadowBelow}) {
    if (alpha <= 0) return;
    if (shadowBelow != null) {
      canvas.drawOval(
          Rect.fromCenter(
              center: shadowBelow, width: h * 0.32, height: h * 0.06),
          Paint()
            ..color = Colors.black.withOpacity(0.12 * alpha)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.04));
    }
    final w = h * 0.42; // head width
    canvas.save();
    canvas.translate(at.dx, at.dy);
    if (right) canvas.scale(-1, 1);
    canvas.rotate(-tilt);

    // Stem: a polished cylinder going down from under the head.
    final stemW = w * 0.34;
    final stem = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.02, w * 0.18, stemW, h - w * 0.62),
        Radius.circular(stemW / 2));
    canvas.drawRRect(
        stem,
        Paint()
          ..shader = LinearGradient(colors: [
            _g(const Color(0xFFB4B9C1), grey),
            _g(const Color(0xFFF3F4F6), grey),
            _g(const Color(0xFFFFFFFF), grey),
            _g(const Color(0xFFDDE0E5), grey),
            _g(const Color(0xFFA3A8B1), grey),
          ], stops: const [
            0,
            0.22,
            0.4,
            0.72,
            1
          ]).createShader(stem.outerRect)
          ..color = Colors.white.withOpacity(alpha));
    // Metal cap at the end.
    final cap = Rect.fromLTWH(
        stem.left, stem.bottom - stemW * 0.55, stemW, stemW * 0.55);
    canvas.drawRRect(
        RRect.fromRectAndCorners(cap,
            bottomLeft: Radius.circular(stemW / 2),
            bottomRight: Radius.circular(stemW / 2)),
        Paint()
          ..shader = LinearGradient(colors: [
            const Color(0xFF8D929B).withOpacity(alpha),
            const Color(0xFFE4E6EA).withOpacity(alpha),
            const Color(0xFF9AA0A8).withOpacity(alpha),
          ]).createShader(cap));
    // Where the stem meets the head: a soft contact shade.
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(stem.center.dx, w * 0.22),
            width: stemW * 1.3,
            height: w * 0.12),
        Paint()
          ..color = Colors.black.withOpacity(0.10 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.03));

    // Head: a glossy sphere, a little wider than tall.
    final head = Rect.fromCenter(
        center: Offset(-w * 0.04, -w * 0.12), width: w, height: w * 0.88);
    canvas.drawOval(
        head,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.45),
            radius: 0.95,
            colors: [
              _g(const Color(0xFFFFFFFF), grey),
              _g(const Color(0xFFF4F5F7), grey),
              _g(const Color(0xFFD4D7DD), grey),
              _g(const Color(0xFFA6ABB4), grey),
            ],
            stops: const [0, 0.38, 0.78, 1],
          ).createShader(head)
          ..color = Colors.white.withOpacity(alpha));
    // Light bouncing up onto the lower right edge.
    canvas.drawArc(
        head.deflate(w * 0.03),
        0.2,
        1.4,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.05
          ..color = Colors.white.withOpacity(0.45 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.025));
    // Silicone ear tip on the inner side, soft and slightly translucent.
    final tip = Rect.fromCenter(
        center: head.centerLeft + Offset(w * 0.06, w * 0.05),
        width: w * 0.42,
        height: w * 0.5);
    canvas.drawOval(
        tip,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.3),
            colors: [
              _g(const Color(0xFFF7F7F8), grey).withOpacity(alpha),
              _g(const Color(0xFFC7CBD1), grey).withOpacity(alpha),
            ],
          ).createShader(tip));
    canvas.drawOval(
        Rect.fromCenter(
            center: tip.center,
            width: tip.width * 0.36,
            height: tip.height * 0.4),
        Paint()..color = const Color(0xFF8F949C).withOpacity(0.55 * alpha));
    // Speaker grille: a dark slot with a lit lower lip.
    final grille = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: head.center + Offset(w * 0.08, -w * 0.2),
            width: w * 0.3,
            height: w * 0.08),
        Radius.circular(w * 0.04));
    canvas.drawRRect(grille,
        Paint()..color = const Color(0xFF26292E).withOpacity(0.9 * alpha));
    canvas.drawLine(
        grille.outerRect.bottomLeft + Offset(w * 0.03, w * 0.012),
        grille.outerRect.bottomRight - Offset(w * 0.03, -w * 0.012),
        Paint()
          ..strokeWidth = w * 0.012
          ..color = Colors.white.withOpacity(0.7 * alpha));
    // Sensor.
    canvas.drawCircle(head.center + Offset(w * 0.28, w * 0.12), w * 0.03,
        Paint()..color = const Color(0xFF3E4248).withOpacity(0.75 * alpha));
    // Specular highlight.
    canvas.drawOval(
        Rect.fromCenter(
            center: head.center + Offset(-w * 0.18, -w * 0.22),
            width: w * 0.26,
            height: w * 0.12),
        Paint()
          ..color = Colors.white.withOpacity(0.9 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.03));
    canvas.restore();
  }

  @override
  bool shouldRepaint(BudsPainter old) =>
      old.ms != ms ||
      old.float != float ||
      old.connected != connected ||
      old.dark != dark;
}
