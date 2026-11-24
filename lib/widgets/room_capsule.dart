import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/room_provider.dart';
import '../services/rooms/room.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';
import 'room_sheet.dart';

/// Room colours that stay the same in light and dark mode.
class RoomCapsule {
  RoomCapsule._();
  static const island = Color(0xFF1F1914);
  static const gold = Color(0xFFD8B06A);
  static const live = Color(0xFFE25A52);
}

/// The room on the player: a full-width pill under the header. The room's
/// name on the left, who is in it on the right (three faces, then "+N"),
/// and a count on its top-left corner when people or songs are waiting.
/// Out of a room it offers to listen together. Tap: the room panel.
class RoomPill extends ConsumerWidget {
  const RoomPill({super.key});

  static const height = 46.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final s = ref.watch(roomProvider);
    final room = s.room;
    final me = ref.read(roomProvider.notifier).uid;
    final List<Widget> row;
    String label;
    var waiting = 0;
    if (s.inRoom && room != null) {
      final here = room.members.where((m) => !s.away.contains(m.uid)).toList();
      waiting = s.isStar ? room.waiting : 0;
      label = 'Room ${room.name}, ${here.length} here'
          '${waiting > 0 ? ', $waiting waiting' : ''}';
      row = [
        Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: RoomCapsule.live, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        // At most five letters: always shown whole.
        Text(cleanRoomName(room.name),
            maxLines: 1, style: noorSongTitleStyle(t.ac, size: 22)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              s.isStar ? "· you're the star" : '· with ${room.starName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.mute, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        _Faces(
          members: [
            ...room.members.where((m) => m.uid == room.starUid),
            ...room.members.where((m) => m.uid != room.starUid),
          ],
          away: s.away,
          me: me,
        ),
      ];
    } else if (s.role == RoomRole.knocking) {
      label = 'Asking to join ${s.knockingName ?? ''}';
      row = [
        const _Pulse(),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Asking to join · ${s.knockingName ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: t.ac, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
      ];
    } else {
      label = 'Listen together';
      row = [
        Icon(Icons.people_alt_outlined, size: 19, color: t.ac),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Listen together',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: noorSongTitleStyle(t.ac, size: 20)),
        ),
        Text('Start or join',
            maxLines: 1, style: TextStyle(color: t.mute, fontSize: 12)),
        Icon(Icons.chevron_right_rounded, size: 20, color: t.mute),
      ];
    }
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('room-pill'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          showRoomSheet(context, requests: waiting > 0);
        },
        child: Stack(clipBehavior: Clip.none, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            height: height,
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            decoration: BoxDecoration(
              color: t.bg,
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(
                  color: s.inRoom ? t.ac : t.soft, width: s.inRoom ? 1 : 0.8),
            ),
            child: Row(children: row),
          ),
          // Waiting requests: a count on the pill's top-left corner.
          if (waiting > 0)
            Positioned(
              left: -4,
              top: -8,
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
                        color: t.onAc,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Up to three faces overlapping (the star first), then "+N".
class _Faces extends StatelessWidget {
  const _Faces({required this.members, required this.away, required this.me});
  final List<RoomMember> members;
  final Set<String> away;
  final String me;

  static const size = 30.0, step = 20.0;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final shown = members.take(3).toList();
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
              child: RoomAvatar(
                  member: shown[i], size: size, ring: t.bg, star: i == 0),
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
