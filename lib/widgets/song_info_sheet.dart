import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/song.dart';
import '../services/song_details.dart';
import '../theme/noor_artwork.dart';
import '../theme/noor_disc.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';

/// Opens the song's details from the top of the player (swipe down there).
///
/// The page dims and softly blurs; the panel drops in like a record sleeve
/// pulled from a shelf. Once it lands, the record slides half out of its
/// sleeve and starts to turn, and the notes below come in one after
/// another. Swipe it back up (it follows the finger), tap outside, or tap
/// the handle to put it away.
Future<void> showSongInfo(BuildContext context, Song song,
    {VoidCallback? onAddToPlaylist}) {
  HapticFeedback.selectionClick();
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierLabel: 'Close details',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 1100),
    reverseTransitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (_, anim, __) => SongInfoSheet(
        song: song, animation: anim, onAddToPlaylist: onAddToPlaylist),
    transitionsBuilder: (context, anim, _, child) {
      // The backdrop: dim + blur, quicker than the panel.
      final t = NoorTheme.of(context);
      final a = Curves.easeOut.transform((anim.value / 0.35).clamp(0.0, 1.0));
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8 * a, sigmaY: 8 * a),
              child: ColoredBox(
                  color:
                      (t.isDark ? Colors.black : t.ac).withOpacity(0.28 * a)),
            ),
          ),
        ),
        child,
      ]);
    },
  ));
}

class SongInfoSheet extends ConsumerStatefulWidget {
  const SongInfoSheet({
    super.key,
    required this.song,
    required this.animation,
    this.onAddToPlaylist,
  });

  final Song song;
  final Animation<double> animation;

  /// Closes the sheet and opens the add-to-playlist panel.
  final VoidCallback? onAddToPlaylist;

  @override
  ConsumerState<SongInfoSheet> createState() => _SongInfoSheetState();
}

