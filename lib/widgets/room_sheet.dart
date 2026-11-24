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
/// The room panel drops down from the top, under the pill it came from;
/// swipe it up or tap outside to close.
Future<void> showRoomSheet(BuildContext context, {bool requests = false}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the room',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (context, _, __) => _TopPanel(requests: requests),
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
  const _TopPanel({required this.requests});
  final bool requests;

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
                Flexible(child: RoomPanel(startOnRequests: requests)),
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

/// The room's name (the star can rename it, up to five letters), its code
/// (tap to copy) and Invite.
class _RoomHeader extends ConsumerStatefulWidget {
  const _RoomHeader({required this.room, this.canRename = false});
  final RoomSnapshot room;
  final bool canRename;
  @override
  ConsumerState<_RoomHeader> createState() => _RoomHeaderState();
}

class _RoomHeaderState extends ConsumerState<_RoomHeader> {
  TextEditingController? _edit;

  @override
  void dispose() {
    _edit?.dispose();
    super.dispose();
  }

  void _save() {
    final c = _edit;
    if (c == null) return;
    final name = cleanRoomName(c.text);
    if (name.isNotEmpty && name != widget.room.name) {
      ref.read(roomProvider.notifier).rename(name);
    }
    setState(() => _edit = null);
    c.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    final room = widget.room;
    final Widget name;
    if (_edit != null) {
      name = Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('room-rename'),
            controller: _edit,
            autofocus: true,
            maxLength: kRoomNameMax,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _save(),
            style: noorSongTitleStyle(t.ac, size: 24),
            decoration: const InputDecoration(
                isDense: true, counterText: '', border: InputBorder.none),
          ),
        ),
        IconButton(
            key: const ValueKey('room-rename-save'),
            tooltip: 'Save the name',
            onPressed: _save,
            icon: Icon(Icons.check_rounded, color: t.ac)),
      ]);
    } else {
      name = Row(children: [
        Flexible(
          child: Text(cleanRoomName(room.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: noorSongTitleStyle(t.ac, size: 24)),
        ),
        if (widget.canRename)
          IconButton(
            key: const ValueKey('room-rename-edit'),
            tooltip: 'Rename the room',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => _edit = TextEditingController(text: room.name)),
            icon: Icon(Icons.edit_outlined, size: 18, color: t.mute),
          ),
      ]);
    }
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          name,
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
    final away = ref.watch(roomProvider.select((s) => s.away));
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
                  Opacity(
                      opacity: away.contains(m.uid) ? 0.4 : 1,
                      child: RoomAvatar(member: m, size: 26)),
                  const SizedBox(width: 6),
                  Text(
                      m.uid == me
                          ? 'You'
                          : away.contains(m.uid)
                              ? '${m.name} · away'
                              : m.name,
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
                const SizedBox(height: 8),
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
    this.count = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool danger;
  final int count;

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
        label: count > 0 ? '$label, $count' : label,
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
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: filled && !danger ? t.ac : null,
                  shape: BoxShape.circle,
                  border: filled && !danger
                      ? null
                      : Border.all(
                          color: danger ? red.withValues(alpha: 0.6) : t.soft,
                          width: 0.8),
                ),
                child: Icon(icon, size: 20, color: fg),
              ),
              if (count > 0)
                Positioned(
                  right: -3,
                  top: -3,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: t.ac,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: t.bg, width: 1.5)),
                    child: Text('$count',
                        style: TextStyle(
                            color: t.onAc,
                            fontSize: 10,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A row of [_IconAction]s spread across the panel.
class _Actions extends StatelessWidget {
  const _Actions(this.children);
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children);
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

class _StarView extends ConsumerWidget {
  const _StarView({required this.room, required this.onRequests});
  final RoomSnapshot room;
  final VoidCallback onRequests;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final ps = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final n = ref.read(roomProvider.notifier);
    final now = ps.displaySong;
    final upNext = ps.queueIndex + 1 < ps.queue.length
        ? ps.queue.sublist(ps.queueIndex + 1).take(12).toList()
        : const <Song>[];
    final alone = room.members.length <= 1;
    final next = room.members
        .where((m) => m.uid != room.starUid)
        .map((m) => m.name)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            _RoomHeader(room: room, canRename: true),
            const SizedBox(height: 12),
            _Members(room: room, manage: true),
            const SizedBox(height: 14),
            _Actions([
              _IconAction(
                  icon: Icons.person_add_alt_1_rounded,
                  label: 'Invite',
                  filled: true,
                  onTap: () => shareRoomInvite(context, room)),
              _IconAction(
                  key: const ValueKey('room-requests'),
                  icon: Icons.inbox_rounded,
                  label: 'Requests',
                  count: room.waiting,
                  onTap: room.waiting > 0 ? onRequests : null),
              _IconAction(
                  key: const ValueKey('room-sync-all'),
                  icon: Icons.sync_rounded,
                  label: 'Sync everyone',
                  onTap: alone ? null : n.syncEveryone),
              _IconAction(
                  key: const ValueKey('room-leave'),
                  icon: Icons.logout_rounded,
                  label: alone
                      ? 'End the room'
                      : 'Leave the room ($next becomes the star)',
                  danger: true,
                  onTap: () {
                    Navigator.of(context).maybePop();
                    n.leave();
                  }),
            ]),
            if (now?.isLocal ?? false) ...[
              const SizedBox(height: 10),
              Text("This song is on your phone, so the others can't hear it.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.mute, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            if (now != null)
              _Songs(
                label: 'NOW PLAYING',
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
              onTap: (s) => player.playSong(s, queue: ps.queue),
            ),
          ]),
    );
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
    final ps = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final play = room.play;
    final asked = n.askedToBeStar;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            _RoomHeader(room: room),
            const SizedBox(height: 12),
            _Members(room: room, manage: false),
            const SizedBox(height: 14),
            _Actions([
              _IconAction(
                  key: const ValueKey('room-sync'),
                  icon: Icons.sync_rounded,
                  label: 'Sync now',
                  filled: true,
                  onTap: () {
                    n.syncNow();
                    NoorToast.show(
                        context, 'Back in step with ${room.starName}');
                  }),
              _IconAction(
                  key: const ValueKey('room-request-song'),
                  icon: Icons.queue_music_rounded,
                  label: 'Request a song',
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SearchPage()));
                    NoorToast.show(context,
                        'Tap a song to ask ${room.starName} to play it');
                  }),
              _IconAction(
                  key: const ValueKey('room-ask-star'),
                  icon: asked ? Icons.star_rounded : Icons.star_outline_rounded,
                  label: asked ? 'Asked to be the star' : 'Ask to be the star',
                  onTap: asked ? null : n.askToBeStar),
              _IconAction(
                  icon: Icons.person_add_alt_1_rounded,
                  label: 'Invite',
                  onTap: () => shareRoomInvite(context, room)),
              _IconAction(
                  key: const ValueKey('room-leave'),
                  icon: Icons.logout_rounded,
                  label: 'Leave the room',
                  danger: true,
                  onTap: () {
                    Navigator.of(context).maybePop();
                    n.leave();
                  }),
            ]),
            const SizedBox(height: 12),
            const _Timing(),
            const SizedBox(height: 14),
            if (play?.fromPhone ?? false)
              Text(
                  '${room.starName} is playing a song from their phone, '
                  'which only they can hear.',
                  style: TextStyle(color: t.mute, fontSize: 12.5))
            else if (play?.song != null)
              _Songs(
                label: '${room.starName.toUpperCase()} IS PLAYING',
                songs: [play!.song!],
                current: play.song,
                playing: ps.status == NebulaPlayerStatus.playing,
                // Play / pause stay this phone's own.
                onPlayPause: player.togglePlay,
                onTap: (_) => player.togglePlay(),
              ),
            if (room.queue.isNotEmpty) ...[
              const SizedBox(height: 6),
              _Songs(label: 'UP NEXT', songs: room.queue.take(12).toList()),
            ],
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
            const SizedBox(height: 8),
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

