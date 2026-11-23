import 'dart:math';
import 'package:flutter/material.dart';
import 'noor_artwork.dart';

/// A turntable seen from above: a light rounded plinth, a grey platter well,
/// a black record whose centre label is the song's artwork, a tone arm on
/// the top right, a pitch slider and a knob.
///
/// * [spinning]: the record turns;
/// * [armDown]: the stylus rests on the record (lifted and swung out when
///   false);
/// * [discShift]: moves the record sideways, as a fraction of the size
///   (used when one record is swapped for the next);
/// * [incomingArtUrl] / [incomingShift]: a second record (not turning) at
///   that shift, the one sliding in while the record is swiped.
/// * [volume]: the phone's volume (0–1) shown by the slider on the right;
///   its dot is blue up to 60 % and red above. Drag the slider (or tap
///   along it) to change the volume ([onVolume], [onVolumeHold]).
/// * The knob opens the equalizer ([onKnob]); [knobTurn] (0–1) is where
///   it points and [eqOn] lights its little lamp.
class NoorTurntable extends StatefulWidget {
  const NoorTurntable({
    super.key,
    required this.size,
    required this.artUrl,
    required this.spinning,
    required this.armDown,
    this.discShift = 0,
    this.incomingArtUrl,
    this.incomingShift = 0,
    this.volume,
    this.onVolume,
    this.onVolumeHold,
    this.onKnob,
    this.knobTurn = 0,
    this.eqOn = false,
  });

  final double? volume;
  final ValueChanged<double>? onVolume;
  final ValueChanged<bool>? onVolumeHold;
  final VoidCallback? onKnob;
  final double knobTurn;
  final bool eqOn;

  /// The tone arm's base: centre and radius, as fractions of the size.
  static const Offset armBase = Offset(0.84, 0.16);
  static const double armBaseRadius = 0.095;

  /// The knob mirrors the arm's base: same size, the same distance from the
  /// bottom as the base is from the top.
  static const Offset knobCentre = Offset(0.84, 1 - 0.16);
  static const double knobRadius = armBaseRadius;

  /// The volume slider: halfway between the arm's base and the knob, and
  /// with the same gap to the record's well (which ends at 0.87) as to the
  /// edge of the body (0.982).
  static const double sliderX = 0.935, sliderTop = 0.41, sliderBottom = 0.59;

  /// The volume slider's dot: blue up to 60 %, red above.
  static Color volumeDot(double v) =>
      v > 0.6 + 1e-9 ? const Color(0xFFD2412F) : const Color(0xFF3D7BE0);

  /// The volume for a touch at [y] (a fraction of the size): top = loudest.
  static double volumeAt(double y) =>
      ((sliderBottom - y) / (sliderBottom - sliderTop)).clamp(0.0, 1.0);

  final String? incomingArtUrl;
  final double incomingShift;
  final double size;
  final String artUrl;
  final bool spinning;
  final bool armDown;
  final double discShift;

  /// Record centre and radius, as fractions of [size].
  static const Offset discCentre = Offset(0.45, 0.5);
  static const double discRadius = 0.39;

  @override
  State<NoorTurntable> createState() => _NoorTurntableState();
}