class _SongInfoSheetState extends ConsumerState<SongInfoSheet>
    with SingleTickerProviderStateMixin {
  /// The record's slow turn.
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))
        ..repeat();

  /// How far the panel has been pulled back up by the finger (px).
  double _pull = 0;
  bool _readMore = false;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  /// 0→1 over [a, b] of the opening (the animation's own 0–1).
  double _step(double a, double b, [Curve curve = Curves.easeOutCubic]) {
    final v = widget.animation.value;
    // While closing, everything leaves together (no stagger backwards).
    if (widget.animation.status == AnimationStatus.reverse) return v;
    return curve.transform(((v - a) / (b - a)).clamp(0.0, 1.0));
  }

  /// A piece of the notes, coming in at [a]: fades in and rises a little.
  Widget _enter(double a, Widget child) {
    final v = _step(a, a + 0.3);
    return Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final song = widget.song;
    final details = song.isLocal
        ? const AsyncValue<SongDetails?>.data(null)
        : ref.watch(songDetailsProvider(song.videoId));
    final d = details.valueOrNull;
    final mq = MediaQuery.of(context);
    final maxH = mq.size.height * 0.86;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.animation, _spin]),
      builder: (context, _) {
        // The panel drops in from above (and follows the finger back up).
        final drop = _step(0, 0.42, Curves.easeOutCubic);
        final dy = -(1 - drop) * maxH - _pull;
        final sleeve = _step(0.22, 0.6, Curves.easeOutBack);
        final record = _step(0.42, 0.82, Curves.easeOutCubic);

        return Align(
          alignment: Alignment.topCenter,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: GestureDetector(
              onVerticalDragUpdate: (g) =>
                  setState(() => _pull = math.max(0, _pull - g.delta.dy)),
              onVerticalDragEnd: (g) {
                if (_pull > 90 || (g.primaryVelocity ?? 0) < -400) {
                  _close();
                } else {
                  setState(() => _pull = 0);
                }
              },
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: double.infinity,
                  constraints: BoxConstraints(maxHeight: maxH),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: t.bg,
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(36)),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          blurRadius: 30,
                          offset: const Offset(0, 12)),
                    ],
                  ),
                  child: Stack(children: [
                    // The artwork, blown up and blurred: the room's light.
                    Positioned.fill(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                        child: Transform.scale(
                            scale: 1.4,
                            child: NoorArtwork(url: song.thumbnailUrl)),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              t.bg.withOpacity(0.55),
                              t.bg.withOpacity(0.88),
                              t.bg.withOpacity(0.97),
                            ],
                            stops: const [0, 0.38, 0.7],
                          ),
                        ),
                      ),
                    ),
                    _content(context, t, song, details, d, mq, sleeve, record),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    NoorTheme t,
    Song song,
    AsyncValue<SongDetails?> details,
    SongDetails? d,
    MediaQueryData mq,
    double sleeve,
    double record,
  ) {
    const art = 148.0;
    final stats = <(String, String)>[
      if (d?.views != null) (SongDetails.compactCount(d!.views!), 'views'),
      if (d?.likes != null) (SongDetails.compactCount(d!.likes!), 'likes'),
      if (d?.published != null)
        (SongDetails.monthYear(d!.published!), 'released'),
      if (d?.duration != null && d!.duration! > Duration.zero)
        (SongDetails.clock(d.duration!), 'length'),
    ];
    final credits = d?.credits ?? const <(String, String)>[];
    final about = d?.description.trim() ?? '';

    return ListView(
      shrinkWrap: true,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(22, mq.padding.top + 18, 22, 0),
      children: [
        // ── The sleeve and its record ──────────────────────────────────
        SizedBox(
          height: art + 8,
          child: Stack(clipBehavior: Clip.none, children: [
            // The record slides out to the right of the sleeve and turns.
            Positioned(
              left: art * 0.12 + record * art * 0.52,
              top: 4,
              child: Opacity(
                opacity: record.clamp(0.0, 1.0),
                child: RotationTransition(
                  turns: _spin,
                  child: NoorDisc(url: song.thumbnailUrl, size: art),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: Transform.scale(
                scale: 0.86 + 0.14 * sleeve,
                alignment: Alignment.centerLeft,
                child: Opacity(
                  opacity: sleeve.clamp(0.0, 1.0),
                  child: Container(
                    width: art,
                    height: art,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 18,
                            offset: const Offset(4, 8)),
                      ],
                    ),
                    child: Stack(fit: StackFit.expand, children: [
                      NoorArtwork(url: song.thumbnailUrl),
                      // A sleeve's sheen and its opening edge.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.18),
                              Colors.transparent,
                              Colors.black.withOpacity(0.12),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 10,
                        bottom: 10,
                        width: 3,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 20),

        // ── Title and who put it out ───────────────────────────────────
        _enter(
            0.45,
            Text(song.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: noorSongTitleStyle(t.ac, size: 30))),
        const SizedBox(height: 6),
        _enter(
            0.5,
            Row(children: [
              Icon(
                  song.isLocal
                      ? Icons.phone_android_rounded
                      : Icons.smart_display_outlined,
                  size: 16,
                  color: t.mute),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                    song.isLocal
                        ? '${song.artist.isEmpty ? 'Unknown artist' : song.artist} · on this phone'
                        : (d?.channel ?? song.artist),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: t.ac,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              if (song.isOfficial) ...[
                const SizedBox(width: 6),
                Icon(Icons.verified_rounded, size: 15, color: t.ac),
              ],
            ])),
        const SizedBox(height: 18),

        // ── Loading / nothing ──────────────────────────────────────────
        if (details.isLoading)
          _enter(
              0.55,
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                    minHeight: 2,
                    color: t.ac,
                    backgroundColor: t.ac.withOpacity(0.12)),
              ))
        else if (!song.isLocal && d == null)
          _enter(
              0.55,
              Text(
                  'More details could not be loaded right now (no connection or YouTube is busy).',
                  style: TextStyle(color: t.mute, fontSize: 13, height: 1.35))),

        // ── The numbers, as tiles ──────────────────────────────────────
        if (stats.isNotEmpty)
          _enter(
              0.55,
              Row(children: [
                for (var i = 0; i < stats.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                      child: _Stat(value: stats[i].$1, label: stats[i].$2)),
                ],
              ])),

        // ── Liner notes: who made it ───────────────────────────────────
        if (credits.isNotEmpty || (d?.hasMusicTags ?? false)) ...[
          const SizedBox(height: 22),
          _enter(0.62, const _Heading('Liner notes')),
          const SizedBox(height: 4),
          for (final (label, value) in [
            ...credits,
            if (d?.albumName != null && !credits.any((c) => c.$1 == 'Album'))
              ('Album', d!.albumName!),
          ])
            _enter(0.66, _Credit(label: label, value: value)),
        ],

        // ── Tags ───────────────────────────────────────────────────────
        if ((d?.keywords ?? const []).isNotEmpty) ...[
          const SizedBox(height: 18),
          _enter(
              0.7,
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final k in d!.keywords.take(8))
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.wash,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('#${k.replaceAll(' ', '')}',
                        style: TextStyle(
                            color: t.mute,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600)),
                  ),
              ])),
        ],

        // ── About ──────────────────────────────────────────────────────
        if (about.isNotEmpty) ...[
          const SizedBox(height: 22),
          _enter(0.72, const _Heading('About')),
          const SizedBox(height: 6),
          _enter(
              0.74,
              GestureDetector(
                onTap: () => setState(() => _readMore = !_readMore),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(about,
                          maxLines: _readMore ? 40 : 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t.ac, fontSize: 13, height: 1.45)),
                      const SizedBox(height: 4),
                      Text(_readMore ? 'Less' : 'More',
                          style: TextStyle(
                              color: t.mute,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              )),
        ],

        // ── What to do with it ─────────────────────────────────────────
        const SizedBox(height: 22),
        _enter(
            0.78,
            Row(children: [
              if (widget.onAddToPlaylist != null)
                Expanded(
                  child: _Action(
                    icon: Icons.playlist_add_rounded,
                    label: 'Add to playlist',
                    filled: true,
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onAddToPlaylist!();
                    },
                  ),
                ),
              if (widget.onAddToPlaylist != null && !song.isLocal)
                const SizedBox(width: 10),
              if (!song.isLocal)
                Expanded(
                  child: _Action(
                    icon: Icons.open_in_new_rounded,
                    label: 'YouTube',
                    onTap: () => launchUrl(
                        Uri.parse(
                            'https://www.youtube.com/watch?v=${song.videoId}'),
                        mode: LaunchMode.externalApplication),
                  ),
                ),
            ])),

        // ── Handle: tap, or swipe up anywhere, to close ────────────────
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _close,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 14),
            child: Center(
              child: Container(
                width: 46,
                height: 5,
                decoration: BoxDecoration(
                  color: t.soft,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Row(children: [
      Text(text.toUpperCase(),
          style: TextStyle(
              color: t.mute,
              fontSize: 11,
              letterSpacing: 2.2,
              fontWeight: FontWeight.w800)),
      const SizedBox(width: 10),
      Expanded(child: Container(height: 0.8, color: t.faint)),
    ]);
  }
}

/// A number with its word under it, on frosted glass.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            color: t.bg.withOpacity(0.55),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.faint, width: 0.8),
          ),
          child: Column(children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(
                      color: t.ac, fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: t.mute,
                    fontSize: 11,
                    letterSpacing: 0.4,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// "Singer ........ Arijit Singh": a role and a name joined by dots, like
/// the credits on the back of a record.
class _Credit extends StatelessWidget {
  const _Credit({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  color: const Color(0xFFB8893F),
                  fontSize: 11.5,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w800)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: CustomPaint(
                  size: const Size(double.infinity, 2), painter: _Dots(t.soft)),
            ),
          ),
          Flexible(
            flex: 3,
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: t.ac, fontSize: 14.5, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _Dots extends CustomPainter {
  _Dots(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var x = 0.0; x < size.width; x += 5) {
      canvas.drawCircle(Offset(x, size.height / 2), 0.9, p);
    }
  }

  @override
  bool shouldRepaint(_Dots old) => old.color != color;
}

class _Action extends StatelessWidget {
  const _Action(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.filled = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: filled ? t.ac : Colors.transparent,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: t.ac, width: 1),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 18, color: filled ? t.onAc : t.ac),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: filled ? t.onAc : t.ac,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5)),
          ),
        ]),
      ),
    );
  }
}
