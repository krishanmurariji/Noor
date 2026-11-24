import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/room_provider.dart';
import '../screens/search_screen.dart';
import '../services/rooms/room.dart';
import '../theme/noor_artwork.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';
import 'noor_toast.dart';
import 'room_capsule.dart';

/// The room panel over the player: start or join, the room itself, and
/// (for the star) the requests.
Future<void> showRoomSheet(BuildContext context, {bool requests = false}) {
  final t = NoorTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.bg,
    isScrollControlled: true,
    constraints:
        BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
    shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: t.ac, width: 0.8)),
    builder: (_) => SafeArea(child: RoomPanel(startOnRequests: requests)),
  );
}

const _share = MethodChannel('noor/share');

/// Sends the invite through the phone's share sheet (or copies it).
Future<void> shareRoomInvite(BuildContext context, RoomSnapshot room) async {
  final text = 'Listen with me on Noor · room ${room.code}\n'
      'Open Noor, tap the room button on the player and enter ${room.code}.';
  var shared = false;
  try {
    shared = await _share.invokeMethod<bool>(
            'text', {'text': text, 'title': 'Invite to ${room.name}'}) ??
        false;
  } catch (_) {}
  if (!shared) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) NoorToast.show(context, 'Invite copied');
  }
}

class RoomPanel extends ConsumerStatefulWidget {
  const RoomPanel({super.key, this.startOnRequests = false});
  final bool startOnRequests;

  @override
  ConsumerState<RoomPanel> createState() => _RoomPanelState();
}

class _RoomPanelState extends ConsumerState<RoomPanel> {
  late bool _requests = widget.startOnRequests;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomProvider);
    final Widget body;
    if (s.isStar && s.room != null && _requests) {
      body = _Requests(
          room: s.room!, onBack: () => setState(() => _requests = false));
    } else if (s.isStar && s.room != null) {
      body = _StarView(
          room: s.room!, onRequests: () => setState(() => _requests = true));
    } else if (s.isListener && s.room != null) {
      body = _ListenerView(room: s.room!);
    } else if (s.role == RoomRole.knocking) {
      body = _Knocking(name: s.knockingName ?? '');
    } else if (s.inRoom) {
      body = const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    } else {
      body = const _StartOrJoin();
    }
    return SingleChildScrollView(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: body,
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _Grip extends StatelessWidget {
  const _Grip();
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 10),
          decoration: BoxDecoration(
              color: NoorTheme.of(context).soft,
              borderRadius: BorderRadius.circular(2)),
        ),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.sub});
  final String text;
  final String? sub;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Column(children: [
      Text(text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: noorSongTitleStyle(t.ac, size: 28)),
      if (sub != null) ...[
        const SizedBox(height: 4),
        Text(sub!,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.mute, fontSize: 12.5, height: 1.35)),
      ],
    ]);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Row(children: [
      Text(text,
          style: TextStyle(
              color: t.mute,
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w700)),
      const SizedBox(width: 10),
      Expanded(child: Container(height: 1, color: t.wash)),
    ]);
  }
}

class _Button extends StatelessWidget {
  const _Button(this.label,
      {required this.onTap,
      this.filled = true,
      this.icon,
      this.danger = false,
      this.height = 48,
      super.key});
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool danger;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final fg = danger
        ? const Color(0xFFB23A2E)
        : filled
            ? t.onAc
            : t.ac;
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: filled && !danger ? t.ac : Colors.transparent,
        shape: StadiumBorder(
            side: filled && !danger
                ? BorderSide.none
                : BorderSide(
                    color: danger ? fg.withValues(alpha: 0.6) : t.soft,
                    width: 0.8)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: SizedBox(
            height: height,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: fg,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton(
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
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: filled ? t.ac : null,
            shape: BoxShape.circle,
            border: filled ? null : Border.all(color: t.soft, width: 0.8),
          ),
          child: Icon(icon, size: 18, color: filled ? t.onAc : t.ac),
        ),
      ),
    );
  }
}

