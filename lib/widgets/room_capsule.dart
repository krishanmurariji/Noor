import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/room_provider.dart';
import '../services/rooms/room.dart';
import '../theme/noor_search_button.dart';
import 'room_sheet.dart';

/// The room's place on the player: a small dark capsule in the header.
/// Out of a room it is a dot with two listeners (tap: listen together); in
/// a room it shows who is in it, and a gold count when people are waiting.
class RoomCapsule extends ConsumerWidget {
  const RoomCapsule({super.key});

  static const island = Color(0xFF1F1914);
  static const ink = Color(0xFFF6EFE8);
  static const gold = Color(0xFFD8B06A);
  static const live = Color(0xFFE25A52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(roomProvider);
    final room = s.room;
    Widget body;
    String label;
    if (s.inRoom && room != null) {
      final count = room.members.length;
      label = s.isStar
          ? '$count in the room${room.waiting > 0 ? ', ${room.waiting} waiting' : ''}'
          : 'Listening with ${room.starName}';
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        if (s.isStar)
          _Faces(room.members.take(3).toList())
        else
          Container(
              width: 8,
              height: 8,
              decoration:
                  const BoxDecoration(color: live, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(s.isStar ? '$count in the room' : 'With ${room.starName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: ink, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
        if (s.isStar && room.waiting > 0) ...[
          const SizedBox(width: 8),
          Container(
            key: const ValueKey('room-waiting'),
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: gold, borderRadius: BorderRadius.circular(10)),
            child: Text('${room.waiting}',
                style: const TextStyle(
                    color: island, fontSize: 11, fontWeight: FontWeight.w800)),
          ),
        ],
      ]);
    } else if (s.role == RoomRole.knocking) {
      label = 'Asking to join ${s.knockingName ?? ''}';
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        const _Pulse(),
        const SizedBox(width: 8),
        Flexible(
          child: Text('Asking · ${s.knockingName ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: ink, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ]);
    } else {
      label = 'Listen together';
      body = const Icon(Icons.people_alt_outlined, color: gold, size: 20);
    }
    final small = !s.inRoom && s.role != RoomRole.knocking;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('room-capsule'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          showRoomSheet(context);
        },
        // Grows and shrinks with what it says (clipped to its round ends).
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kNoorHeaderSize / 2),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: Container(
              height: kNoorHeaderSize,
              constraints: BoxConstraints(
                  minWidth: kNoorHeaderSize,
                  maxWidth: small ? kNoorHeaderSize : 210),
              padding: EdgeInsets.symmetric(horizontal: small ? 0 : 12),
              alignment: Alignment.center,
              color: island,
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _Faces extends StatelessWidget {
  const _Faces(this.members);
  final List<RoomMember> members;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20.0 + 13 * (members.length - 1).clamp(0, 2),
      height: 22,
      child: Stack(children: [
        for (var i = 0; i < members.length; i++)
          Positioned(
            left: 13.0 * i,
            child: RoomAvatar(
                member: members[i], size: 22, ring: RoomCapsule.island),
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
