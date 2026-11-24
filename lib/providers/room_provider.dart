import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/app_log.dart';
import '../services/audio_handler.dart';
import '../services/rooms/firebase_room_store.dart';
import '../services/rooms/room.dart';
import '../services/rooms/room_store.dart';
import '../services/rooms/room_sync.dart';
export '../services/rooms/room_sync.dart'
    show FollowKind, FollowStep, followStep;
import 'player_provider.dart';

/// Where rooms live. Null when this build has no Firebase project set up
/// (Rooms then say so instead of starting).
final roomStoreProvider = Provider<RoomStore?>((ref) {
  const config = RoomConfig.fromBuild;
  return config.ready ? FirebaseRoomStore(config) : null;
});

/// The name this phone shows in rooms (asked once, then remembered).
final roomNameProvider = StateNotifierProvider<RoomNameNotifier, String>(
    (ref) => RoomNameNotifier());

class RoomNameNotifier extends StateNotifier<String> {
  RoomNameNotifier() : super('') {
    loaded = SharedPreferences.getInstance().then((p) {
      if (mounted && state.isEmpty) state = p.getString(_k) ?? '';
    }).catchError((_) {});
  }

  /// Done reading the saved name.
  late final Future<void> loaded;
  static const _k = 'room_my_name';

  Future<void> set(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    state = n.length > 24 ? n.substring(0, 24) : n;
    try {
      (await SharedPreferences.getInstance()).setString(_k, state);
    } catch (_) {}
  }
}

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) {
  final store = ref.watch(roomStoreProvider);
  final n = RoomNotifier(ref, store == null ? null : RoomController(store));
  return n;
});

/// Things to say in the capsule ("Rohan wants to join").
final roomEventsProvider = StreamProvider<RoomEvent>((ref) {
  ref.watch(roomProvider.notifier);
  return ref.read(roomProvider.notifier).events;
});

/// Keeps this phone and the room together: the star's playback goes up to
/// the room, a listener's player follows it.
class RoomNotifier extends StateNotifier<RoomState> {
  RoomNotifier(this._ref, this.controller) : super(const RoomState()) {
    final c = controller;
    if (c == null) return;
    _subs.add(c.changes.listen(_onState));
    _subs.add(c.events.listen(_events.add));
    unawaited(_resume());
  }

  static const _kRoom = 'room_code';

