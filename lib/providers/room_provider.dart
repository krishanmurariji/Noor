import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../services/app_log.dart';
import '../services/audio_handler.dart';
import '../services/rooms/firebase_room_store.dart';
import '../services/rooms/room.dart';
import '../services/rooms/room_store.dart';
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
      _role = s.role;
      _published = null;
      _followed = null;
      _settleUntil = null;
      _setSpeed(1.0);
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

  ({String id, bool playing, int pos, DateTime at})? _published;
  String _queueKey = '';

  void _publish() {
    final h = _handler;
    final c = controller;
    if (h == null || c == null) return;
    final song = h.currentSong;
    final playing = h.player.playing;
    final pos = h.player.position;
    final now = DateTime.now();
    final last = _published;
    var due = last == null ||
        last.id != (song?.videoId ?? '') ||
        last.playing != playing ||
        now.difference(last.at).inSeconds >= 20;
    if (!due) {
      final expected =
          last.pos + (playing ? now.difference(last.at).inMilliseconds : 0);
      // A seek, or the song stalled to buffer: everyone needs the new place.
      due = (pos.inMilliseconds - expected).abs() > 300;
    }
    if (due) {
      _published = (
        id: song?.videoId ?? '',
        playing: playing,
        pos: pos.inMilliseconds,
        at: now
      );
      // Stamped with when the position was read (not when it reaches the
      // store, which is late by the upload time).
      final at = c.clockReady ? c.serverNow() : null;
      unawaited(
          c.publishPlay(song, pos, playing, at: at).catchError((Object e) {
        nlog('[R] publishing playback: $e');
        _published = null;
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

  /// The star's playback as last applied here.
  ({String id, bool playing})? _followed;

  /// How far ahead to aim a seek so the song lands in place once the
  /// player has actually moved there (learned on this phone).
  int _leadMs = 150;

  /// After a seek: wait until then before measuring again; [_seekedTo] is
  /// what it aimed for.
  DateTime? _settleUntil;
  double _speed = 1.0;
  DateTime _lastLog = DateTime.fromMillisecondsSinceEpoch(0);

  void _setSpeed(double x) {
    if ((x - _speed).abs() < 0.001) return;
    _speed = x;
    final h = _handler;
    if (h != null) unawaited(h.player.setSpeed(x).catchError((_) {}));
  }

  void _seekTo(NebulaAudioHandler h, Duration at) {
    _setSpeed(1.0);
    _settleUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    unawaited(h.seek(at));
  }

  void _follow() {
    final h = _handler;
    final c = controller;
    final play = state.room?.play;
    if (h == null || c == null || play == null) return;
    final now = DateTime.now();
    final settling = _settleUntil != null && now.isBefore(_settleUntil!);
    final myLoading =
        _ref.read(playerProvider).status == NebulaPlayerStatus.loading;
    final step = followStep(
      play: play,
      serverNow: c.serverNow(),
      mine: h.currentSong,
      myPosition: h.player.position,
      myPlaying: h.player.playing,
      myLoading: myLoading || settling,
      mySpeed: _speed,
      leadMs: _leadMs,
      last: _followed,
    );
    // Just settled after a seek: how far off it landed teaches the lead.
    if (_settleUntil != null && !settling && !myLoading) {
      _settleUntil = null;
      final d = step.driftMs;
      if (d != null && d.abs() < 3000) {
        _leadMs = (_leadMs - (d * 0.8).round()).clamp(0, 1500);
        nlog('[R] sync: landed ${d > 0 ? '+' : ''}${d}ms off, '
            'seek lead now ${_leadMs}ms');
      }
    }
    if (step.driftMs != null &&
        now.difference(_lastLog) > const Duration(seconds: 6)) {
      _lastLog = now;
      nlog('[R] sync: ${step.driftMs! > 0 ? '+' : ''}${step.driftMs}ms '
          'from the star, speed ${_speed.toStringAsFixed(3)}, '
          'clock ±${(c.clockRtt ?? 0) ~/ 2}ms');
    }
    if (step.kind != FollowKind.none && step.kind != FollowKind.speed) {
      nlog('[R] follow: ${step.kind.name}'
          '${step.at == null ? '' : ' @${step.at!.inMilliseconds}ms'}');
    }
    _followed = (id: play.song?.videoId ?? '', playing: play.playing);
    switch (step.kind) {
      case FollowKind.none:
        break;
      case FollowKind.speed:
        _setSpeed(step.speed);
        break;
      case FollowKind.load:
        _setSpeed(1.0);
        unawaited(h.playSong(step.song!, queue: [step.song!]).then((_) async {
          final again = state.room?.play;
          if (again == null || again.song?.videoId != step.song!.videoId) {
            return;
          }
          _seekTo(
              h,
              again.positionAt(c.serverNow()) +
                  Duration(milliseconds: _leadMs));
          if (!again.playing) await h.pause();
        }));
        break;
      case FollowKind.seek:
        _seekTo(h, step.at!);
        break;
      case FollowKind.play:
        if (step.at != null) _seekTo(h, step.at!);
        unawaited(h.play());
        break;
      case FollowKind.pause:
        _setSpeed(1.0);
        unawaited(h.pause());
        break;
    }
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

enum FollowKind { none, load, seek, play, pause, speed }

class FollowStep {
  const FollowStep(this.kind,
      {this.song, this.at, this.speed = 1.0, this.driftMs});
  final FollowKind kind;
  final Song? song;
  final Duration? at;

  /// For [FollowKind.speed]: the playback speed to use (1.0 = normal).
  final double speed;

  /// This phone minus the star, in ms (+: ahead), when both play the same
  /// song.
  final int? driftMs;
  static const none = FollowStep(FollowKind.none);
}

/// Further apart than this, a listener jumps (seeks) to the star's place.
const kRoomSeekMs = 700;

/// Closer than [kRoomSeekMs] but more than this, it plays a little faster
/// or slower until it's back with the star (no audible jump).
const kRoomNudgeMs = 35;

/// Back within this, normal speed again.
const kRoomInSyncMs = 12;

/// The most a listener speeds up or slows down (5 %).
const kRoomMaxNudge = 0.05;

/// What a listener's player should do to match the star's [play].
///
/// [last] is the star's song and play/pause as last applied here: a
/// listener may pause on their own, and that holds until the star changes
/// something (pauses, plays or picks another song). [leadMs] is how far
/// ahead to aim a seek (a seek lands late by about that much).
FollowStep followStep({
  required RoomPlay play,
  required int serverNow,
  required Song? mine,
  required Duration myPosition,
  required bool myPlaying,
  required bool myLoading,
  required ({String id, bool playing})? last,
  double mySpeed = 1.0,
  int leadMs = 0,
}) {
  final song = play.song;
  final changed = last == null ||
      last.id != (song?.videoId ?? '') ||
      last.playing != play.playing;
  if (song == null || play.fromPhone || !song.isPlayable) {
    return changed && myPlaying
        ? const FollowStep(FollowKind.pause)
        : FollowStep.none;
  }
  final target = play.positionAt(serverNow);
  final aim = target + Duration(milliseconds: leadMs);
  if (mine?.videoId != song.videoId) {
    // A new song (or one this phone dropped): only when the star changed
    // it, or this phone isn't loading something already.
    if (myLoading && !changed) return FollowStep.none;
    return FollowStep(FollowKind.load, song: song, at: target);
  }
  final drift = (myPosition - target).inMilliseconds;
  if (myLoading) return FollowStep(FollowKind.none, driftMs: drift);
  if (changed) {
    if (play.playing && !myPlaying) {
      return FollowStep(FollowKind.play,
          at: drift.abs() > kRoomNudgeMs ? aim : null, driftMs: drift);
    }
    if (!play.playing && myPlaying) {
      return FollowStep(FollowKind.pause, driftMs: drift);
    }
  }
  if (!play.playing || !myPlaying) {
    return FollowStep(FollowKind.none, driftMs: drift);
  }
  if (drift.abs() > kRoomSeekMs) {
    return FollowStep(FollowKind.seek, at: aim, driftMs: drift);
  }
  // Small gaps close smoothly: ahead → a little slower, behind → faster,
  // in proportion (a 250 ms gap closes in about 5 s, at most 5 % off).
  double want;
  if (drift.abs() <= kRoomInSyncMs) {
    want = 1.0;
  } else if (drift.abs() > kRoomNudgeMs || mySpeed != 1.0) {
    want = 1.0 - (drift / 2500).clamp(-kRoomMaxNudge, kRoomMaxNudge);
  } else {
    want = mySpeed;
  }
  want = double.parse(want.toStringAsFixed(3));
  if ((want - mySpeed).abs() >= 0.002) {
    return FollowStep(FollowKind.speed, speed: want, driftMs: drift);
  }
  return FollowStep(FollowKind.none, driftMs: drift);
}
