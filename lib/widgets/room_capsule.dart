import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/room_provider.dart';
import '../services/rooms/room.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';
import 'noor_toast.dart';
import 'room_sheet.dart';

/// Room colours that stay the same in light and dark mode.
class RoomCapsule {
  RoomCapsule._();
  static const island = Color(0xFF1F1914);
  static const gold = Color(0xFFD8B06A);
  static const live = Color(0xFFE25A52);
}

/// The room on the player: a full-width pill under the header.
///
/// * No room: "Listen together", and "Start · Join →" opens a code field
///   with Join (once a whole code is typed) and Create (the room's code
///   then shows in the field, with a thumbs-up to carry on).
/// * In a room: the others as overlapping initials on the left (five,
///   then "+N"; the code while nobody has joined), the star on the right
///   (★ and their name). Waiting requests: a count on its top-left corner.
///   Tap: the room panel. Swipe right: the pill slides almost out and
///   everyone shows as circles to scroll through; tap one for the full
///   name (the star long-presses for make star / remove / block). Swipe
///   left (or tap the pill's edge) to bring it back.
class RoomPill extends ConsumerStatefulWidget {
  const RoomPill({super.key});

  static const height = 46.0;

  @override
  ConsumerState<RoomPill> createState() => _RoomPillState();
}

