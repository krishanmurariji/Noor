import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:noor/models/song.dart';
import 'package:noor/services/rooms/firebase_room_store.dart';
import 'package:noor/services/rooms/room.dart';
import 'package:noor/services/rooms/room_sync.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers.dart';

// Room sync on a real Android audio stack, through the real Firebase
// project: two players in one app, one the star and one a listener in its
// room, each with its own sign-in. Both run on this device's clock, so the
// gap between them is measured directly (what the phones actually play),
// while the star seeks, pauses and plays.

const _song = Song(
    videoId: 'synctone001', title: 'Sync tone', artist: '', thumbnailUrl: '');

/// A 3-minute WAV (a quiet tone that changes every second, so every
/// position sounds different).
Future<String> _toneFile() async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/sync_tone.wav');
  const rate = 22050, seconds = 180;
  const n = rate * seconds;
  final data = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final hz = 300 + (i ~/ rate % 7) * 60;
    data.setInt16(44 + i * 2, (sin(2 * pi * hz * i / rate) * 3000).round(),
        Endian.little);
  }
  await f.writeAsBytes(data.buffer.asUint8List());
  return f.path;
}

/// A just_audio player as the room follower sees it.
class _Follow implements FollowPlayer {
  _Follow(this.p, this.path);
  final AudioPlayer p;
  final String path;
  String? id;

  @override
  String? get songId => id;
  @override
  Duration get position => p.position;
  @override
  bool get playing => p.playing && p.processingState == ProcessingState.ready;
  @override
  bool get loading =>
      p.processingState == ProcessingState.loading ||
      p.processingState == ProcessingState.buffering;
  @override
  void load(Song song) {
    id = song.videoId;
    unawaited(p.setFilePath(path).then((_) => p.play()));
  }

  @override
  void seek(Duration to) => unawaited(p.seek(to));
  @override
  void play() => unawaited(p.play());
  @override
  void pause() => unawaited(p.pause());
  @override
  void setSpeed(double speed) => unawaited(p.setSpeed(speed));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a listener plays in step with the star', (t) async {
    const config = RoomConfig.fromBuild;
    if (!config.ready) {
      report('room sync: SKIPPED (no Firebase settings in this build)');
      return;
    }
    await t.runAsync(() async {
      final path = await _toneFile();
      AudioPlayer make() => AudioPlayer(
          handleInterruptions: false, handleAudioSessionActivation: false);
      final starP = make(), lisP = make();
      final star =
          RoomController(FirebaseRoomStore(config, prefsKey: 'e2e_star'));
      final lis =
          RoomController(FirebaseRoomStore(config, prefsKey: 'e2e_lis'));
      final follower = RoomFollower(_Follow(lisP, path), log: report);
      final publisher = RoomPublisher();
      Timer? starTick, lisTick;
      try {
        final code = await star.start('Star');
        expect(await lis.knock(code, 'Listener'), isNull);
        for (var i = 0;
            i < 40 && star.state.room?.knocks.isEmpty != false;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await star.letIn(star.state.room!.knocks.single);
        for (var i = 0; i < 40 && !lis.state.isListener; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(lis.state.isListener, isTrue, reason: 'the listener got in');
        report(
            'room sync: room $code, star clock ±${(star.clockRtt ?? 0) ~/ 2}ms, '
            'listener clock ±${(lis.clockRtt ?? 0) ~/ 2}ms');

        await starP.setFilePath(path);
        unawaited(starP.play());
        int now() => DateTime.now().millisecondsSinceEpoch;
        starTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
          final playing =
              starP.playing && starP.processingState == ProcessingState.ready;
          final pos = starP.position;
          if (!publisher.due(_song.videoId, playing, pos, now())) return;
          publisher.sent(_song.videoId, playing, pos, now());
          unawaited(star
              .publishPlay(_song, pos, playing,
                  at: star.clockReady ? star.serverNow() : null)
              .catchError((Object e) => publisher.failed()));
        });
        lisTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
          follower.tick(lis.state.room?.play,
              serverNow: lis.serverNow(), nowMs: now(), clockRtt: lis.clockRtt);
        });

        /// The gap (listener − star) every 100 ms for [s] seconds.
        Future<List<int>> measure(String what, int s) async {
          final gaps = <int>[];
          for (var i = 0; i < s * 10; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            if (starP.playing && lisP.playing) {
              gaps.add((lisP.position - starP.position).inMilliseconds);
            }
          }
          final a = gaps.map((g) => g.abs()).toList()..sort();
          if (a.isEmpty) {
            report('room sync: $what: no samples');
          } else {
            report('room sync: $what: median ${a[a.length ~/ 2]} ms, '
                'p95 ${a[(a.length * .95).floor().clamp(0, a.length - 1)]} ms, '
                'max ${a.last} ms (${a.length} samples, '
                '${follower.seeks} seeks, lead ${follower.leadMs} ms)');
          }
          return a;
        }

        await Future<void>.delayed(const Duration(seconds: 12));
        final start = await measure('joined', 10);

        await starP.seek(starP.position + const Duration(seconds: 40));
        await Future<void>.delayed(const Duration(seconds: 12));
        final afterSeek = await measure('after the star seeks', 10);

        await starP.pause();
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(lisP.playing, isFalse, reason: 'the listener paused too');
        unawaited(starP.play());
        await Future<void>.delayed(const Duration(seconds: 12));
        final afterPause = await measure('after pause and play', 10);

        expect(lisP.position.inSeconds, greaterThan(40),
            reason: 'the listener really played');
        for (final (name, a) in [
          ('joined', start),
          ('after the star seeks', afterSeek),
          ('after pause and play', afterPause),
        ]) {
          expect(a.length, greaterThan(50), reason: '$name: both playing');
          expect(a[(a.length * .95).floor()], lessThan(120),
              reason: '$name: 95 % of the time within 120 ms');
        }
      } finally {
        starTick?.cancel();
        lisTick?.cancel();
        await lis.leave();
        await star.leave();
        lis.dispose();
        star.dispose();
        await starP.dispose();
        await lisP.dispose();
      }
    });
  });
}