class _NoorTurntableState extends State<NoorTurntable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(NoorTurntable old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.spinning && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final d = NoorTurntable.discRadius * 2 * s;
    final c = NoorTurntable.discCentre;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: CustomPaint(painter: _PlinthPainter())),
          if (widget.incomingArtUrl != null)
            _record(s, d, c, widget.incomingShift, widget.incomingArtUrl!,
                turning: false),
          // The record (and its artwork label) turns and slides.
          _record(s, d, c, widget.discShift, widget.artUrl, turning: true),
          // Spindle (does not turn visibly, so outside the rotation).
          Positioned(
            left: c.dx * s - s * 0.014 + widget.discShift * s,
            top: c.dy * s - s * 0.014,
            child: Container(
              width: s * 0.028,
              height: s * 0.028,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: Alignment(-0.4, -0.4),
                  colors: [Color(0xFFE6E6E6), Color(0xFF8C8C8C)],
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black38,
                      blurRadius: 2,
                      offset: Offset(0.5, 1))
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: widget.volume ?? 0.42),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              builder: (context, vol, _) => TweenAnimationBuilder<double>(
                tween: Tween(end: widget.knobTurn),
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOutBack,
                builder: (context, turn, _) => CustomPaint(
                    painter: _ControlsPainter(
                        volume: vol, knobTurn: turn, eqOn: widget.eqOn)),
              ),
            ),
          ),
          // Tone arm, swinging about its pivot.
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: widget.armDown ? 0 : 1),
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeInOutCubic,
              builder: (context, lift, _) =>
                  CustomPaint(painter: _ArmPainter(lift)),
            ),
          ),
          // Touch areas, on top: the volume slider and the knob.
          if (widget.onVolume != null)
            Positioned(
              left: s * (NoorTurntable.sliderX - 0.055),
              top: s * (NoorTurntable.sliderTop - 0.05),
              width: s * 0.11,
              height: s *
                  (NoorTurntable.sliderBottom - NoorTurntable.sliderTop + 0.10),
              child: Semantics(
                slider: true,
                label: 'Volume',
                value: '${((widget.volume ?? 0) * 100).round()}%',
                child: GestureDetector(
                  key: const ValueKey('volume-slider'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (d) {
                    widget.onVolumeHold?.call(true);
                    _volumeAt(d.localPosition.dy);
                  },
                  onVerticalDragUpdate: (d) => _volumeAt(d.localPosition.dy),
                  onVerticalDragEnd: (_) => widget.onVolumeHold?.call(false),
                  onVerticalDragCancel: () => widget.onVolumeHold?.call(false),
                  onTapUp: (d) => _volumeAt(d.localPosition.dy),
                ),
              ),
            ),
          if (widget.onKnob != null)
            Positioned(
              left: s * (NoorTurntable.knobCentre.dx - 0.11),
              top: s * (NoorTurntable.knobCentre.dy - 0.11),
              width: s * 0.22,
              height: s * 0.22,
              child: Semantics(
                button: true,
                label: 'Equalizer',
                child: GestureDetector(
                  key: const ValueKey('eq-knob'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onKnob,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// [dy]: a touch in the slider's area, from its top edge.
  void _volumeAt(double dy) {
    final s = widget.size;
    final y = (dy + s * (NoorTurntable.sliderTop - 0.05)) / s;
    widget.onVolume?.call(NoorTurntable.volumeAt(y));
  }

  Widget _record(double s, double d, Offset c, double shift, String art,
      {required bool turning}) {
    final record = Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _VinylPainter()),
        Center(
          child: SizedBox(
            width: d * 0.41,
            height: d * 0.41,
            child: ClipOval(
              child: Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Color(0xFFE8673F)),
                if (art.isNotEmpty) NoorArtwork(url: art),
              ]),
            ),
          ),
        ),
        // Light sheen over the label so it sits under the same lighting as
        // the vinyl.
        CustomPaint(painter: _SheenPainter()),
      ],
    );
    return Positioned(
      left: c.dx * s - d / 2 + shift * s,
      top: c.dy * s - d / 2,
      width: d,
      height: d,
      child: turning ? RotationTransition(turns: _spin, child: record) : record,
    );
  }
}

/// The body: rounded plinth with a soft drop shadow and the grey well the
/// platter sits in.
class _PlinthPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final body =
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(s * 0.1));

    // Shadow under the body.
    canvas.drawRRect(
      body.shift(Offset(0, s * 0.03)),
      Paint()
        ..color = const Color(0xFF5A6478).withOpacity(0.22)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.035),
    );
    // Body.
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF4F3F1), Color(0xFFE2E1DE)],
        ).createShader(Offset.zero & size),
    );
    // Rim highlight / lower edge.
    canvas.drawRRect(
      body.deflate(s * 0.012),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.012
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withOpacity(0.9), const Color(0xFFCFCECB)],
        ).createShader(Offset.zero & size),
    );

    // Grey well: square on the left (clipped to the body), round on the right.
    final c = Offset(
        NoorTurntable.discCentre.dx * s, NoorTurntable.discCentre.dy * s);
    final r = s * 0.42;
    final well = Path()
      ..addRect(Rect.fromLTRB(0, c.dy - r, c.dx, c.dy + r))
      ..addOval(Rect.fromCircle(center: c, radius: r));
    canvas.save();
    canvas.clipRRect(body.deflate(s * 0.018));
    canvas.drawPath(
      well,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFADB3B2), Color(0xFF9EA4A6)],
        ).createShader(Offset.zero & size),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlinthPainter old) => false;
}

