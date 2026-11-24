import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor/models/song.dart';
import 'package:noor/services/rooms/room.dart';
import 'package:noor/services/rooms/room_sync.dart';

// A simulator for room sync: a star and a listener, each with its own
// clock (minutes off, drifting), a network with delays and jitter, players
// that take time to seek and load and sometimes stall, and a star who
// seeks, pauses and changes songs. The listener runs the app's real
// RoomFollower, the star the real RoomPublisher and both the real
// ClockSync. The test measures the true gap between what the two phones
// play, every 100 ms of simulated time.

const _songA =
    Song(videoId: 'aaaaaaaaaaa', title: 'A', artist: '', thumbnailUrl: '');
const _songB =
    Song(videoId: 'bbbbbbbbbbb', title: 'B', artist: '', thumbnailUrl: '');

class _World {
  int t = 0; // true time, ms
}

/// A phone's player: the true place in the song, plus what it reports.
class _Player implements FollowPlayer {
  _Player(this.w, this.rng, {required this.seekMs, required this.loadMs});
  final _World w;
  final Random rng;
  final int seekMs;
  final int loadMs;
  final int noiseMs = 10;

  String? id;
  double pos = 0; // true position, ms
  bool isPlaying = false;
  double rate = 1;
  int frozenUntil = 0; // seeking or stalled: no sound moves
  int loadedAt = -1;

  void advance(int dt) {
    if (loadedAt >= 0 && w.t >= loadedAt) {
      loadedAt = -1;
      isPlaying = true; // a loaded song starts playing
    }
    if (isPlaying && w.t >= frozenUntil && loadedAt < 0) pos += dt * rate;
  }

  int _vary(int ms) => (ms * (0.7 + 0.6 * rng.nextDouble())).round();

  @override
  String? get songId => id;
  @override
  Duration get position => Duration(
      milliseconds: (pos + (rng.nextDouble() * 2 - 1) * noiseMs).round());
  @override
  bool get playing => isPlaying && loadedAt < 0;
  @override
  bool get loading => loadedAt >= 0;
  @override
  void load(Song song) {
    id = song.videoId;
    pos = 0;
    isPlaying = false;
    loadedAt = w.t + _vary(loadMs);
  }

  @override
  void seek(Duration to) {
    pos = to.inMilliseconds.toDouble();
    frozenUntil = w.t + _vary(seekMs);
  }

  @override
  void play() => isPlaying = true;
  @override
  void pause() => isPlaying = false;
  @override
  void setSpeed(double speed) {
    expect(speed, inInclusiveRange(1 - kRoomMaxNudge, 1 + kRoomMaxNudge));
    rate = speed;
  }

  void stall(int ms) => frozenUntil = w.t + ms;
}

/// A phone's clock: off by [skew] and running [ppm] fast or slow.
class _Clock {
  _Clock(this.w, this.skew, this.ppm);
  final _World w;
  final int skew;
  final double ppm;
  int get now => (w.t * (1 + ppm / 1e6)).round() + skew;
}

class _Net {
  _Net(this.rng, this.minMs, this.maxMs, {this.spikes = 0});
  final Random rng;
  final int minMs, maxMs;

  /// Chance of a slow message (×4).
  final double spikes;
  int delay() {
    final d = minMs + rng.nextInt(maxMs - minMs + 1);
    return rng.nextDouble() < spikes ? d * 4 : d;
  }
}

class _Result {
  final gaps = <int>[];
  int seeks = 0;
  int events = 0;
  String describe() {
    final s = gaps.map((g) => g.abs()).toList()..sort();
    if (s.isEmpty) return 'no samples';
    int pct(double p) => s[((s.length - 1) * p).round()];
    return 'median ${pct(.5)} ms, p95 ${pct(.95)} ms, max ${s.last} ms, '
        '${s.length} samples, $seeks seeks';
  }

  int pct(double p) {
    final s = gaps.map((g) => g.abs()).toList()..sort();
    return s[((s.length - 1) * p).round()];
  }
}

