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
      vsync: this, duration: const Duration(milliseconds: 3200));

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
        final t = _show.value * 3200; // ms into the show
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
                        height: 286,
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

/// The earbuds and their halo. [ms]: time into the show; [float]: 0–1 loop.
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

  double _seg(double a, double b) => ((ms - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final bud = math.min(size.height * 0.92, size.width * 0.26);

    // How "apart" and how visible the buds are, and the halo.
    double apart, lift, alpha, grey, halo, turn;
    if (connected) {
      final inT = Curves.easeOutCubic.transform(_seg(180, 1050));
      final settle = Curves.elasticOut.transform(_seg(700, 1700));
      apart = 1.9 - 1.9 * inT; // from far out to their place
      turn = (1 - settle) * 0.55;
      lift = math.sin(float * 2 * math.pi) * 3 * _seg(1000, 1600);
      alpha = Curves.easeOut.transform(_seg(180, 600));
      grey = 0;
      halo = Curves.easeOutCubic.transform(_seg(800, 1500)) *
          (0.85 + 0.15 * math.sin(float * 2 * math.pi));
    } else {
      final go = Curves.easeInOutCubic.transform(_seg(750, 1950));
      apart = 0.55 * go;
      turn = -0.35 * go;
      lift = -26 * go * go;
      alpha = Curves.easeOut.transform(_seg(150, 500)) * (1 - 0.75 * go);
      grey = go;
      halo = (Curves.easeOut.transform(_seg(150, 650))) * (1 - go);
    }

    // Halo: a soft warm light behind, and a thin ring.
    if (halo > 0) {
      const gold = Color(0xFFD8B06A);
      canvas.drawCircle(
          c,
          bud * 0.95,
          Paint()
            ..color = gold.withOpacity((dark ? 0.22 : 0.18) * halo)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, bud * 0.35));
      canvas.drawCircle(
          c,
          bud * (0.78 + 0.08 * halo),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = gold.withOpacity(0.35 * halo));
    }

    final gap = bud * 0.30 + apart * bud;
    _bud(canvas, c + Offset(-gap, -lift), bud,
        right: false, turn: turn, alpha: alpha, grey: grey);
    _bud(canvas, c + Offset(gap, -lift), bud,
        right: true, turn: turn, alpha: alpha, grey: grey);
  }

  /// One earbud (the right one is the left mirrored), centred on [at],
  /// [h] tall: a rounded head with its speaker grille and a slim stem with
  /// a polished tip; lit from the top left, with a soft contact shadow.
  void _bud(Canvas canvas, Offset at, double h,
      {required bool right,
      required double turn,
      required double alpha,
      required double grey}) {
    if (alpha <= 0) return;
    final w = h * 0.5;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    if (right) canvas.scale(-1, 1);
    canvas.rotate(-0.18 + turn);

    // Shadow under the bud.
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(w * 0.08, h * 0.52),
            width: w * 0.9,
            height: h * 0.07),
        Paint()
          ..color = Colors.black.withOpacity(0.18 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.04));

    final shellTop =
        Color.lerp(Colors.white, const Color(0xFFBDBDBD), grey * 0.6)!;
    final shellBottom = Color.lerp(
        const Color(0xFFD9DCE1), const Color(0xFF9E9E9E), grey * 0.6)!;
    Paint shell(Rect r) => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [shellTop.withOpacity(alpha), shellBottom.withOpacity(alpha)],
      ).createShader(r);

    // Stem: from under the head down to the tip, slightly angled.
    final stemTop = Offset(w * 0.08, -h * 0.08);
    final stemBottom = Offset(w * 0.16, h * 0.44);
    final stemW = w * 0.30;
    final stem = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: (stemTop + stemBottom) / 2,
              width: stemW,
              height: (stemBottom - stemTop).distance),
          Radius.circular(stemW / 2)));
    canvas.save();
    final mid = (stemTop + stemBottom) / 2;
    canvas.translate(mid.dx, mid.dy);
    canvas.rotate(
        -math.atan2(stemBottom.dx - stemTop.dx, stemBottom.dy - stemTop.dy));
    canvas.translate(-mid.dx, -mid.dy);
    canvas.drawPath(stem, shell(stem.getBounds()));
    // Polished tip.
    final tipRect = Rect.fromCenter(
        center: Offset(mid.dx, stemBottom.dy - stemW * 0.35),
        width: stemW * 0.92,
        height: stemW * 0.5);
    canvas.drawRRect(
        RRect.fromRectAndRadius(tipRect, Radius.circular(stemW * 0.3)),
        Paint()
          ..shader = LinearGradient(colors: [
            const Color(0xFFE9EBEE).withOpacity(alpha),
            const Color(0xFFB4B8BF).withOpacity(alpha),
          ]).createShader(tipRect));
    // A soft highlight along the stem.
    canvas.drawLine(
        Offset(mid.dx - stemW * 0.22, stemTop.dy + stemW * 0.6),
        Offset(mid.dx - stemW * 0.22, stemBottom.dy - stemW * 0.9),
        Paint()
          ..strokeWidth = stemW * 0.12
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.7 * alpha));
    canvas.restore();

    // Head: a rounded body, wider than the stem.
    final headC = Offset(-w * 0.02, -h * 0.22);
    final headRect =
        Rect.fromCenter(center: headC, width: w * 0.98, height: w * 0.88);
    canvas.drawOval(
        headRect.shift(Offset(0, h * 0.012)),
        Paint()
          ..color = Colors.black.withOpacity(0.10 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.02));
    canvas.drawOval(headRect, shell(headRect));
    // Ear tip: a softer, slightly darker cap on the inner side.
    final tip = Rect.fromCenter(
        center: headC + Offset(-w * 0.34, w * 0.02),
        width: w * 0.42,
        height: w * 0.5);
    canvas.drawOval(
        tip,
        Paint()
          ..shader = RadialGradient(colors: [
            Color.lerp(const Color(0xFFF2F3F5), const Color(0xFFBDBDBD),
                    grey * 0.6)!
                .withOpacity(alpha),
            Color.lerp(const Color(0xFFC9CDD3), const Color(0xFF9E9E9E),
                    grey * 0.6)!
                .withOpacity(alpha),
          ]).createShader(tip));
    // Speaker grille: a dark slot near the tip.
    final grille = Rect.fromCenter(
        center: headC + Offset(-w * 0.12, -w * 0.18),
        width: w * 0.26,
        height: w * 0.09);
    canvas.drawRRect(RRect.fromRectAndRadius(grille, Radius.circular(w * 0.05)),
        Paint()..color = const Color(0xFF2E3136).withOpacity(0.85 * alpha));
    // Sensor dot.
    canvas.drawCircle(headC + Offset(w * 0.22, w * 0.12), w * 0.035,
        Paint()..color = const Color(0xFF4A4E55).withOpacity(0.7 * alpha));
    // Light on the head.
    canvas.drawOval(
        Rect.fromCenter(
            center: headC + Offset(-w * 0.05, -w * 0.24),
            width: w * 0.5,
            height: w * 0.16),
        Paint()
          ..color = Colors.white.withOpacity(0.85 * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.04));

    canvas.restore();
  }

  @override
  bool shouldRepaint(BudsPainter old) =>
      old.ms != ms ||
      old.float != float ||
      old.connected != connected ||
      old.dark != dark;
}
