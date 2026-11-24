import 'dart:math';

import 'package:flutter/material.dart';

/// What a message in the island is about. Each kind has its own small
/// moving symbol at the start, and the light running around the island's
/// edge takes its colour.
enum IslandKind {
  general,
  offline,
  online,
  knock,
  welcome,
  star,
  music,
  sync,
  copy,
  remove,
  update,
  warning,
}

const _gold = Color(0xFFD8B06A);
const _red = Color(0xFFE25A52);
const _green = Color(0xFF55D17F);
const _amber = Color(0xFFE8A33D);

extension IslandKindLook on IslandKind {
  Color get color => switch (this) {
        IslandKind.offline => _red,
        IslandKind.online => _green,
        IslandKind.warning => _amber,
        _ => _gold,
      };
}

/// Works out the kind from what a message says (so every message in the
/// app gets a fitting symbol, wherever it comes from).
IslandKind islandKindFor(String message) {
  final m = message.toLowerCase();
  bool has(List<String> words) => words.any(m.contains);
  if (m.startsWith('back online')) return IslandKind.online;
  if (has(['offline', 'no connection', "can't reach youtube"])) {
    return IslandKind.offline;
  }
  if (has(['updating noor', 'update'])) return IslandKind.update;
  if (has(['wants to join', 'asking to join'])) return IslandKind.knock;
  if (has([
    'skipped',
    'could not',
    "couldn't",
    "can't",
    'refused',
    'limiting',
    'busy',
    'is full',
    'already exists',
    'up to ',
    'not saved yet',
    'said no',
  ])) {
    return IslandKind.warning;
  }
  if (has(['star'])) return IslandKind.star;
  if (has(['sync', 'in step'])) return IslandKind.sync;
  if (has(['copied'])) return IslandKind.copy;
  if (has([
    'removed',
    'cleared',
    'deleted',
    'left the room',
    'has ended',
    'no longer'
  ])) {
    return IslandKind.remove;
  }
  if (has(["you're in", 'added to', 'created', '✓'])) {
    return IslandKind.welcome;
  }
  if (has([
    'asked for',
    'plays next',
    'in the queue',
    'to play',
    'playing',
    'song'
  ])) {
    return IslandKind.music;
  }
  return IslandKind.general;
}

