import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/noor_palette.dart';
export 'island_glyphs.dart' show IslandKind;
import 'island_glyphs.dart';
import '../theme/noor_search_button.dart';

/// Noor's messages: a dark capsule that grows out of a dot in the header,
/// between the logo and the search button (like a phone's island), says
/// its piece and shrinks away on its own. Tap it or swipe it up to dismiss
/// sooner. One at a time: a new message replaces the one showing.
class NoorToast {
  NoorToast._();

  static OverlayEntry? _entry;

  /// Shows [message] above the page [context] belongs to. With [action], a
  /// button such as "Undo" sits at the end and the message stays longer.
  static void show(
    BuildContext context,
    String message, {
    String? action,
    VoidCallback? onAction,
    Duration? duration,
    IslandKind? kind,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    showIn(overlay, message,
        action: action, onAction: onAction, duration: duration, kind: kind);
  }

  /// Same, for code without a page context (the app's own notices).
  static void showIn(
    OverlayState overlay,
    String message, {
    String? action,
    VoidCallback? onAction,
    Duration? duration,
    IslandKind? kind,
  }) {
    _entry?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _Island(
        message: message,
        kind: kind ?? islandKindFor(message),
        action: action,
        onAction: onAction,
        showFor: duration ??
            (action != null
                ? const Duration(milliseconds: 4500)
                : const Duration(milliseconds: 2600)),
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
  }
}

class _Island extends StatefulWidget {
  const _Island({
    required this.message,
    required this.kind,
    required this.showFor,
    required this.onGone,
    this.action,
    this.onAction,
  });

  final String message;

  /// What it's about: picks the moving symbol and the light's colour.
  final IslandKind kind;
  final String? action;
  final VoidCallback? onAction;
  final Duration showFor;
  final VoidCallback onGone;

  @override
  State<_Island> createState() => _IslandState();
}

class _IslandState extends State<_Island> with TickerProviderStateMixin {
  /// 0: a dot; 1: the full capsule with its text.
  late final AnimationController _open = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 280));

  /// How long it stays (a ticker, so nothing is left pending if the page
  /// goes away).
  late final AnimationController _life =
      AnimationController(vsync: this, duration: widget.showFor);

  /// The running light around the edge and the sound bars, while it shows.
  late final AnimationController _run = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1700))
    ..repeat();

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _open.forward();
    _life.forward().whenComplete(_close);
  }

  Future<void> _close() async {
    if (_closing || !mounted) return;
    _closing = true;
    _life.stop();
    await _open.reverse();
    if (mounted) widget.onGone();
  }

  @override
  void dispose() {
    _open.dispose();
    _life.dispose();
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final top = MediaQuery.paddingOf(context).top + 14;
    // The island's colours: deep espresso with the ivory and gold of the
    // palette, the same in light and dark mode.
    const island = Color(0xFF1F1914);
    const ink = Color(0xFFF6EFE8);
    const gold = Color(0xFFD8B06A);

    // Centred on the screen whatever sits on either side (the logo on one,
    // two buttons on the other), over everything.
    final screen = MediaQuery.sizeOf(context).width;
    final width = min(screen - 32, 340.0);
    return Positioned(
      top: top,
      left: (screen - width) / 2,
      width: width,
      height: kNoorHeaderSize,
      // A Material ancestor so the text gets the app's font and style.
      child: Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(builder: (context, box) {
          return AnimatedBuilder(
            animation: Listenable.merge([_open, _run]),
            builder: (context, _) {
              final v =
                  Curves.easeOutBack.transform(_open.value.clamp(0.0, 1.0));
              // Arriving, it squashes and springs like a drop (taller
              // then settling), the way a phone's island takes a message.
              final o = _open.value.clamp(0.0, 1.0);
              final squash =
                  _closing ? 1.0 : 1 + 0.16 * sin(o * pi * 1.6) * (1 - o) * 1.8;
              final w = kNoorHeaderSize +
                  (box.maxWidth - kNoorHeaderSize) * v.clamp(0.0, 1.05);
              final textIn = ((_open.value - 0.45) / 0.55).clamp(0.0, 1.0);
              return Align(
                alignment: Alignment.center,
                child: Opacity(
                  opacity: _open.value.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scaleY: squash.clamp(0.85, 1.25),
                    scaleX: (2 - squash).clamp(0.9, 1.1),
                    child: GestureDetector(
                      onTap: _close,
                      onVerticalDragEnd: (d) {
                        if ((d.primaryVelocity ?? 0) < -100) _close();
                      },
                      child: Semantics(
                        liveRegion: true,
                        label: widget.message,
                        child: CustomPaint(
                          foregroundPainter: _RunningLight(
                              _run.value, textIn, widget.kind.color),
                          child: Container(
                            width: w.clamp(kNoorHeaderSize, box.maxWidth + 4),
                            height: kNoorHeaderSize,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: island,
                              borderRadius:
                                  BorderRadius.circular(kNoorHeaderSize / 2),
                              boxShadow: [
                                BoxShadow(
                                    color: t.ac.withOpacity(0.25),
                                    blurRadius: 14,
                                    offset: const Offset(0, 4)),
                              ],
                            ),
                            child: Opacity(
                              opacity: textIn,
                              child: Row(children: [
                                IslandGlyph(kind: widget.kind, t: _run.value),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(widget.message,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: ink,
                                          fontSize: 12.5,
                                          height: 1.2,
                                          fontWeight: FontWeight.w600)),
                                ),
                                if (widget.action != null) ...[
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      widget.onAction?.call();
                                      _close();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      child: Text(widget.action!,
                                          style: const TextStyle(
                                              color: gold,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800)),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// A light running around the island's edge, a short gold comet with a
/// fading tail, while a message shows.
class _RunningLight extends CustomPainter {
  _RunningLight(this.t, this.show, this.color);
  final double t;
  final double show;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (show <= 0 || size.width <= 0) return;
    final r = RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.75), Radius.circular(size.height / 2));
    final metric = (Path()..addRRect(r)).computeMetrics().first;
    final len = metric.length;
    final head = len * t;
    const pieces = 10;
    final tail = len * 0.22;
    for (var i = 0; i < pieces; i++) {
      final a = (head - tail * (i + 1) / pieces) % len;
      final b = (head - tail * i / pieces) % len;
      final seg = a < b
          ? metric.extractPath(a, b)
          : (metric.extractPath(a, len)
            ..addPath(metric.extractPath(0, b), Offset.zero));
      final k = (1 - i / pieces) * show;
      canvas.drawPath(
          seg,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: 0.9 * k)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6));
    }
  }

  @override
  bool shouldRepaint(_RunningLight old) =>
      old.t != t || old.show != show || old.color != color;
}