/// Asks for this phone's name once (rooms show it to the others).
class _NameField extends ConsumerStatefulWidget {
  const _NameField();
  @override
  ConsumerState<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends ConsumerState<_NameField> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return TextField(
      key: const ValueKey('room-name'),
      controller: _c,
      textCapitalization: TextCapitalization.words,
      maxLength: 24,
      onChanged: (_) => setState(() {}),
      onSubmitted: (v) => ref.read(roomNameProvider.notifier).set(v),
      onTapOutside: (_) {
        if (_c.text.trim().isNotEmpty) {
          ref.read(roomNameProvider.notifier).set(_c.text);
        }
      },
      style: TextStyle(color: t.ac, fontSize: 16, fontWeight: FontWeight.w600),
      decoration: _field(t, 'Your name, as friends see it'),
    );
  }
}

InputDecoration _field(NoorTheme t, String hint) => InputDecoration(
      hintText: hint,
      counterText: '',
      hintStyle: TextStyle(color: t.mute, fontWeight: FontWeight.w400),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: t.soft)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: t.ac, width: 1.2)),
    );

// ── Start or join ─────────────────────────────────────────────────────────

class _StartOrJoin extends ConsumerStatefulWidget {
  const _StartOrJoin();
  @override
  ConsumerState<_StartOrJoin> createState() => _StartOrJoinState();
}

class _StartOrJoinState extends ConsumerState<_StartOrJoin> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? get _name {
    final n = ref.read(roomNameProvider);
    return n.isEmpty ? null : n;
  }

  Future<void> _run(Future<String?> Function() f) async {
    if (_name == null) {
      setState(() => _error = 'Add your name first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final why = await f();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = why;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final n = ref.watch(roomProvider.notifier);
    final name = ref.watch(roomNameProvider);
    final song = ref.watch(playerProvider.select((s) => s.displaySong));
    final code = cleanRoomCode(_code.text);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            _Heading('Listen together',
                sub: n.available
                    ? 'You play, every phone in the room plays the same song.'
                    : 'Rooms are not set up in this build of Noor yet.'),
            const SizedBox(height: 16),
            if (name.isEmpty) ...[
              const _NameField(),
              const SizedBox(height: 12),
            ],
            _Button(
              song == null ? 'Start a room' : "Share what I'm playing",
              key: const ValueKey('room-start'),
              icon: Icons.star_rounded,
              onTap: !n.available || _busy ? null : () => _run(n.start),
            ),
            if (song != null) ...[
              const SizedBox(height: 6),
              Text('${song.title} keeps playing. Friends join in sync.',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.mute, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Container(height: 1, color: t.wash)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('OR JOIN',
                    style: TextStyle(
                        color: t.mute,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700)),
              ),
              Expanded(child: Container(height: 1, color: t.wash)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('room-code'),
                  controller: _code,
                  maxLength: 7,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  onChanged: (_) => setState(() => _error = null),
                  style: TextStyle(
                      color: t.ac,
                      fontSize: 18,
                      letterSpacing: 5,
                      fontWeight: FontWeight.w700),
                  decoration: _field(t, 'Room code').copyWith(
                      hintStyle: TextStyle(
                          color: t.mute,
                          fontSize: 15,
                          letterSpacing: 0,
                          fontWeight: FontWeight.w400)),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: _Button('Ask',
                    key: const ValueKey('room-join'),
                    onTap: !n.available || _busy || code == null
                        ? null
                        : () => _run(() => n.knock(code))),
              ),
            ]),
            const SizedBox(height: 8),
            Text(_error ?? 'The star lets you in. You always ask to join.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _error != null ? const Color(0xFFB23A2E) : t.mute,
                    fontSize: 12)),
          ]),
    );
  }
}

class _Knocking extends ConsumerWidget {
  const _Knocking({required this.name});
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const _Grip(),
        _Heading('Asking to join',
            sub: '$name · the star will let you in (or not).'),
        const SizedBox(height: 20),
        const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(height: 20),
        _Button('Cancel',
            filled: false,
            onTap: () => ref.read(roomProvider.notifier).cancelKnock()),
      ]),
    );
  }
}