/// The black record with grooves, track gaps and two broad reflections.
class _VinylPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(
        c,
        r + 1,
        Paint()
          ..color = Colors.black.withOpacity(0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF111213));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withOpacity(0.06);
    for (var rr = r * 0.96; rr > r * 0.46; rr -= r * 0.022) {
      canvas.drawCircle(c, rr, groove);
    }
    final gap = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Colors.black.withOpacity(0.9);
    for (final f in [0.88, 0.76, 0.64, 0.55]) {
      canvas.drawCircle(c, r * f, gap);
    }
    // Lead-out ring around the label.
    canvas.drawCircle(c, r * 0.47, Paint()..color = const Color(0xFF0A0A0B));
    // Outer edge.
    canvas.drawCircle(
        c,
        r - 0.8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = const Color(0xFF2A2B2E));
  }

  @override
  bool shouldRepaint(_VinylPainter old) => false;
}

/// Two soft diagonal reflections across the record, like in a lit room.
class _SheenPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.saveLayer(rect, Paint());
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [
            Colors.white.withOpacity(0.0),
            Colors.white.withOpacity(0.16),
            Colors.white.withOpacity(0.0),
            Colors.white.withOpacity(0.0),
            Colors.white.withOpacity(0.13),
            Colors.white.withOpacity(0.0),
            Colors.white.withOpacity(0.0),
          ],
          stops: const [0.05, 0.13, 0.22, 0.55, 0.63, 0.72, 1.0],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter old) => false;
}

/// Volume slider and equalizer knob on the right of the plinth.
class _ControlsPainter extends CustomPainter {
  _ControlsPainter(
      {required this.volume, required this.knobTurn, required this.eqOn});
  final double volume;
  final double knobTurn;
  final bool eqOn;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // Slider slot.
    final x = s * NoorTurntable.sliderX;
    final top = s * NoorTurntable.sliderTop,
        bottom = s * NoorTurntable.sliderBottom;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTRB(x - s * 0.006, top, x + s * 0.006, bottom),
          Radius.circular(s * 0.006)),
      Paint()..color = const Color(0xFF3A3B3D),
    );
    final tick = Paint()..color = const Color(0xFF7F8590);
    for (var i = 0; i <= 12; i++) {
      final y = top + (bottom - top) * i / 12;
      final long = i % 3 == 0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x - s * (long ? 0.03 : 0.022), y - s * 0.002,
                s * (long ? 0.012 : 0.004), s * 0.004),
            Radius.circular(s * 0.002)),
        tick,
      );
    }
    // Slider cap: up = louder. Its dot is blue up to 60 %, red above.
    final capY = bottom - (bottom - top) * volume.clamp(0.0, 1.0);
    final cap = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(x, capY), width: s * 0.026, height: s * 0.05),
        Radius.circular(s * 0.006));
    canvas.drawRRect(
        cap.shift(Offset(0, s * 0.004)), Paint()..color = Colors.black26);
    canvas.drawRRect(
        cap,
        Paint()
          ..shader = const LinearGradient(
                  colors: [Color(0xFFF2F2F2), Color(0xFFCFCFCF)])
              .createShader(cap.outerRect));
    canvas.drawCircle(Offset(x, capY), s * 0.0045,
        Paint()..color = NoorTurntable.volumeDot(volume));

    // Knob (the equalizer).
    final k = Offset(
        s * NoorTurntable.knobCentre.dx, s * NoorTurntable.knobCentre.dy);
    final kr = s * NoorTurntable.knobRadius;
    canvas.drawCircle(
        k + Offset(0, s * 0.008),
        kr,
        Paint()
          ..color = Colors.black.withOpacity(0.18)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.01));
    canvas.drawCircle(
        k,
        kr,
        Paint()
          ..shader = const SweepGradient(colors: [
            Color(0xFFB9BCC4),
            Color(0xFFE9EAEE),
            Color(0xFF9DA1AA),
            Color(0xFFDADCE1),
            Color(0xFFA4A8B0),
            Color(0xFFE6E7EB),
            Color(0xFFB9BCC4),
          ]).createShader(Rect.fromCircle(center: k, radius: kr)));
    canvas.drawCircle(
        k,
        kr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF8E929B));
    // Points left when the equalizer is off, turns right through the presets.
    final a = -pi * 5 / 4 + knobTurn * pi * 1.5;
    canvas.drawLine(
        k + Offset(cos(a), sin(a)) * kr * 0.25,
        k + Offset(cos(a), sin(a)) * kr * 0.85,
        Paint()
          ..strokeWidth = s * 0.006
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF5D616A));
    // Its lamp: gold while the equalizer is on.
    final lamp = k + Offset(kr * 1.05, -kr * 1.05);
    if (eqOn) {
      canvas.drawCircle(
          lamp,
          s * 0.016,
          Paint()
            ..color = const Color(0xFFD8B06A).withOpacity(0.45)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.01));
    }
    canvas.drawCircle(
        lamp,
        s * 0.008,
        Paint()
          ..color = eqOn ? const Color(0xFFD8B06A) : const Color(0xFF4A4C50));
  }

  @override
  bool shouldRepaint(_ControlsPainter old) =>
      old.volume != volume || old.knobTurn != knobTurn || old.eqOn != eqOn;
}

