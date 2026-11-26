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
    state = n.length > kRoomNameMax ? n.substring(0, kRoomNameMax).trim() : n;
    try {
      (await SharedPreferences.getInstance()).setString(_k, state);
    } catch (_) {}
  }
}

/// This phone's timing in rooms, in ms (+: plays earlier than the star's
/// place). Phones take different times to get sound out of the speaker
/// (more with sound effects on or with earbuds), which the player can't
/// see; a listener tunes it by ear once and it stays.
final roomTuneProvider =
    StateNotifierProvider<RoomTuneNotifier, int>((ref) => RoomTuneNotifier());

class RoomTuneNotifier extends StateNotifier<int> {
  RoomTuneNotifier() : super(0) {
    SharedPreferences.getInstance().then((p) {
      if (mounted) state = p.getInt(_k) ?? 0;
    }).catchError((_) {});
  }
  static const _k = 'room_tune_ms';

  /// The most either way.
  static const limit = 600;

  void nudge(int ms) => set(state + ms);

  Future<void> set(int ms) async {
    state = ms.clamp(-limit, limit);
    nlog('[R] timing for this phone: ${state > 0 ? '+' : ''}${state}ms');
    try {
      (await SharedPreferences.getInstance()).setInt(_k, state);
    } catch (_) {}
  }
}

/// Every phone always has a room of its own (its code shows on the
/// player); off in tests that drive rooms by hand.
final roomAutoHomeProvider = Provider<bool>((ref) => true);

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) {
  final store = ref.watch(roomStoreProvider);
  final n = RoomNotifier(ref, store == null ? null : RoomController(store),
      autoHome: ref.watch(roomAutoHomeProvider));
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
  RoomNotifier(this._ref, this.controller, {this.autoHome = true})
      : super(const RoomState()) {
    final c = controller;
    if (c == null) return;
    _subs.add(c.changes.listen(_onState));
    _subs.add(c.events.listen(_events.add));
    unawaited(_resume());
    // A name given (or changed) shows in the room at once.
    _ref.listen<String>(roomNameProvider, (prev, next) {
      if (next.isNotEmpty && next != prev) {
        unawaited(c.setMyName(next).catchError((Object e) {
          nlog('[R] could not show the new name: $e');
        }));
      }
    });
  }

  static const _kRoom = 'room_code';

  /// Back in the room after the app was closed (swiped away, the phone
  /// restarted): the room is remembered until this phone leaves it.
  Future<void> _resume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_kRoom);
      if (code != null && controller != null) {
        if (!await controller!.resume(code)) await prefs.remove(_kRoom);
      }
    } catch (_) {}
    _resumed = true;
    _ensureHome();
  }

  /// Every phone always has a room: its own (where it's the star) unless
  /// it's in someone else's. Made when the app opens with none to go back
  /// to, and again after leaving a room, being turned away or the room
  /// ending. Going to the background or closing the app keeps it (it's
  /// rejoined on opening), so the code stays the same for a while.
  final bool autoHome;
  bool _resumed = false;
  bool _homing = false;
  bool _joining = false;
  Timer? _homeTimer;

  void _ensureHome({Duration wait = const Duration(milliseconds: 600)}) {
    if (!autoHome || controller == null || !_resumed || !mounted) return;
    _homeTimer?.cancel();
    _homeTimer = Timer(wait, () async {
      if (!mounted || _homing || _joining || state.role != RoomRole.none) {
        return;
      }
      _homing = true;
      try {
        await controller!.start(await _name());
      } on RoomStoreError catch (e) {
        nlog('[R] making this phone\'s room: $e (again in 20 s)');
        _homing = false;
        _ensureHome(wait: const Duration(seconds: 20));
        return;
      } catch (_) {}
      _homing = false;
    });
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
      if (s.role == RoomRole.none) _ensureHome();
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
    final h = _handler;
    if (h != null) h.following = following;
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
  int _failures = 0;
  int _retryAt = 0;
  String _queueKey = '';

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  void _publish() {
    final h = _handler;
    final c = controller;
    if (h == null || c == null) return;
    // Alone in the room: nothing to send. Someone joining gets it at once.
    if ((state.room?.members.length ?? 0) <= 1) {
      _publisher.failed();
      _queueKey = '';
      return;
    }
    final song = h.currentSong;
    final playing = h.player.playing;
    final pos = h.player.position;
    final now = _nowMs;
    final id = song?.videoId ?? '';
    if (now < _retryAt) return; // no connection: wait a little
    if (_publisher.due(id, playing, pos, now)) {
      _publisher.sent(id, playing, pos, now);
      // Stamped with when the position was read (not when it reaches the
      // store, which is late by the upload time).
      final at = c.clockReady ? c.serverNow() : null;
      unawaited(c.publishPlay(song, pos, playing, at: at).then((_) {
        if (_failures > 0) nlog('[R] room reachable again');
        _failures = 0;
      }).catchError((Object e) {
        // Offline (or Firebase unreachable): try again after 1, 2, 4… up to
        // 15 s, and say so once, not twice a second.
        if (_failures == 0) nlog('[R] cannot reach the room: $e');
        _failures++;
        _retryAt = _nowMs + (500 << _failures.clamp(0, 5)).clamp(1000, 15000);
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
    // This phone's own timing (tuned by ear): aim that much earlier.
    final tune = _ref.read(roomTuneProvider);
    f.tick(state.room?.play,
        serverNow: c.serverNow() + tune, nowMs: _nowMs, clockRtt: c.clockRtt);
    // What plays next in the room downloads ahead on this phone.
    final h = _handler;
    final room = state.room;
    if (h != null && room != null && room.play?.song == h.currentSong) {
      h.followQueue(room.queue);
    }
  }

  // ── Actions (the room sheet) ──────────────────────────────────────────

  Future<String> _name() async {
    await _ref.read(roomNameProvider.notifier).loaded;
    final n = _ref.read(roomNameProvider);
    if (n.isNotEmpty) return n;
    // Until a name is given: "Guest" and a tag, like a room code.
    try {
      await controller?.store.ready();
    } catch (_) {}
    return guestName(controller?.uid ?? '');
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

  /// Asks to join [code]: this phone leaves its own room (or the one it's
  /// in) first. Turned away, it gets a room of its own again.
  Future<String?> knock(String code) async {
    final c = controller;
    if (c == null) return 'Rooms are not set up in this build';
    if (code == state.code) return "That's this room's own code";
    _joining = true;
    try {
      if (state.inRoom) await c.leave();
      final why = await c.knock(code, await _name());
      return why;
    } on RoomStoreError catch (e) {
      nlog('[R] knocking: $e');
      return "Couldn't reach the room · check the internet";
    } finally {
      _joining = false;
      if (state.role == RoomRole.none) _ensureHome();
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

  /// The star's name is the room's: renaming changes this phone's name,
  /// which the room then shows (at most [kRoomNameMax] letters).
  Future<void> rename(String name) async {
    await _ref.read(roomNameProvider.notifier).set(name);
  }

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
    _homeTimer?.cancel();
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