// ── In the room ───────────────────────────────────────────────────────────

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.room});
  final RoomSnapshot room;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: noorSongTitleStyle(t.ac, size: 24)),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: room.code));
              NoorToast.show(context, 'Room code copied');
            },
            child: Text(room.code,
                semanticsLabel: 'Room code ${room.code.split('').join(' ')}',
                style: TextStyle(
                    color: t.mute,
                    fontSize: 12,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      SizedBox(
        width: 96,
        child: _Button('Invite',
            height: 38, onTap: () => shareRoomInvite(context, room)),
      ),
    ]);
  }
}

class _Members extends ConsumerWidget {
  const _Members({required this.room, required this.manage});
  final RoomSnapshot room;
  final bool manage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final me = ref.read(roomProvider.notifier).uid;
    return SizedBox(
      height: 36,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final m in room.members)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap:
                  manage && m.uid != me ? () => _manage(context, ref, m) : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color:
                          m.uid == room.starUid ? RoomCapsule.gold : t.faint),
                ),
                child: Row(children: [
                  RoomAvatar(member: m, size: 26),
                  const SizedBox(width: 6),
                  Text(m.uid == me ? 'You' : m.name,
                      style: TextStyle(
                          color: t.ac,
                          fontSize: 12.5,
                          fontWeight: m.uid == room.starUid
                              ? FontWeight.w700
                              : FontWeight.w500)),
                  if (m.uid == room.starUid) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.star_rounded,
                        size: 14,
                        color: RoomCapsule.gold,
                        semanticLabel: 'star'),
                  ],
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  void _manage(BuildContext context, WidgetRef ref, RoomMember m) {
    final t = NoorTheme.of(context);
    final n = ref.read(roomProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.bg,
      shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: t.ac, width: 0.8)),
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Grip(),
                _Heading(m.name),
                const SizedBox(height: 16),
                _Button('Make ${m.name} the star', icon: Icons.star_rounded,
                    onTap: () {
                  Navigator.pop(c);
                  n.handOver(m);
                }),
                const SizedBox(height: 10),
                _Button('Remove from the room', filled: false, onTap: () {
                  Navigator.pop(c);
                  n.remove(m.uid);
                }),
                const SizedBox(height: 10),
                _Button('Block', danger: true, filled: false, onTap: () {
                  Navigator.pop(c);
                  n.block(m.uid, m.name);
                }),
              ]),
        ),
      ),
    );
  }
}

class _SongLine extends StatelessWidget {
  const _SongLine(this.song);
  final Song song;
  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        ClipOval(
          child: SizedBox(
              width: 40,
              height: 40,
              child: NoorArtwork(url: song.thumbnailUrl)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: noorSongTitleStyle(t.ac, size: 18)),
            Text(song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: noorArtistStyle(t.mute, size: 11.5)),
          ]),
        ),
      ]),
    );
  }
}

class _StarView extends ConsumerWidget {
  const _StarView({required this.room, required this.onRequests});
  final RoomSnapshot room;
  final VoidCallback onRequests;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final ps = ref.watch(playerProvider);
    final upNext = ps.queueIndex + 1 < ps.queue.length
        ? ps.queue.sublist(ps.queueIndex + 1).take(8).toList()
        : const <Song>[];
    final alone = room.members.length <= 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            _RoomHeader(room: room),
            const SizedBox(height: 14),
            _Members(room: room, manage: true),
            if (ps.displaySong?.isLocal ?? false) ...[
              const SizedBox(height: 10),
              Text("This song is on your phone, so the others can't hear it.",
                  style: TextStyle(color: t.mute, fontSize: 12)),
            ],
            if (room.waiting > 0) ...[
              const SizedBox(height: 14),
              Material(
                color: t.ac,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  key: const ValueKey('room-requests'),
                  borderRadius: BorderRadius.circular(18),
                  onTap: onRequests,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration:
                            BoxDecoration(color: t.bg, shape: BoxShape.circle),
                        child: Text('${room.waiting}',
                            style: TextStyle(
                                color: t.ac,
                                fontWeight: FontWeight.w800,
                                fontSize: 13)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_waitingText(room),
                            style: TextStyle(
                                color: t.onAc,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600)),
                      ),
                      Icon(Icons.chevron_right_rounded, color: t.onAc),
                    ]),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const _Label('UP NEXT'),
            const SizedBox(height: 6),
            if (upNext.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Nothing queued after this song.',
                    style: TextStyle(color: t.mute, fontSize: 12.5)),
              )
            else
              for (final s in upNext) _SongLine(s),
            const SizedBox(height: 14),
            _Button(alone ? 'End the room' : 'Leave the room',
                key: const ValueKey('room-leave'),
                filled: false,
                danger: true,
                height: 44, onTap: () {
              Navigator.of(context).maybePop();
              ref.read(roomProvider.notifier).leave();
            }),
            if (!alone)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    '${room.members.firstWhere((m) => m.uid != room.starUid, orElse: () => room.members.first).name} becomes the star when you leave.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.mute, fontSize: 11.5)),
              ),
          ]),
    );
  }

  static String _waitingText(RoomSnapshot r) {
    final songs = r.asks.where((a) => a.isSong).length;
    final people = r.knocks.length;
    final star = r.asks.length - songs;
    final parts = [
      if (songs > 0) '$songs song${songs == 1 ? '' : 's'}',
      if (people > 0) '$people to let in',
      if (star > 0) '$star star request${star == 1 ? '' : 's'}',
    ];
    return '${parts.join(' · ')} waiting';
  }
}

