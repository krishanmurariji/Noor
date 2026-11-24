import '../../models/song.dart';
import 'room.dart';

// Keeping a room's phones in step: the store's clock, the star's side
// (when to send where the song is) and a listener's side (how to follow).
// Plain Dart with the time passed in, so the same code runs in the app and
// in the sync simulator (test/room_sync_sim_test.dart).

/// This phone's idea of the store's clock, from timed writes: the store
/// stamps a write, and halfway through the round trip is when it did.
/// The reading with the shortest round trip is the most exact one (its
/// error is at most half that round trip).
class ClockSync {
  int offset = 0;

  /// Round trip of the reading in use (ms); null before the first one.
  int? rtt;
  int _readAt = 0;

  bool get ready => rtt != null;

  /// A reading: the local clock [before] and [after] the write, and the
  /// store's stamp [serverAt].
  void add(int before, int serverAt, int after) {
    final trip = after - before;
    if (trip < 0) return;
    // Phone clocks drift slowly: after 5 minutes any new reading counts.
    final stale = after - _readAt > 5 * 60 * 1000;
    if (rtt == null || trip <= rtt! + 20 || stale) {
      offset = serverAt - (before + after) ~/ 2;
      rtt = trip;
      _readAt = after;
    }
  }

  int serverNow(int local) => local + offset;
}

/// The star's side: when to send the room where the song is.
class RoomPublisher {
  ({String id, bool playing, int pos, int at})? _last;

  /// True when what plays should go up now: a new song, play/pause, the
  /// song more than 60 ms from where the last message says it is (a seek,
  /// the moment of silence after one, or a stall while buffering), or 5 s
  /// since the last time (a small message; it keeps everyone's reference
  /// fresh).
  bool due(String id, bool playing, Duration position, int nowMs) {
    final last = _last;
    if (last == null ||
        last.id != id ||
        last.playing != playing ||
        nowMs - last.at >= 5000) {
      return true;
    }
    final expected = last.pos + (playing ? nowMs - last.at : 0);
    return (position.inMilliseconds - expected).abs() > 60;
  }

  void sent(String id, bool playing, Duration position, int nowMs) => _last =
      (id: id, playing: playing, pos: position.inMilliseconds, at: nowMs);

  /// Sending failed: try again on the next tick.
  void failed() => _last = null;
}

/// What a listener's follower controls: the phone's player.
abstract class FollowPlayer {
  String? get songId;

  /// Where the song is now, by the player.
  Duration get position;
  bool get playing;

  /// Loading a song (nothing to measure yet).
  bool get loading;

  /// Starts [song] (it begins playing when ready).
  void load(Song song);
  void seek(Duration to);
  void play();
  void pause();
  void setSpeed(double speed);
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

  /// This phone minus the star, in ms (+: ahead), when both are on the
  /// same song.
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

/// The most a listener speeds up or slows down (6 %, with the pitch kept).
const kRoomMaxNudge = 0.06;

/// How long after a seek before measuring again (the player is still
/// getting the audio going).
const kRoomSettleMs = 1500;

/// What a listener's player should do to match the star's [play].
///
/// [last] is the star's song and play/pause as last applied here: a
/// listener may pause on their own, and that holds until the star changes
/// something (plays or picks another song). A listener can't play while
/// the star is paused. [leadMs] is how far ahead to aim a seek (a seek
/// lands late by about that much).
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
    return myPlaying && !myLoading
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
  if (!play.playing) {
    if (myPlaying) return FollowStep(FollowKind.pause, driftMs: drift);
    // Paused together: be at the same place for when it plays again.
    return drift.abs() > kRoomSeekMs
        ? FollowStep(FollowKind.seek, at: target, driftMs: drift)
        : FollowStep(FollowKind.none, driftMs: drift);
  }
  if (!myPlaying) {
    if (!changed) return FollowStep(FollowKind.none, driftMs: drift);
    return FollowStep(FollowKind.play,
        at: drift.abs() > kRoomNudgeMs ? aim : null, driftMs: drift);
  }
  if (drift.abs() > kRoomSeekMs) {
    return FollowStep(FollowKind.seek, at: aim, driftMs: drift);
  }
  // Small gaps close smoothly: ahead → a little slower, behind → faster,
  // in proportion (a 300 ms gap closes in about 5 s, at most 6 % off).
  double want;
  if (drift.abs() <= kRoomInSyncMs) {
    want = 1.0;
  } else if (drift.abs() > kRoomNudgeMs || mySpeed != 1.0) {
    want = 1.0 - (drift / 2000).clamp(-kRoomMaxNudge, kRoomMaxNudge);
  } else {
    want = mySpeed;
  }
  want = double.parse(want.toStringAsFixed(3));
  if ((want - mySpeed).abs() >= 0.002) {
    return FollowStep(FollowKind.speed, speed: want, driftMs: drift);
  }
  return FollowStep(FollowKind.none, driftMs: drift);
}

