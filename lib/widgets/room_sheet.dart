import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/room_provider.dart';
import '../services/rooms/room.dart';
import '../theme/noor_artwork.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';
import 'noor_toast.dart';
import 'room_capsule.dart';

/// The room panel over the player: start or join, the room itself, and
/// (for the star) the requests.
/// The room panel drops down from the top, under the pill it came from;
/// swipe it up or tap outside to close.
Future<void> showRoomSheet(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the room',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (context, _, __) => const _TopPanel(),
    transitionBuilder: (context, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(
              parent: anim,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  );
}

class _TopPanel extends StatelessWidget {
  const _TopPanel();

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final mq = MediaQuery.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -250) Navigator.of(context).maybePop();
        },
        child: Material(
          color: t.bg,
          shape: RoundedRectangleBorder(
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(28)),
              side: BorderSide(color: t.ac, width: 0.8)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.9,
                maxWidth: 600),
            child: Padding(
              padding: EdgeInsets.only(top: mq.padding.top + 4),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Flexible(child: RoomPanel()),
                // The handle at the bottom: swipe up to close.
                const _Grip(),
              ]),
            ),
          ),
        ),
      ),
    );
  }
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
  const RoomPanel({super.key});

  @override
  ConsumerState<RoomPanel> createState() => _RoomPanelState();
}

class _RoomPanelState extends ConsumerState<RoomPanel> {
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(roomProvider);
    final Widget body;
    if (s.inRoom && s.room != null) {
      body = _InRoom(room: s.room!, star: s.isStar);
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
      super.key});
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool danger;
  final IconData? icon;
  static const height = 48.0;

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
      maxLength: kRoomNameMax,
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
            const SizedBox(height: 8),
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
        const SizedBox(height: 8),
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

/// A round icon-only button (its name is read out and shows on a long
/// press), with an optional count on its corner.
class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.danger = false,
    this.size = 46,
  });
  final double size;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    const red = Color(0xFFB23A2E);
    final fg = danger
        ? red
        : filled
            ? t.onAc
            : t.ac;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1,
            child: Stack(clipBehavior: Clip.none, children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: filled && !danger ? t.ac : null,
                  shape: BoxShape.circle,
                  border: filled && !danger
                      ? null
                      : Border.all(
                          color: danger ? red.withValues(alpha: 0.6) : t.soft,
                          width: 0.8),
                ),
                child: Icon(icon, size: size * 0.44, color: fg),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Songs in the app's own song-card design.
class _Songs extends StatelessWidget {
  const _Songs({
    required this.label,
    required this.songs,
    this.current,
    this.playing = false,
    this.onTap,
    this.onPlayPause,
    this.empty,
  });
  final String label;
  final List<Song> songs;

  /// The one playing now (shown as the current card).
  final Song? current;
  final bool playing;
  final void Function(Song)? onTap;
  final VoidCallback? onPlayPause;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Label(label),
      const SizedBox(height: 8),
      if (songs.isEmpty && empty != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(empty!, style: TextStyle(color: t.mute, fontSize: 12.5)),
        ),
      for (final s in songs)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: NoorSongCard(
            thumbnailUrl: s.thumbnailUrl,
            title: s.title,
            artist: s.artist,
            current: s == current,
            playing: s == current && playing,
            onTap: () => onTap?.call(s),
            onPlayPause: s == current ? onPlayPause : () => onTap?.call(s),
          ),
        ),
    ]);
  }
}

/// The room: its name in a round pill at the top (the star renames it;
/// everyone can leave), swiped right for Sync and Share; then what plays.
class _InRoom extends ConsumerWidget {
  const _InRoom({required this.room, required this.star});
  final RoomSnapshot room;
  final bool star;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final ps = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final Song? now;
    final List<Song> upNext;
    if (star) {
      now = ps.displaySong;
      upNext = ps.queueIndex + 1 < ps.queue.length
          ? ps.queue.sublist(ps.queueIndex + 1).take(12).toList()
          : const <Song>[];
    } else {
      now = room.play?.song;
      upNext = room.queue.take(12).toList();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NamePill(room: room, star: star),
            if (star && (now?.isLocal ?? false)) ...[
              const SizedBox(height: 10),
              Text("This song is on your phone, so the others can't hear it.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.mute, fontSize: 12)),
            ],
            if (!star && (room.play?.fromPhone ?? false)) ...[
              const SizedBox(height: 10),
              Text(
                  '${room.starName} is playing a song from their phone, '
                  'which only they can hear.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.mute, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            if (now != null)
              _Songs(
                label: star
                    ? 'NOW PLAYING'
                    : '${room.starName.toUpperCase()} IS PLAYING',
                songs: [now],
                current: now,
                playing: ps.status == NebulaPlayerStatus.playing,
                onPlayPause: player.togglePlay,
                onTap: (_) => player.togglePlay(),
              ),
            const SizedBox(height: 6),
            _Songs(
              label: 'UP NEXT',
              songs: upNext,
              empty: 'Nothing queued after this song.',
              // The star plays any of them now.
              onTap: star ? (s) => player.playSong(s, queue: ps.queue) : null,
            ),
          ]),
    );
  }
}