/// Runs one room for [seconds] of simulated time.
_Result simulate(int seed,
    {required _Net up,
    required _Net down,
    _Net? listenerUp,
    _Net? listenerDown,
    int seconds = 160,
    bool script = true}) {
  final rng = Random(seed);
  final w = _World();
  final starClock =
      _Clock(w, rng.nextInt(240000) - 120000, rng.nextDouble() * 100 - 50);
  final lisClock =
      _Clock(w, rng.nextInt(240000) - 120000, rng.nextDouble() * 100 - 50);
  final star = _Player(w, rng, seekMs: 80 + rng.nextInt(300), loadMs: 600);
  final lis = _Player(w, rng,
      seekMs: 60 + rng.nextInt(540), loadMs: 400 + rng.nextInt(2000));
  final starSync = ClockSync(), lisSync = ClockSync();
  final publisher = RoomPublisher();
  final follower = RoomFollower(lis);
  final lUp = listenerUp ?? up, lDown = listenerDown ?? down;

  void readClock(ClockSync sync, _Clock clock, _Net u, _Net d) {
    final before = clock.now;
    final upMs = u.delay(), downMs = d.delay();
    final serverAt = w.t + upMs;
    final after = (clock.now + upMs + downMs);
    sync.add(before, serverAt, after);
  }

  // The star's messages in flight to the listener: (arrives at, play).
  final inFlight = <(int, RoomPlay)>[];
  var lastArrival = 0;
  RoomPlay? latest;

  star.id = _songA.videoId;
  star.isPlaying = true;
  final r = _Result();
  // Quiet periods to measure: from 10 s after a disturbance.
  var quietFrom = 10000;
  void disturb() {
    quietFrom = w.t + 10000;
    r.events++;
  }

  final starPhase = rng.nextInt(50) * 10, lisPhase = rng.nextInt(50) * 10;
  for (var i = 0; i < 8; i++) {
    readClock(starSync, starClock, up, down);
    readClock(lisSync, lisClock, lUp, lDown);
  }

  const dt = 10;
  for (w.t = 0; w.t < seconds * 1000; w.t += dt) {
    star.advance(dt);
    lis.advance(dt);
    if (w.t % 30000 == 0 && w.t > 0) {
      readClock(starSync, starClock, up, down);
      readClock(lisSync, lisClock, lUp, lDown);
    }
    // The star's script.
    if (script) {
      switch (w.t) {
        case 30000: // seeks ahead
          star.seek(Duration(milliseconds: star.pos.round() + 40000));
          disturb();
        case 50000: // pauses for 4 s
          star.pause();
          disturb();
        case 54000:
          star.play();
          disturb();
        case 75000: // the star's phone stalls (buffering)
          star.stall(1200);
          disturb();
        case 95000: // a new song
          star.load(_songB);
          disturb();
        case 125000: // the listener's phone stalls
          lis.stall(900);
          disturb();
      }
    }
    // The star sends (every 500 ms it checks).
    if ((w.t + starPhase) % 500 == 0) {
      final id = star.id ?? '';
      final pos = star.position;
      final now = starClock.now;
      if (publisher.due(id, star.playing, pos, now)) {
        publisher.sent(id, star.playing, pos, now);
        final play = RoomPlay(star.id == _songB.videoId ? _songB : _songA,
            pos.inMilliseconds, star.playing, starSync.serverNow(now));
        var arrives = w.t + up.delay() + lDown.delay();
        arrives = max(arrives, lastArrival); // the store keeps the order
        lastArrival = arrives;
        inFlight.add((arrives, play));
      }
    }
    while (inFlight.isNotEmpty && inFlight.first.$1 <= w.t) {
      latest = inFlight.removeAt(0).$2;
    }
    // The listener follows (every 500 ms).
    if ((w.t + lisPhase) % 500 == 0) {
      follower.tick(latest,
          serverNow: lisSync.serverNow(lisClock.now),
          nowMs: lisClock.now,
          clockRtt: lisSync.rtt);
    }
    // Measure the true gap in quiet periods, while both play one song.
    if (w.t >= quietFrom &&
        w.t % 100 == 0 &&
        star.playing &&
        lis.playing &&
        star.id == lis.id &&
        w.t >= star.frozenUntil &&
        w.t >= lis.frozenUntil) {
      r.gaps.add((lis.pos - star.pos).round());
    }
  }
  r.seeks = follower.seeks;
  return r;
}

void main() {
  group('room sync, simulated', () {
    test('Wi-Fi (15–60 ms each way): within ~40 ms, few seeks', () {
      final all = _Result();
      for (var seed = 0; seed < 80; seed++) {
        final rng = Random(seed * 7 + 1);
        final r =
            simulate(seed, up: _Net(rng, 15, 60), down: _Net(rng, 15, 60));
        all.gaps.addAll(r.gaps);
        all.seeks += r.seeks;
        all.events += r.events;
        expect(r.pct(.95), lessThan(60), reason: 'seed $seed: ${r.describe()}');
        // A seek per jump the star makes, a few more to learn the lead.
        expect(r.seeks, lessThanOrEqualTo(r.events * 2 + 4),
            reason: 'seed $seed: ${r.describe()}');
      }
      // ignore: avoid_print
      print('Wi-Fi: ${all.describe()}');
      expect(all.pct(.5), lessThan(20));
      expect(all.pct(.95), lessThan(45));
    });

    test('mobile data (40–250 ms, 5 % slow spikes): within ~80 ms', () {
      final all = _Result();
      for (var seed = 100; seed < 180; seed++) {
        final rng = Random(seed * 7 + 1);
        final r = simulate(seed,
            up: _Net(rng, 40, 250, spikes: .05),
            down: _Net(rng, 40, 250, spikes: .05));
        all.gaps.addAll(r.gaps);
        all.seeks += r.seeks;
        all.events += r.events;
        expect(r.pct(.95), lessThan(120),
            reason: 'seed $seed: ${r.describe()}');
        expect(r.seeks, lessThanOrEqualTo(r.events * 2 + 5),
            reason: 'seed $seed: ${r.describe()}');
      }
      // ignore: avoid_print
      print('Mobile: ${all.describe()}');
      expect(all.pct(.5), lessThan(40));
      expect(all.pct(.95), lessThan(90));
    });

    test(
        'no disturbances: stays together for minutes, no seeks after the '
        'first', () {
      for (var seed = 200; seed < 230; seed++) {
        final rng = Random(seed);
        final r = simulate(seed,
            up: _Net(rng, 15, 80),
            down: _Net(rng, 15, 80),
            seconds: 300,
            script: false);
        expect(r.pct(.95), lessThan(45), reason: 'seed $seed: ${r.describe()}');
        expect(r.seeks, lessThanOrEqualTo(4),
            reason: 'seed $seed: ${r.describe()}');
      }
    });

    test(
        'a lopsided connection (fast up, slow down) costs at most half '
        'the difference', () {
      for (var seed = 300; seed < 320; seed++) {
        final rng = Random(seed);
        final r = simulate(seed,
            up: _Net(rng, 20, 40),
            down: _Net(rng, 20, 40),
            listenerUp: _Net(rng, 20, 40),
            listenerDown: _Net(rng, 220, 260));
        // The listener's clock reading is off by ~(240-30)/2 ≈ 105 ms: no
        // timing scheme can see that from one side.
        expect(r.pct(.5), lessThan(140), reason: 'seed $seed: ${r.describe()}');
      }
    });
  });
}