  /// Back in the room after the app was closed (swiped away, the phone
  /// restarted): the room is remembered until this phone leaves it.
  Future<void> _resume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_kRoom);
      if (code == null || controller == null) return;
      if (!await controller!.resume(code)) await prefs.remove(_kRoom);
    } catch (_) {}
  }

  Future<void> _remember(String? code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (code == null) {
        await prefs.remove(_kRoom);
      } else {
        await prefs.setString(_kRoom, code);
      }
    } catch (_) {}
  }

  final Ref _ref;
  final RoomController? controller;
  final List<StreamSubscription<Object?>> _subs = [];
  final _events = StreamController<RoomEvent>.broadcast();
  Stream<RoomEvent> get events => _events.stream;
  Timer? _tick;
  RoomRole _role = RoomRole.none;

  /// Rooms work in this build.
  bool get available => controller != null;

  NebulaAudioHandler? get _handler {
    try {
      return _ref.read(audioHandlerProvider);
    } catch (_) {
      return null; // tests without a player
    }
  }

  void _onState(RoomState s) {
    if (!mounted) return;
    state = s;
    if (s.role != _role) {
      if (s.inRoom) {
        unawaited(_remember(s.code));
      } else if (_role == RoomRole.star || _role == RoomRole.listener) {
        unawaited(_remember(null)); // left, removed, or the room ended
      }
      _role = s.role;
      _publisher.failed(); // a new star sends at once
      _follower?.reset();
      _tick?.cancel();
      _tick = null;
      _lockPlayer(s.isListener);
      if (s.inRoom) {
        _tick =
            Timer.periodic(const Duration(milliseconds: 500), (_) => _step());
        _step();
      }
    } else if (s.inRoom) {
      if (s.isListener) _follow();
    }
  }

  void _lockPlayer(bool following) {
    try {
      final p = _ref.read(playerProvider.notifier);
      p.followingStar =
          following ? () => state.room?.starName ?? 'the star' : null;
      p.onSongWhileFollowing = following ? _offerAsk : null;
    } catch (_) {}
  }

  void _offerAsk(Song song) {
    _events.add(RoomEvent('Ask ${state.room?.starName ?? 'the star'} to play '
        '${song.title}?'));
    _pendingAsk = song;
  }

  Song? _pendingAsk;

  /// The song a listener tapped (offered in the capsule's "Ask" button).
  Song? takePendingAsk() {
    final s = _pendingAsk;
    _pendingAsk = null;
    return s;
  }

  void _step() {
    if (state.isStar) {
      _publish();
    } else if (state.isListener) {
      _follow();
    }
  }

  // ── The star publishes ────────────────────────────────────────────────

  final RoomPublisher _publisher = RoomPublisher();
  String _queueKey = '';

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  void _publish() {
    final h = _handler;
    final c = controller;
    if (h == null || c == null) return;
    final song = h.currentSong;
    final playing = h.player.playing;
    final pos = h.player.position;
    final now = _nowMs;
    final id = song?.videoId ?? '';
    if (_publisher.due(id, playing, pos, now)) {
      _publisher.sent(id, playing, pos, now);
      // Stamped with when the position was read (not when it reaches the
      // store, which is late by the upload time).
      final at = c.clockReady ? c.serverNow() : null;
      unawaited(
          c.publishPlay(song, pos, playing, at: at).catchError((Object e) {
        nlog('[R] publishing playback: $e');
        _publisher.failed();
      }));
    }
    final q = h.songQueue;
    final i = h.songQueueIndex;
    final upNext = i + 1 < q.length ? q.sublist(i + 1) : const <Song>[];
    final key = upNext.take(kRoomCap).map((s) => s.videoId).join(',');
    if (key != _queueKey) {
      _queueKey = key;
      unawaited(c.publishQueue(upNext).catchError((Object e) {
        _queueKey = '';
      }));
    }
  }

  // ── A listener follows ────────────────────────────────────────────────

  RoomFollower? _followerOf;
  RoomFollower? get _follower {
    final h = _handler;
    if (h == null) return null;
    return _followerOf ??= RoomFollower(
        _HandlerPlayer(
            h,
            () =>
                _ref.read(playerProvider).status == NebulaPlayerStatus.loading),
        log: nlog);
  }

  void _follow() {
    final f = _follower;
    final c = controller;
    if (f == null || c == null) return;
    f.tick(state.room?.play,
        serverNow: c.serverNow(), nowMs: _nowMs, clockRtt: c.clockRtt);
  }

  // ── Actions (the room sheet) ──────────────────────────────────────────

  Future<String> _name() async {
    await _ref.read(roomNameProvider.notifier).loaded;
    final n = _ref.read(roomNameProvider);
    return n.isEmpty ? 'A friend' : n;
  }

  Future<String?> start() async {
    final c = controller;
    if (c == null) return 'Rooms are not set up in this build';
    try {
      await c.start(await _name());
      return null;
    } on RoomStoreError catch (e) {
      nlog('[R] starting a room: $e');
      return "Couldn't start a room · check the internet";
    }
  }

  Future<String?> knock(String code) async {
    final c = controller;
    if (c == null) return 'Rooms are not set up in this build';
    try {
      return await c.knock(code, await _name());
    } on RoomStoreError catch (e) {
      nlog('[R] knocking: $e');
      return "Couldn't reach the room · check the internet";
    }
  }

  Future<void> _safe(Future<void> Function(RoomController c) f) async {
    final c = controller;
    if (c == null) return;
    try {
      await f(c);
    } on RoomStoreError catch (e) {
      nlog('[R] room action: $e');
      _events.add(const RoomEvent("Couldn't reach the room · try again"));
    }
  }

  Future<void> cancelKnock() => _safe((c) => c.cancelKnock());
  Future<void> leave() => _safe((c) => c.leave());

  Future<void> letIn(RoomKnock k) => _safe((c) async {
        if (!await c.letIn(k)) {
          _events.add(const RoomEvent('The room is full · 20 is the most'));
        }
      });
  Future<void> notNow(RoomKnock k) => _safe((c) => c.notNow(k));
  Future<void> block(String uid, String name) =>
      _safe((c) => c.block(uid, name));
  Future<void> remove(String uid) => _safe((c) => c.remove(uid));
  Future<void> handOver(RoomMember m) => _safe((c) => c.handOver(m));

  /// The star renames the room (at most [kRoomNameMax] letters).
  Future<void> rename(String name) => _safe((c) => c.rename(name));

  /// A listener: jump straight to the star's place now.
  void syncNow() {
    _follower?.resync();
    _follow();
  }

  /// The star: every listener jumps to the star's place.
  void syncEveryone() {
    controller?.syncEveryone();
    _publisher.failed(); // send at once
    _publish();
    _events.add(const RoomEvent('Syncing everyone'));
  }

  Future<void> decline(RoomAsk a) => _safe((c) => c.decline(a));

  Future<void> acceptSong(RoomAsk a, {required bool next}) => _safe((c) async {
        final h = _handler;
        final song = a.song;
        if (song == null) return;
        if (h != null) {
          if (next) {
            h.insertNext(song);
          } else {
            h.append(song);
          }
        }
        await c.acceptSong(a, next: next);
        _queueKey = ''; // publish the new order
      });

  Future<void> askForSong(Song song) => _safe((c) async {
        await c.askForSong(song);
        _events.add(RoomEvent('Asked for ${song.title}'));
      });

  Future<void> askToBeStar() => _safe((c) async {
        await c.askToBeStar();
        _events.add(const RoomEvent('Asked to be the star'));
      });

  bool get askedToBeStar => controller?.askedToBeStar ?? false;
  String get uid => controller?.uid ?? '';

  @override
  void dispose() {
    _tick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _events.close();
    controller?.dispose();
    super.dispose();
  }
}

/// The app's player, as the room follower sees it.
class _HandlerPlayer implements FollowPlayer {
  _HandlerPlayer(this.h, this._loading);
  final NebulaAudioHandler h;
  final bool Function() _loading;

  @override
  String? get songId => h.currentSong?.videoId;
  @override
  Duration get position => h.player.position;
  @override
  bool get playing => h.player.playing;
  @override
  bool get loading => _loading();
  @override
  void load(Song song) => unawaited(h.playSong(song, queue: [song]));
  @override
  void seek(Duration to) => unawaited(h.seek(to));
  @override
  void play() => unawaited(h.play());
  @override
  void pause() => unawaited(h.pause());
  @override
  void setSpeed(double speed) =>
      unawaited(h.player.setSpeed(speed).catchError((_) {}));
}