/// The room's name in a round bordered pill: edit (the star) and leave on
/// the right. Editing turns them into save and cancel. Swiped right, it
/// shows Sync and Share (and, for a listener, asking to be the star).
class _NamePill extends ConsumerStatefulWidget {
  const _NamePill({required this.room, required this.star});
  final RoomSnapshot room;
  final bool star;
  @override
  ConsumerState<_NamePill> createState() => _NamePillState();
}

class _NamePillState extends ConsumerState<_NamePill> {
  TextEditingController? _edit;
  bool _actions = false;

  @override
  void dispose() {
    _edit?.dispose();
    super.dispose();
  }

  /// This phone's own name in the room (the star's is also the room's).
  String _myName() {
    final saved = ref.read(roomNameProvider);
    if (saved.isNotEmpty) return cleanRoomName(saved);
    final uid = ref.read(roomProvider.notifier).uid;
    for (final m in widget.room.members) {
      if (m.uid == uid && m.name.isNotEmpty) return cleanRoomName(m.name);
    }
    return uid.isEmpty ? '' : guestName(uid);
  }

  void _save() {
    final c = _edit;
    if (c == null) return;
    final name = cleanRoomName(c.text);
    if (name.isNotEmpty && name != _myName()) {
      ref.read(roomProvider.notifier).rename(name);
    }
    setState(() => _edit = null);
    c.dispose();
  }

  void _cancel() {
    final c = _edit;
    setState(() => _edit = null);
    c?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final room = widget.room;
    final n = ref.read(roomProvider.notifier);
    ref.watch(roomNameProvider);
    final me = _myName();
    Widget round(IconData icon, String label, VoidCallback? onTap,
            {Key? key, bool danger = false, bool filled = false}) =>
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: SizedBox(
            width: 40,
            height: 40,
            child: _IconAction(
                key: key,
                icon: icon,
                label: label,
                onTap: onTap,
                danger: danger,
                filled: filled,
                size: 40),
          ),
        );

    final Widget row;
    if (_edit != null) {
      row = Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('room-rename'),
            controller: _edit,
            autofocus: true,
            maxLength: kRoomNameMax,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _save(),
            style: noorSongTitleStyle(t.ac, size: 22),
            decoration: const InputDecoration(
                isDense: true, counterText: '', border: InputBorder.none),
          ),
        ),
        round(Icons.check_rounded, 'Save the name', _save,
            key: const ValueKey('room-rename-save'), filled: true),
        round(Icons.close_rounded, 'Cancel', _cancel,
            key: const ValueKey('room-rename-cancel')),
      ]);
    } else if (_actions) {
      final asked = n.askedToBeStar;
      row = Row(children: [
        Expanded(
          child: Text('Code ${room.code}',
              style: TextStyle(
                  color: t.mute,
                  fontSize: 12.5,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700)),
        ),
        round(Icons.sync_rounded, widget.star ? 'Sync everyone' : 'Sync now',
            () {
          if (widget.star) {
            n.syncEveryone();
          } else {
            n.syncNow();
            NoorToast.show(context, 'Back in step with ${room.starName}');
          }
        },
            key: ValueKey(widget.star ? 'room-sync-all' : 'room-sync'),
            filled: true),
        round(Icons.share_rounded, 'Share the room',
            () => shareRoomInvite(context, room),
            key: const ValueKey('room-share')),
        if (!widget.star)
          round(
              asked ? Icons.star_rounded : Icons.star_outline_rounded,
              asked ? 'Asked to be the star' : 'Ask to be the star',
              asked ? null : n.askToBeStar,
              key: const ValueKey('room-ask-star')),
      ]);
    } else {
      final alone = room.members.length <= 1;
      row = Row(children: [
        Expanded(
          child: Text(me,
              key: const ValueKey('room-my-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: noorSongTitleStyle(t.ac, size: 24)),
        ),
        round(
            Icons.edit_outlined,
            'Change your name',
            () => setState(() => _edit = TextEditingController(text: me)),
            key: const ValueKey('room-rename-edit')),
        // Alone in this phone's own room: leaving gives a fresh code.
        round(
            widget.star && alone
                ? Icons.autorenew_rounded
                : Icons.logout_rounded,
            widget.star && alone ? 'Get a new room code' : 'Leave the room',
            () {
          Navigator.of(context).maybePop();
          n.leave();
        }, key: const ValueKey('room-leave'), danger: true),
      ]);
    }
    return GestureDetector(
      key: const ValueKey('room-name-pill'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _edit != null
          ? null
          : (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 150 && !_actions) setState(() => _actions = true);
              if (v < -150 && _actions) setState(() => _actions = false);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 54,
        padding: const EdgeInsets.fromLTRB(18, 0, 7, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(27),
          border: Border.all(color: t.ac, width: 1),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                  position: Tween(
                          begin: Offset(_actions ? -0.15 : 0.15, 0),
                          end: Offset.zero)
                      .animate(a),
                  child: child)),
          child: KeyedSubtree(
              key: ValueKey('${_edit != null}-$_actions'), child: row),
        ),
      ),
    );
  }
}