/// Hear an echo? This phone's timing, tuned by ear in 20 ms steps (phones
/// take different times to get sound out of the speaker): one slim line.
class _Timing extends ConsumerWidget {
  const _Timing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final tune = ref.watch(roomTuneProvider);
    final n = ref.read(roomTuneProvider.notifier);
    Widget step(IconData icon, String label, int ms, Key key) => IconButton(
          key: key,
          tooltip: label,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            HapticFeedback.selectionClick();
            n.nudge(ms);
          },
          icon: Icon(icon, size: 18, color: t.ac),
        );
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: t.faint)),
      child: Row(children: [
        Tooltip(
          message: 'Hear an echo? If this phone sounds behind, tap +; '
              'ahead, tap −. It stays set for this phone.',
          triggerMode: TooltipTriggerMode.tap,
          child: Row(children: [
            Icon(Icons.graphic_eq_rounded, size: 18, color: t.mute),
            const SizedBox(width: 8),
            Text('TIMING',
                style: TextStyle(
                    color: t.mute,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
        const Spacer(),
        step(Icons.remove_rounded, 'Later', -20,
            const ValueKey('room-tune-later')),
        GestureDetector(
          onLongPress: () => n.set(0),
          child: SizedBox(
            width: 64,
            child: Text(
                tune == 0 ? '0 ms' : '${tune > 0 ? '+' : '−'}${tune.abs()} ms',
                key: const ValueKey('room-tune-value'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: t.ac, fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ),
        step(Icons.add_rounded, 'Earlier', 20,
            const ValueKey('room-tune-earlier')),
        const SizedBox(width: 4),
      ]),
    );
  }
}