/// The moving symbol for [kind]; [t] runs 0 → 1 over and over, [intro]
/// 0 → 1 once as the island opens.
class IslandGlyph extends StatelessWidget {
  const IslandGlyph(
      {super.key, required this.kind, required this.t, this.intro = 1});
  final IslandKind kind;
  final double t;
  final double intro;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(painter: _GlyphPainter(kind, t, intro)),
      );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.kind, this.t, this.intro);
  final IslandKind kind;
  final double t;
  final double intro;

  Paint _stroke(double alpha, [double w = 1.8]) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = kind.color.withValues(alpha: alpha.clamp(0.0, 1.0));

  Paint _fill(double alpha) =>
      Paint()..color = kind.color.withValues(alpha: alpha.clamp(0.0, 1.0));

  /// 0 → 1 → 0 once per cycle, offset by [phase].
  double _wave(double phase) => 0.5 - 0.5 * cos(2 * pi * ((t + phase) % 1));

  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final o = Offset(w / 2, h / 2);
    switch (kind) {
      case IslandKind.general:
        for (var i = 0; i < 3; i++) {
          final bh = 4 + 11 * (0.5 + 0.5 * sin(2 * pi * (t * 2 + i * 0.27)));
          final x = 4.0 + i * 6;
          c.drawLine(Offset(x, h / 2 - bh / 2), Offset(x, h / 2 + bh / 2),
              _stroke(1, 3));
        }
      case IslandKind.offline:
      case IslandKind.online:
        // Wi-Fi: arcs from a dot. Offline: they fade out from the outside
        // in, then a slash crosses them. Online: they light up from the
        // inside out.
        final base = Offset(w / 2, h - 3);
        c.drawCircle(base, 1.6, _fill(1));
        for (var i = 0; i < 3; i++) {
          final r = 5.0 + i * 4.5;
          final a = kind == IslandKind.online
              ? ((t * 4 - i).clamp(0.0, 1.0))
              : (1 - (t * 4 - (2 - i)).clamp(0.0, 1.0)) * 0.9 + 0.1;
          c.drawArc(Rect.fromCircle(center: base, radius: r), -pi * 0.78,
              pi * 0.56, false, _stroke(a));
        }
        if (kind == IslandKind.offline) {
          final k = ((t - 0.55) / 0.3).clamp(0.0, 1.0);
          if (k > 0) {
            c.drawLine(
                const Offset(3, 3),
                Offset.lerp(const Offset(3, 3), Offset(w - 3, h - 3), k)!,
                _stroke(1, 2));
          }
        }
      case IslandKind.knock:
        // Knock, knock: rings spread from a point, two at a time.
        c.drawCircle(o, 2.4, _fill(1));
        for (final p in [0.0, 0.18]) {
          final k = ((t * 1.4 - p) % 1).clamp(0.0, 1.0);
          c.drawCircle(o, 3 + 7 * k, _stroke(1 - k, 1.5));
        }
      case IslandKind.welcome:
        // A tick drawing itself, then resting, then again.
        final k = (t / 0.45).clamp(0.0, 1.0);
        final path = Path()
          ..moveTo(3.5, 10.5)
          ..lineTo(8, 15)
          ..lineTo(16.5, 5);
        final m = path.computeMetrics().first;
        c.drawPath(m.extractPath(0, m.length * k), _stroke(1, 2.2));
        c.drawCircle(o, 9.2, _stroke(0.35 * (1 - k * 0.5), 1));
      case IslandKind.star:
        // A star turning a little and breathing, sparkles popping.
        c.save();
        c.translate(o.dx, o.dy);
        c.rotate(0.35 * sin(2 * pi * t));
        final sc = 0.85 + 0.18 * _wave(0);
        c.scale(sc, sc);
        final star = Path();
        for (var i = 0; i < 10; i++) {
          final r = i.isEven ? 7.5 : 3.2;
          final a = -pi / 2 + i * pi / 5;
          final p = Offset(r * cos(a), r * sin(a));
          i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
        }
        star.close();
        c.drawPath(star, _fill(1));
        c.restore();
        for (final (x, y, p) in [
          (2.5, 3.0, 0.0),
          (17.5, 4.0, 0.45),
          (16.0, 17.0, 0.7)
        ]) {
          final k = _wave(p);
          final r = 2.2 * k;
          c.drawLine(Offset(x - r, y), Offset(x + r, y), _stroke(k, 1.2));
          c.drawLine(Offset(x, y - r), Offset(x, y + r), _stroke(k, 1.2));
        }
      case IslandKind.music:
        // Notes floating up and fading, one after the other.
        for (final (x, p) in [(5.0, 0.0), (13.0, 0.5)]) {
          final k = (t + p) % 1;
          final y = h - 3 - 9 * k;
          final a = sin(pi * k);
          c.drawOval(
              Rect.fromCenter(center: Offset(x, y), width: 5, height: 3.8),
              _fill(a));
          c.drawLine(
              Offset(x + 2.3, y), Offset(x + 2.3, y - 8), _stroke(a, 1.5));
          c.drawLine(
              Offset(x + 2.3, y - 8), Offset(x + 5, y - 6.5), _stroke(a, 1.5));
        }
      case IslandKind.sync:
        // Two arrows chasing round a circle.
        c.save();
        c.translate(o.dx, o.dy);
        c.rotate(2 * pi * t);
        const r = 6.8;
        for (var i = 0; i < 2; i++) {
          c.save();
          c.rotate(pi * i);
          // An arc of about 130°, ending in a filled arrowhead.
          const start = 0.35, sweep = 2.25;
          c.drawArc(Rect.fromCircle(center: Offset.zero, radius: r), start,
              sweep, false, _stroke(1));
          const end = start + sweep;
          final tip = Offset(r * cos(end + 0.32), r * sin(end + 0.32));
          final back = Offset(r * cos(end - 0.15), r * sin(end - 0.15));
          final out = Offset(cos(end), sin(end)) * 2.8;
          c.drawPath(
              Path()
                ..moveTo(tip.dx, tip.dy)
                ..lineTo(back.dx + out.dx, back.dy + out.dy)
                ..lineTo(back.dx - out.dx, back.dy - out.dy)
                ..close(),
              _fill(1));
          c.restore();
        }
        c.restore();
      case IslandKind.copy:
        // One page slides onto the other.
        final back = RRect.fromRectAndRadius(
            const Rect.fromLTWH(2, 2, 10, 12), const Radius.circular(2));
        c.drawRRect(back, _stroke(0.55, 1.5));
        final k = Curves.easeInOut.transform((t / 0.6).clamp(0.0, 1.0));
        final dx = 6 * (1 - k) + 6, dy = 6 * (1 - k) + 4;
        final front = RRect.fromRectAndRadius(
            Rect.fromLTWH(dx, dy, 10, 12), const Radius.circular(2));
        c.drawRRect(front, _fill(0.25));
        c.drawRRect(front, _stroke(1, 1.6));
      case IslandKind.remove:
        // A bin, its lid lifting and dropping.
        c.drawRRect(
            RRect.fromRectAndRadius(
                const Rect.fromLTWH(5, 7, 10, 11), const Radius.circular(2)),
            _stroke(1, 1.6));
        c.drawLine(
            const Offset(8.5, 10), const Offset(8.5, 15), _stroke(0.7, 1.2));
        c.drawLine(
            const Offset(11.5, 10), const Offset(11.5, 15), _stroke(0.7, 1.2));
        // The lid hinges at its left end and lifts on the right.
        final lift = 0.6 * _wave(0);
        c.save();
        c.translate(3.5, 5.5);
        c.rotate(-lift);
        c.translate(-3.5, -5.5);
        c.drawLine(
            const Offset(3.5, 5.5), const Offset(16.5, 5.5), _stroke(1, 1.8));
        c.drawLine(const Offset(8.5, 5.5), const Offset(9, 3), _stroke(1, 1.5));
        c.drawLine(const Offset(9, 3), const Offset(11, 3), _stroke(1, 1.5));
        c.drawLine(
            const Offset(11, 3), const Offset(11.5, 5.5), _stroke(1, 1.5));
        c.restore();
      case IslandKind.update:
        // An arrow dropping into a tray.
        final tray = Path()
          ..moveTo(3, 12)
          ..lineTo(3, 17)
          ..lineTo(17, 17)
          ..lineTo(17, 12);
        c.drawPath(tray, _stroke(1, 1.6));
        final k = Curves.easeIn.transform(t % 1);
        final y = -2 + 11 * k;
        final a = k < 0.85 ? 1.0 : (1 - (k - 0.85) / 0.15);
        c.drawLine(Offset(10, y - 6), Offset(10, y + 3), _stroke(a, 1.8));
        c.drawLine(Offset(10, y + 3), Offset(6.5, y - 0.5), _stroke(a, 1.8));
        c.drawLine(Offset(10, y + 3), Offset(13.5, y - 0.5), _stroke(a, 1.8));
      case IslandKind.warning:
        // A warning sign giving a little shake.
        final k = t % 1;
        final shake =
            k < 0.35 ? 2.2 * sin(k / 0.35 * 6 * pi) * (1 - k / 0.35) : 0;
        c.save();
        c.translate(shake.toDouble(), 0);
        final tri = Path()
          ..moveTo(10, 2.5)
          ..lineTo(18, 17)
          ..lineTo(2, 17)
          ..close();
        c.drawPath(tri, _stroke(1, 1.7));
        c.drawLine(const Offset(10, 8), const Offset(10, 12), _stroke(1, 2));
        c.drawCircle(const Offset(10, 14.6), 1.2, _fill(1));
        c.restore();
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.t != t || old.kind != kind || old.intro != intro;
}