/// The tone arm. [lift] 0 = stylus on the record, 1 = parked to the right.
class _ArmPainter extends CustomPainter {
  _ArmPainter(this.lift);
  final double lift;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final pivot =
        Offset(s * NoorTurntable.armBase.dx, s * NoorTurntable.armBase.dy);

    // Base (does not move).
    canvas.drawCircle(
        pivot + Offset(0, s * 0.006),
        s * 0.095,
        Paint()
          ..color = Colors.black.withOpacity(0.12)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.01));
    canvas.drawCircle(
        pivot, s * 0.095, Paint()..color = const Color(0xFF8D9097));
    canvas.drawCircle(
        pivot, s * 0.078, Paint()..color = const Color(0xFFB8BBC1));
    canvas.drawCircle(
        pivot, s * 0.064, Paint()..color = const Color(0xFF9A9DA3));

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    // Positive angle swings the arm clockwise, off the record.
    canvas.rotate(-0.22 * lift);
    canvas.translate(-pivot.dx, -pivot.dy);

    // Counterweight behind the pivot (up and to the right).
    final cwDir = Offset(cos(-1.05), sin(-1.05));
    final cwStart = pivot + cwDir * s * 0.03;
    final cwEnd = pivot + cwDir * s * 0.12;
    final cw = Paint()
      ..strokeWidth = s * 0.042
      ..strokeCap = StrokeCap.butt
      ..shader = const LinearGradient(
              colors: [Color(0xFFD9D9D9), Color(0xFFF7F7F7), Color(0xFFC8C8C8)])
          .createShader(Rect.fromPoints(cwStart, cwEnd));
    canvas.drawLine(cwStart, cwEnd, cw);
    canvas.drawLine(
        cwEnd - cwDir * s * 0.012,
        cwEnd,
        Paint()
          ..strokeWidth = s * 0.046
          ..color = const Color(0xFFBEBEBE));

    // Tube: from the pivot down, bending left into the headshell.
    final p1 = pivot + Offset(-s * 0.012, s * 0.07);
    final p2 = Offset(s * 0.795, s * 0.56);
    final p3 = Offset(s * 0.67, s * 0.735);
    final tube = Path()
      ..moveTo(pivot.dx, pivot.dy)
      ..lineTo(p1.dx, p1.dy)
      ..quadraticBezierTo(s * 0.81, s * 0.44, p2.dx, p2.dy)
      ..quadraticBezierTo(s * 0.775, s * 0.66, p3.dx, p3.dy);
    canvas.drawPath(
        tube,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.017
          ..strokeCap = StrokeCap.round
          ..color = Colors.black.withOpacity(0.15)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.006));
    canvas.drawPath(
        tube,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.014
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF8F949C));
    canvas.drawPath(
        tube,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.004
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.45));

    // Pivot cap on top of the tube.
    canvas.drawCircle(
        pivot,
        s * 0.044,
        Paint()
          ..shader = const RadialGradient(
                  center: Alignment(-0.3, -0.3),
                  colors: [Color(0xFFF5F5F5), Color(0xFFBDBDBD)])
              .createShader(Rect.fromCircle(center: pivot, radius: s * 0.044)));

    // Headshell: a white block angled along the end of the tube, a blue
    // cartridge and the finger lift.
    canvas.save();
    canvas.translate(p3.dx, p3.dy);
    canvas.rotate(0.92);
    final shell = RRect.fromRectAndRadius(
        Rect.fromLTWH(-s * 0.03, -s * 0.004, s * 0.06, s * 0.075),
        Radius.circular(s * 0.006));
    canvas.drawRRect(shell.shift(Offset(s * 0.004, s * 0.006)),
        Paint()..color = Colors.black26);
    canvas.drawRRect(shell, Paint()..color = const Color(0xFFF1F1F1));
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(-s * 0.022, s * 0.045, s * 0.034, s * 0.036),
            Radius.circular(s * 0.004)),
        Paint()..color = const Color(0xFF8DB8DE));
    canvas.drawLine(
        Offset(s * 0.022, s * 0.05),
        Offset(s * 0.05, s * 0.095),
        Paint()
          ..strokeWidth = s * 0.006
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFFF4F4F4));
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArmPainter old) => old.lift != lift;
}