class _ListenerView extends ConsumerWidget {
  const _ListenerView({required this.room});
  final RoomSnapshot room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final n = ref.read(roomProvider.notifier);
    ref.watch(roomProvider);
    final play = room.play;
    final asked = n.askedToBeStar;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            _RoomHeader(room: room),
            const SizedBox(height: 14),
            _Members(room: room, manage: false),
            const SizedBox(height: 14),
            Row(children: [
              const Icon(Icons.star_rounded, size: 14, color: RoomCapsule.gold),
              const SizedBox(width: 6),
              Text('${room.starName.toUpperCase()} IS PLAYING',
                  style: TextStyle(
                      color: t.mute,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            if (play?.fromPhone ?? false)
              Text('A song from their phone, which only they can hear.',
                  style: TextStyle(color: t.mute, fontSize: 12.5))
            else if (play?.song != null)
              _SongLine(play!.song!)
            else
              Text('Nothing yet.',
                  style: TextStyle(color: t.mute, fontSize: 12.5)),
            if (room.queue.isNotEmpty) ...[
              const SizedBox(height: 12),
              const _Label('UP NEXT'),
              const SizedBox(height: 4),
              for (final s in room.queue.take(6)) _SongLine(s),
            ],
            const SizedBox(height: 16),
            _Button('Request a song',
                key: const ValueKey('room-request-song'),
                icon: Icons.music_note_rounded, onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SearchPage()));
              NoorToast.show(
                  context, 'Tap a song to ask ${room.starName} to play it');
            }),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _Button(asked ? 'Asked to be star' : 'Ask to be star',
                    key: const ValueKey('room-ask-star'),
                    filled: false,
                    height: 44,
                    icon: Icons.star_outline_rounded,
                    onTap: asked ? null : n.askToBeStar),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Button('Leave',
                    key: const ValueKey('room-leave'),
                    filled: false,
                    danger: true,
                    height: 44, onTap: () {
                  Navigator.of(context).maybePop();
                  n.leave();
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Text('${room.starName} picks the songs. Play and pause are yours.',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.mute, fontSize: 11.5)),
          ]),
    );
  }
}

// ── The star's requests ───────────────────────────────────────────────────

class _Requests extends ConsumerStatefulWidget {
  const _Requests({required this.room, required this.onBack});
  final RoomSnapshot room;
  final VoidCallback onBack;
  @override
  ConsumerState<_Requests> createState() => _RequestsState();
}

class _RequestsState extends ConsumerState<_Requests> {
  int? _tab;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final r = widget.room;
    final n = ref.read(roomProvider.notifier);
    final songs = r.asks.where((a) => a.isSong).toList();
    final stars = r.asks.where((a) => !a.isSong).toList();
    final counts = [songs.length, r.knocks.length, stars.length];
    final tab = _tab ?? (counts.indexWhere((c) => c > 0).clamp(0, 2));
    const names = ['Songs', 'Joining', 'Star'];