class _RoomPillState extends ConsumerState<RoomPill> {
  bool _open = false; // no room: the code field is showing
  bool _reveal = false; // in a room: swiped right, everyone's circles show
  String? _named; // the circle showing its full name
  bool _busy = false;
  String? _error;
  final _code = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final why = await f();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = why;
    });
    if (why != null) NoorToast.show(context, why);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomProvider);
    // Leaving the room (or never having one) puts the pill back to rest.
    final alone = s.room != null && s.room!.members.length <= 1;
    if ((!s.inRoom || alone) && _reveal) _reveal = false;
    if (s.role == RoomRole.knocking || (s.inRoom && !alone)) _open = false;
    final available = ref.read(roomProvider.notifier).available;
    final Widget child;
    if (s.role == RoomRole.knocking) {
      child = _frame(_knocking(s));
    } else if (_open) {
      child = _frame(_join());
    } else if (s.inRoom && s.room != null && !alone) {
      child = _inRoom(s);
    } else if (!available) {
      child = _frame(_rest(),
          onTap: () => NoorToast.show(
              context, 'Rooms are not set up in this build of Noor yet'));
    } else {
      // This phone's own room: its code, and Join to go to someone's.
      final waiting = s.isStar ? (s.room?.waiting ?? 0) : 0;
      child = Stack(clipBehavior: Clip.none, children: [
        _frame(_home(s), onTap: () {
          if (s.inRoom) showRoomSheet(context);
        }),
        if (waiting > 0) Positioned(left: -4, top: -8, child: _badge(waiting)),
      ]);
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  // ── Pieces ──────────────────────────────────────────────────────────────

  Widget _frame(Widget row,
      {VoidCallback? onTap, Key key = const ValueKey('room-pill')}) {
    final t = NoorTheme.of(context);
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: Container(
        height: RoomPill.height,
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(RoomPill.height / 2),
          border: Border.all(color: t.ac, width: 1),
        ),
        child: row,
      ),
    );
  }

  Widget _round(IconData icon, String label, VoidCallback? onTap,
      {bool filled = false, Key? key}) {
    final t = NoorTheme.of(context);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        enabled: onTap != null,
        excludeSemantics: true,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap();
                },
          child: Opacity(
            opacity: onTap == null ? 0.35 : 1,
            child: Container(
              width: 36,
              height: 36,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: filled ? t.ac : null,
                shape: BoxShape.circle,
                border: filled ? null : Border.all(color: t.soft, width: 0.8),
              ),
              child: Icon(icon, size: 18, color: filled ? t.onAc : t.ac),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rest() {
    final t = NoorTheme.of(context);
    return Row(children: [
      Icon(Icons.people_alt_outlined, size: 19, color: t.ac),
      const SizedBox(width: 10),
      Expanded(
        child: Text('Listen together',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: noorSongTitleStyle(t.ac, size: 20)),
      ),
    ]);
  }

  /// This phone's own room: the code on the left (tap to copy), Join on
  /// the right.
  Widget _home(RoomState s) {
    final t = NoorTheme.of(context);
    final code = s.inRoom ? s.room?.code : null;
    return Row(children: [
      Icon(Icons.meeting_room_outlined, size: 20, color: t.ac),
      const SizedBox(width: 10),
      Expanded(
        child: code == null
            ? Text('Getting your room code…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.mute, fontSize: 13))
            : GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  NoorToast.show(context, 'Room code copied');
                },
                child: Text(code,
                    key: const ValueKey('room-pill-code'),
                    semanticsLabel:
                        'Your room code ${code.split('').join(' ')}',
                    style: TextStyle(
                        color: t.ac,
                        fontSize: 17,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w800)),
              ),
      ),
      GestureDetector(
        key: const ValueKey('room-join-open'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() {
            _open = true;
            _error = null;
            _code.clear();
          });
        },
        child: Container(
          height: 34,
          padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
          decoration: BoxDecoration(
              color: t.ac, borderRadius: BorderRadius.circular(17)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Join a room',
                style: TextStyle(
                    color: t.onAc, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward_rounded, size: 16, color: t.onAc),
          ]),
        ),
      ),
      const SizedBox(width: 2),
    ]);
  }

  /// The code field with Join and Create (or, the first time, the name).
  /// Joining someone's room: the code field on the left, cancel and Join
  /// (once the code is whole) on the right. The first time, the name.
  Widget _join() {
    final t = NoorTheme.of(context);
    final rooms = ref.read(roomProvider.notifier);
    final name = ref.watch(roomNameProvider);
    void close() => setState(() => _open = false);
    if (name.isEmpty) {
      return Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('room-name'),
            controller: _name,
            autofocus: true,
            maxLength: kRoomNameMax,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) => ref.read(roomNameProvider.notifier).set(v),
            style: TextStyle(
                color: t.ac, fontSize: 15, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
                isDense: true,
                counterText: '',
                border: InputBorder.none,
                hintText: 'Your name first',
                hintStyle:
                    TextStyle(color: t.mute, fontWeight: FontWeight.w400)),
          ),
        ),
        _round(Icons.close_rounded, 'Cancel', close,
            key: const ValueKey('room-join-cancel')),
        _round(
            Icons.check_rounded,
            'Save my name',
            _name.text.trim().isEmpty
                ? null
                : () => ref.read(roomNameProvider.notifier).set(_name.text),
            filled: true,
            key: const ValueKey('room-name-save')),
      ]);
    }
    final code = cleanRoomCode(_code.text);
    return Row(children: [
      Expanded(
        child: TextField(
          key: const ValueKey('room-code'),
          controller: _code,
          autofocus: true,
          maxLength: 7,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) {
            if (code != null && !_busy) _run(() => rooms.knock(code));
          },
          style: TextStyle(
              color: t.ac,
              fontSize: 16,
              letterSpacing: 3,
              fontWeight: FontWeight.w700),
          decoration: InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
              hintText: _error ?? "Friend's room code",
              hintStyle: TextStyle(
                  color: _error != null ? const Color(0xFFB23A2E) : t.mute,
                  letterSpacing: 0,
                  fontSize: 14,
                  fontWeight: FontWeight.w400)),
        ),
      ),
      _round(Icons.close_rounded, 'Cancel', close,
          key: const ValueKey('room-join-cancel')),
      _round(Icons.login_rounded, 'Join',
          _busy || code == null ? null : () => _run(() => rooms.knock(code)),
          filled: true, key: const ValueKey('room-join')),
    ]);
  }

  Widget _knocking(RoomState s) {
    final t = NoorTheme.of(context);
    return Row(children: [
      const _Pulse(),
      const SizedBox(width: 10),
      Expanded(
        child: Text('Asking to join · ${s.knockingName ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: t.ac, fontSize: 13.5, fontWeight: FontWeight.w600)),
      ),
      _round(Icons.close_rounded, 'Stop asking',
          () => ref.read(roomProvider.notifier).cancelKnock()),
    ]);
  }

  Widget _starName(RoomSnapshot room, String me) {
    final t = NoorTheme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.star_rounded, size: 18, color: t.ac, semanticLabel: 'star'),
      const SizedBox(width: 5),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 150),
        child: Text(
            room.starName.length > kRoomNameMax
                ? room.starName.substring(0, kRoomNameMax)
                : room.starName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: noorSongTitleStyle(t.ac, size: 20)),
      ),
    ]);
  }

  Widget _inRoom(RoomState s) {
    final room = s.room!;
    final me = ref.read(roomProvider.notifier).uid;
    final others = room.members.where((m) => m.uid != room.starUid).toList();
    final waiting = s.isStar ? room.waiting : 0;

    // Everyone but the star (who is on the right).
    final left = _Faces(members: others, away: s.away, me: me);
    final pill = _frame(
      Row(children: [
        left,
        const Spacer(),
        _starName(room, me),
        const SizedBox(width: 10),
      ]),
      onTap: () => showRoomSheet(context),
    );

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return SizedBox(
        height: RoomPill.height + 8,
        child: Stack(clipBehavior: Clip.none, children: [
          // Behind the pill: everyone, as circles to scroll through.
          if (_reveal)
            Positioned(
              left: 0,
              top: 4,
              width: w * 0.9 - 8,
              height: RoomPill.height,
              // Swipe left: back to the pill (once the circles are
              // scrolled to their end, or when they all fit).
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  final atEnd =
                      n.metrics.pixels >= n.metrics.maxScrollExtent - 1;
                  if ((n is OverscrollNotification &&
                          n.overscroll > 0 &&
                          n.dragDetails != null) ||
                      (n is ScrollEndNotification &&
                          atEnd &&
                          (n.dragDetails?.primaryVelocity ?? 0) < -150)) {
                    setState(() => _reveal = false);
                  }
                  return false;
                },
                child: GestureDetector(
                  onHorizontalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) < -150) {
                      setState(() => _reveal = false);
                    }
                  },
                  child: _everyone(room, s, me),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            left: _reveal ? w * 0.9 : 0,
            width: w,
            top: 4,
            child: GestureDetector(
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v > 150 && !_reveal) setState(() => _reveal = true);
                if (v < -150 && _reveal) setState(() => _reveal = false);
              },
              onTap: _reveal ? () => setState(() => _reveal = false) : null,
              child: AbsorbPointer(absorbing: _reveal, child: pill),
            ),
          ),
          if (waiting > 0 && !_reveal)
            Positioned(
              left: -4,
              top: -4,
              child: _badge(waiting),
            ),
        ]),
      );
    });
  }

  /// Waiting requests: a count; tap to answer them.
  Widget _badge(int waiting) {
    final t = NoorTheme.of(context);
    return GestureDetector(
      onTap: () => showRoomRequests(context),
      child: Container(
        key: const ValueKey('room-waiting'),
        constraints: const BoxConstraints(minWidth: 22),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: t.ac,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: t.bg, width: 2),
        ),
        child: Text('$waiting',
            style: TextStyle(
                color: t.onAc, fontSize: 11, fontWeight: FontWeight.w800)),
      ),
    );
  }

  /// Everyone in the room as circles (the star first); tap one for the
  /// full name.
  Widget _everyone(RoomSnapshot room, RoomState s, String me) {
    final t = NoorTheme.of(context);
    // The star is already on the pill's right: everyone else here.
    final all = room.members.where((m) => m.uid != room.starUid).toList();
    return ListView.separated(
      key: const ValueKey('room-everyone'),
      scrollDirection: Axis.horizontal,
      itemCount: all.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final m = all[i];
        final open = _named == m.uid;
        final name = m.uid == me ? 'You' : m.name;
        return Center(
          child: GestureDetector(
            onTap: () => setState(() => _named = open ? null : m.uid),
            onLongPress: s.isStar && m.uid != me
                ? () => showMemberActions(context, ref, m)
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: 40,
              padding: EdgeInsets.fromLTRB(2, 2, open ? 12 : 2, 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: m.uid == room.starUid ? t.ac : t.faint, width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Opacity(
                    opacity: s.away.contains(m.uid) ? 0.4 : 1,
                    child: RoomAvatar(member: m, size: 34)),
                if (open) ...[
                  const SizedBox(width: 8),
                  Text(
                      '$name${m.uid == room.starUid ? ' ★' : ''}'
                      '${s.away.contains(m.uid) ? ' · away' : ''}',
                      style: TextStyle(
                          color: t.ac,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Up to five faces overlapping, then "+N".
class _Faces extends StatelessWidget {
  const _Faces({required this.members, required this.away, required this.me});
  final List<RoomMember> members;
  final Set<String> away;
  final String me;

  static const size = 30.0, step = 20.0;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final shown = members.take(5).toList();
    final more = members.length - shown.length;
    final count = shown.length + (more > 0 ? 1 : 0);
    return SizedBox(
      width: size + step * (count - 1),
      height: size,
      child: Stack(children: [
        for (var i = 0; i < shown.length; i++)
          Positioned(
            left: step * i,
            child: Opacity(
              opacity: away.contains(shown[i].uid) ? 0.4 : 1,
              child: RoomAvatar(member: shown[i], size: size, ring: t.bg),
            ),
          ),
        if (more > 0)
          Positioned(
            left: step * shown.length,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.tint(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: t.bg, width: 1.5),
              ),
              child: Text('+$more',
                  style: TextStyle(
                      color: t.ac, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }
}

/// A member's initial on a muted colour of their own.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar(
      {super.key,
      required this.member,
      this.size = 32,
      this.ring,
      this.star = false});
  final RoomMember member;
  final double size;
  final Color? ring;
  final bool star;

  static const _colors = [
    Color(0xFF8E4A27),
    Color(0xFF5C7A6A),
    Color(0xFFB8794F),
    Color(0xFF4E5A86),
    Color(0xFF7B4A6E),
    Color(0xFF3E6A8A),
  ];

  static Color colorFor(String uid) =>
      _colors[uid.codeUnits.fold<int>(0, (a, c) => a + c) % _colors.length];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorFor(member.uid),
        shape: BoxShape.circle,
        border: star
            ? Border.all(color: RoomCapsule.gold, width: 2)
            : ring == null
                ? null
                : Border.all(color: ring!, width: 1.5),
      ),
      child: Text(member.initial,
          style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.42,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
        child: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
                color: RoomCapsule.gold, shape: BoxShape.circle)),
      );
}