/// Make the star, remove or block someone (the star, from a circle on the
/// player's room pill).
void showMemberActions(BuildContext context, WidgetRef ref, RoomMember m) {
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

// ── Requests: a pop-up in the middle of the screen ─────────────────────────

/// The star's waiting requests (someone wants in, a song, the star) in a
/// pop-up in the middle of the screen, to approve or turn down there and
/// then. Closes by itself once nothing is left.
Future<void> showRoomRequests(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the requests',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, _, __) => const _RequestsDialog(),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
          child: child),
    ),
  );
}

class _RequestsDialog extends ConsumerWidget {
  const _RequestsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final s = ref.watch(roomProvider);
    final room = s.room;
    final n = ref.read(roomProvider.notifier);
    final empty =
        room == null || !s.isStar || (room.knocks.isEmpty && room.asks.isEmpty);
    if (empty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }

    Widget item({
      required Widget lead,
      required String title,
      required String sub,
      required List<Widget> actions,
      bool script = false,
    }) =>
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: t.ac, width: 1)),
          child: Row(children: [
            lead,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: script
                            ? noorSongTitleStyle(t.ac, size: 18)
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
    Widget act(IconData icon, String label, VoidCallback onTap,
            {bool filled = false, bool danger = false}) =>
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: _IconAction(
              icon: icon,
              label: label,
              onTap: onTap,
              filled: filled,
              danger: danger,
              size: 38),
        );

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Material(
          color: t.bg,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(color: t.ac, width: 1)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 520,
                maxHeight: MediaQuery.sizeOf(context).height * 0.7),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Requests',
                        textAlign: TextAlign.center,
                        style: noorSongTitleStyle(t.ac, size: 28)),
                    const SizedBox(height: 14),
                    for (final k in room.knocks)
                      item(
                        lead: RoomAvatar(
                            member: RoomMember(k.uid, k.name, k.at, k.at),
                            size: 40),
                        title: k.name,
                        sub: 'wants to join',
                        actions: [
                          act(Icons.block_rounded, 'Block this phone',
                              () => n.block(k.uid, k.name),
                              danger: true),
                          act(Icons.close_rounded, 'Not now',
                              () => n.notNow(k)),
                          act(Icons.check_rounded, 'Let in', () => n.letIn(k),
                              filled: true),
                        ],
                      ),
                    for (final a in room.asks.where((a) => a.isSong))
                      item(
                        script: true,
                        lead: ClipOval(
                            child: SizedBox(
                                width: 40,
                                height: 40,
                                child: NoorArtwork(url: a.song!.thumbnailUrl))),
                        title: a.song!.title,
                        sub: '${a.name} would like this',
                        actions: [
                          act(Icons.close_rounded, 'Decline',
                              () => n.decline(a)),
                          act(Icons.playlist_add_rounded, 'Add to the end',
                              () => n.acceptSong(a, next: false)),
                          act(Icons.playlist_play_rounded, 'Play next',
                              () => n.acceptSong(a, next: true),
                              filled: true),
                        ],
                      ),
                    for (final a in room.asks.where((a) => !a.isSong))
                      item(
                        lead: RoomAvatar(
                            member: RoomMember(a.uid, a.name, a.at, a.at),
                            size: 40),
                        title: '${a.name} asks to be the star',
                        sub: "You'd become a listener",
                        actions: [
                          act(Icons.close_rounded, 'Decline',
                              () => n.decline(a)),
                          act(Icons.star_rounded, 'Hand over', () {
                            final m = room.members.where((m) => m.uid == a.uid);
                            if (m.isNotEmpty) n.handOver(m.first);
                            n.decline(a);
                          }, filled: true),
                        ],
                      ),
                    TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: Text('Later',
                            style: TextStyle(color: t.mute, fontSize: 13))),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