    Widget card(
            {required Widget lead,
            required String title,
            required String sub,
            required List<Widget> actions,
            bool script = false}) =>
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: t.faint)),
          child: Row(children: [
            lead,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: script
                            ? noorSongTitleStyle(t.ac, size: 19)
                            : TextStyle(
                                color: t.ac,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.mute, fontSize: 11.5)),
                  ]),
            ),
            ...actions,
          ]),
        );

    final List<Widget> items;
    if (tab == 0) {
      items = [
        for (final a in songs)
          Column(children: [
            card(
              script: true,
              lead: ClipOval(
                  child: SizedBox(
                      width: 44,
                      height: 44,
                      child: NoorArtwork(url: a.song!.thumbnailUrl))),
              title: a.song!.title,
              sub: '${a.name} would like this',
              actions: [
                _RoundButton(
                    icon: Icons.close_rounded,
                    label: 'Decline',
                    onTap: () => n.decline(a)),
                const SizedBox(width: 8),
                _RoundButton(
                    icon: Icons.playlist_add_rounded,
                    label: 'Add to the end',
                    onTap: () => n.acceptSong(a, next: false)),
                const SizedBox(width: 8),
                _RoundButton(
                    icon: Icons.playlist_play_rounded,
                    label: 'Play next',
                    filled: true,
                    onTap: () => n.acceptSong(a, next: true)),
              ],
            ),
          ]),
      ];
    } else if (tab == 1) {
      items = [
        for (final k in r.knocks)
          Column(children: [
            card(
              lead: RoomAvatar(
                  member: RoomMember(k.uid, k.name, k.at, k.at), size: 40),
              title: k.name,
              sub: 'wants to join',
              actions: [
                _RoundButton(
                    icon: Icons.close_rounded,
                    label: 'Not now',
                    onTap: () => n.notNow(k)),
                const SizedBox(width: 8),
                _RoundButton(
                    icon: Icons.check_rounded,
                    label: 'Let in',
                    filled: true,
                    onTap: () => n.letIn(k)),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => n.block(k.uid, k.name),
                child: const Text('Block this phone',
                    style: TextStyle(color: Color(0xFFB23A2E), fontSize: 12.5)),
              ),
            ),
          ]),
      ];
    } else {
      items = [
        for (final a in stars)
          card(
            lead: RoomAvatar(
                member: RoomMember(a.uid, a.name, a.at, a.at), size: 40),
            title: '${a.name} asks to be the star',
            sub: "You'd become a listener",
            actions: [
              _RoundButton(
                  icon: Icons.close_rounded,
                  label: 'Decline',
                  onTap: () => n.decline(a)),
              const SizedBox(width: 8),
              _RoundButton(
                  icon: Icons.star_rounded,
                  label: 'Hand over',
                  filled: true,
                  onTap: () {
                    final m = r.members.where((m) => m.uid == a.uid);
                    if (m.isNotEmpty) n.handOver(m.first);
                    n.decline(a);
                  }),
            ],
          ),
      ];
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            Row(children: [
              IconButton(
                  tooltip: 'Back to the room',
                  onPressed: widget.onBack,
                  icon: Icon(Icons.arrow_back_rounded, color: t.ac)),
              Expanded(
                  child: Text('Requests',
                      textAlign: TextAlign.center,
                      style: noorSongTitleStyle(t.ac, size: 28))),
              const SizedBox(width: 48),
            ]),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text('${names[i]} · ${counts[i]}'),
                    selected: tab == i,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _tab = i),
                    selectedColor: t.ac,
                    backgroundColor: t.bg,
                    labelStyle: TextStyle(
                        color: tab == i ? t.onAc : t.ac,
                        fontWeight: FontWeight.w600,
                        fontSize: 13),
                    shape: StadiumBorder(
                        side: BorderSide(color: t.soft, width: 0.8)),
                  ),
                ),
            ]),
            const SizedBox(height: 14),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('Nothing waiting here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.mute, fontSize: 13)),
              )
            else
              ...items,
          ]),
    );
  }
}