/// A listener's side: run [tick] twice a second with the star's latest
/// [RoomPlay]; it drives the [player] to match.
class RoomFollower {
  RoomFollower(this.player, {this.log});

  final FollowPlayer player;
  final void Function(String line)? log;

  /// How far ahead to aim a seek so the song lands in place once the
  /// player has actually moved there (learned on this phone).
  int leadMs = 300;
  double speed = 1.0;

  /// Seeks so far (the simulator checks they stay rare).
  int seeks = 0;

  ({String id, bool playing})? _last;
  int? _settleUntil;
  int _lastLog = -1 << 40;

  /// The last measured gap to the star (ms, +: ahead).
  int? driftMs;

  void reset() {
    _last = null;
    _settleUntil = null;
    _setSpeed(1.0);
  }

  void _setSpeed(double x) {
    if ((x - speed).abs() < 0.001) return;
    speed = x;
    player.setSpeed(x);
  }

  void _seek(Duration to, int nowMs) {
    _setSpeed(1.0);
    seeks++;
    _settleUntil = nowMs + kRoomSettleMs;
    player.seek(to);
  }

  void tick(RoomPlay? play,
      {required int serverNow, required int nowMs, int? clockRtt}) {
    if (play == null) return;
    final settling = _settleUntil != null && nowMs < _settleUntil!;
    final step = followStep(
      play: play,
      serverNow: serverNow,
      mine: player.songId == null
          ? null
          : Song(
              videoId: player.songId!, title: '', artist: '', thumbnailUrl: ''),
      myPosition: player.position,
      myPlaying: player.playing,
      myLoading: player.loading || settling,
      mySpeed: speed,
      leadMs: leadMs,
      last: _last,
    );
    driftMs = step.driftMs;
    // Just settled after a seek: how far off it landed teaches the lead.
    if (_settleUntil != null && !settling && !player.loading) {
      _settleUntil = null;
      final d = step.driftMs;
      if (d != null && d.abs() < 3000) {
        // Half the error each time, at most 200 ms: one unlucky seek
        // (the star stalled meanwhile) can't throw it far off.
        leadMs = (leadMs - (d * 0.5).round().clamp(-200, 200)).clamp(0, 1500);
        log?.call('[R] sync: landed ${d > 0 ? '+' : ''}${d}ms off, '
            'seek lead now ${leadMs}ms');
      }
    }
    if (step.driftMs != null && nowMs - _lastLog > 6000) {
      _lastLog = nowMs;
      log?.call('[R] sync: ${step.driftMs! > 0 ? '+' : ''}${step.driftMs}ms '
          'from the star, speed ${speed.toStringAsFixed(3)}'
          '${clockRtt == null ? '' : ', clock ±${clockRtt ~/ 2}ms'}');
    }
    if (step.kind != FollowKind.none && step.kind != FollowKind.speed) {
      log?.call('[R] follow: ${step.kind.name}'
          '${step.at == null ? '' : ' @${step.at!.inMilliseconds}ms'}');
    }
    _last = (id: play.song?.videoId ?? '', playing: play.playing);
    switch (step.kind) {
      case FollowKind.none:
        break;
      case FollowKind.speed:
        _setSpeed(step.speed);
        break;
      case FollowKind.load:
        // Once it's loaded, the next ticks seek it into place (and pause
        // it if the star is paused).
        _setSpeed(1.0);
        _settleUntil = null;
        player.load(step.song!);
        break;
      case FollowKind.seek:
        _seek(step.at!, nowMs);
        break;
      case FollowKind.play:
        if (step.at != null) _seek(step.at!, nowMs);
        player.play();
        break;
      case FollowKind.pause:
        _setSpeed(1.0);
        player.pause();
        break;
    }
  }
}
