import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noor/services/audio_cache.dart';
import 'package:noor/services/audio_quality.dart';
import 'package:noor/services/resolved_stream.dart';
import 'package:noor/services/song_acquirer.dart';
import 'package:noor/services/stream_resolver.dart';

AudioOption o(int kbps, String mime, {bool drc = false}) =>
    AudioOption(bitrate: kbps * 1000, mimeType: mime, drc: drc);

const aac = 'audio/mp4', opus = 'audio/webm';

/// YouTube's usual free versions.
final youtube = [
  o(48, aac),
  o(128, aac),
  o(50, opus),
  o(70, opus),
  o(160, opus)
];

int pick(List<AudioOption> all, AudioTier t) =>
    pickOption(all, (x) => x, t)!.kbps;

void main() {
  group('choosing a song\'s version', () {
    test('High: the best (Opus 160); Normal: ~70; Low: the smallest', () {
      expect(pick(youtube, AudioTier.high), 160);
      expect(pickOption(youtube, (x) => x, AudioTier.high)!.isOpus, isTrue);
      expect(pick(youtube, AudioTier.normal), 70);
      expect(pick(youtube, AudioTier.low), 48);
    });

    test('no Opus: AAC 128 for High', () {
      expect(pick([o(48, aac), o(128, aac)], AudioTier.high), 128);
      expect(pick([o(48, aac), o(128, aac)], AudioTier.normal), 48);
    });

    test('"stable volume" versions are skipped when a normal one exists', () {
      final all = [o(160, opus, drc: true), o(130, opus), o(48, aac)];
      expect(pick(all, AudioTier.high), 130);
      // Only DRC versions: still plays.
      expect(pick([o(160, opus, drc: true)], AudioTier.high), 160);
      expect(
          isDrcUrl(Uri.parse('https://x/videoplayback?xtags=drc%3D1&itag=251')),
          isTrue);
      expect(isDrcUrl(Uri.parse('https://x/videoplayback?itag=251')), isFalse);
    });

    test('same bitrate: Opus wins', () {
      expect(
          pickOption([o(128, aac), o(128, opus)], (x) => x, AudioTier.high)!
              .isOpus,
          isTrue);
    });

    test('a resolved song keeps every version and picks per tier', () {
      ResolvedStream v(int kbps, String mime) => ResolvedStream(
          url: Uri.parse('https://x/$kbps'),
          totalBytes: kbps * 1000,
          mimeType: mime,
          open: () => const Stream.empty(),
          bitrate: kbps * 1000);
      final song = v(160, opus).choose(AudioTier.high);
      final withAll = ResolvedStream(
        url: song.url,
        totalBytes: song.totalBytes,
        mimeType: song.mimeType,
        open: song.open,
        bitrate: song.bitrate,
        alternatives: [v(48, aac), v(70, opus)],
      );
      expect(withAll.choose(AudioTier.high).kbps, 160);
      final low = withAll.choose(AudioTier.low);
      expect(low.kbps, 48);
      // Choosing again from the chosen one still sees every version.
      expect(low.choose(AudioTier.high).kbps, 160);
      expect(withAll.choose(AudioTier.normal).kbps, 70);
    });

    test('labels', () {
      expect(qualityName(160), 'High');
      expect(qualityName(128), 'High');
      expect(qualityName(70), 'Normal');
      expect(qualityName(48), 'Low');
    });
  });

  group('Auto', () {
    AudioTier auto({bool wifi = false, bool saver = false, double? mbps}) =>
        tierFor(
            SoundQuality.auto,
            NetworkState(
                wifi: wifi,
                dataSaver: saver,
                speedBps: mbps == null ? null : mbps * 1e6));

    test('High on Wi-Fi and on good mobile data', () {
      expect(auto(wifi: true), AudioTier.high);
      expect(auto(), AudioTier.high); // nothing measured yet
      expect(auto(mbps: 12), AudioTier.high);
    });

    test('lower on a slow network or with Data Saver', () {
      expect(auto(mbps: 0.6), AudioTier.normal);
      expect(auto(saver: true, mbps: 20), AudioTier.normal);
      expect(auto(mbps: 0.2), AudioTier.low);
      expect(auto(wifi: true, mbps: 0.2), AudioTier.low); // a broken Wi-Fi
      expect(auto(wifi: true, mbps: 0.6), AudioTier.high);
    });

    test('High and Low ignore the network', () {
      const slow = NetworkState(speedBps: 1000);
      expect(tierFor(SoundQuality.high, slow), AudioTier.high);
      expect(tierFor(SoundQuality.low, const NetworkState(wifi: true)),
          AudioTier.low);
    });

    test('the speed is the average of the last three songs', () {
      final m = SpeedMeter();
      expect(m.bitsPerSecond, isNull);
      m.record(1000, const Duration(seconds: 1)); // too small to count
      expect(m.bitsPerSecond, isNull);
      for (final mbps in [1, 2, 3, 4]) {
        m.record(4 * 1000000 * mbps ~/ 8, const Duration(seconds: 4));
      }
      expect(m.bitsPerSecond! / 1e6, closeTo(3, 0.01)); // 2, 3, 4
    });
  });

  group('saved songs', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('noor_q'));
    tearDown(() async => dir.delete(recursive: true));

    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 200));

    test('each saved song remembers its version; older ones count as Low',
        () async {
      final c = AudioCache(Directory('${dir.path}/c'));
      expect(c.maxBytes, 1024 * 1024 * 1024);
      await c.init();
      await c.put('aaaaaaaaaaa', bytes(5000), kbps: 160);
      await c.put('bbbbbbbbbbb', bytes(5000), kbps: 48);
      await c.put('ccccccccccc', bytes(5000)); // an older Noor's copy
      await c.flush();

      final again = AudioCache(Directory('${dir.path}/c'));
      await again.init();
      expect(again.kbpsOf('aaaaaaaaaaa'), 160);
      expect(again.kbpsOf('bbbbbbbbbbb'), 48);
      expect(again.kbpsOf('ccccccccccc'), 0);
      expect(again.belowKbps(110).toSet(), {'bbbbbbbbbbb', 'ccccccccccc'});
      // Favourites first; a song with nothing better is left alone.
      expect(again.belowKbps(110, first: {'ccccccccccc'}).first, 'ccccccccccc');
      again.markBest('bbbbbbbbbbb');
      expect(again.belowKbps(110), ['ccccccccccc']);
    });
  });

  group('downloads', () {
    late Directory dir;
    late AudioCache cache;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('noor_dl');
      cache = AudioCache(Directory('${dir.path}/c'));
      await cache.init();
    });
    tearDown(() async => dir.delete(recursive: true));

    const id = 'dQw4w9WgXcQ';
    const lowSize = 20000, highSize = 400000;
    Uint8List data(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 251));

    /// [high] feeds the High version, chunk by chunk, when the test says so.
    SongAcquirer make(StreamController<List<int>> high,
        {bool highExists = true}) {
      ResolvedStream v(int kbps, int size, Stream<List<int>> Function() open) =>
          ResolvedStream(
              url: Uri.parse(
                  'https://rr1.googlevideo.com/videoplayback?k=$kbps'),
              totalBytes: size,
              mimeType: 'audio/webm',
              open: open,
              bitrate: kbps * 1000);
      final resolver = StreamResolver<ResolvedStream>(
        timeouts: const [Duration(seconds: 5)],
        minGap: Duration.zero,
        fetch: (_, __) async {
          final low = v(50, lowSize, () => Stream.value(data(lowSize)));
          if (!highExists) return low;
          final top = v(160, highSize, () => high.stream);
          return ResolvedStream(
            url: top.url,
            totalBytes: top.totalBytes,
            mimeType: top.mimeType,
            open: top.open,
            bitrate: top.bitrate,
            alternatives: [low],
          );
        },
      );
      return SongAcquirer(
        resolver: resolver,
        cache: () => cache,
        // The direct download is refused, so the library stream is used.
        httpClient: MockClient((_) async => http.Response('', 403)),
        stallTimeout: const Duration(seconds: 5),
      );
    }

    test(
        'plays while downloading: handed over after the first bytes, saved when done',
        () async {
      final high = StreamController<List<int>>();
      final a = make(high);
      final all = data(highSize);
      final got = a.acquire(id,
          superseded: Completer<void>().future,
          tier: AudioTier.high,
          whileDownloading: true);
      high.add(all.sublist(0, 150000)); // past the start threshold
      final song = await got;
      expect(song.download, isNotNull);
      expect(song.kbps, 160);
      expect(song.download!.isComplete, isFalse); // still downloading
      expect(cache.contains(id), isFalse);

      // The player reads ahead of the download: it waits, then gets it.
      final reading = song.download!.read(300000, 300010).toList();
      high.add(all.sublist(150000));
      await high.close();
      final part = (await reading).expand((x) => x).toList();
      expect(part, all.sublist(300000, 300010));

      await song.download!.completed;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cache.contains(id), isTrue);
      expect(cache.kbpsOf(id), 160);
    });

    test('Low picks the small version', () async {
      final a = make(StreamController<List<int>>());
      final song = await a.acquire(id,
          superseded: Completer<void>().future, tier: AudioTier.low);
      expect(song.kbps, 50);
      expect(cache.kbpsOf(id), 50);
    });

    test('a saved Low copy plays at once and is upgraded to High later',
        () async {
      final high = StreamController<List<int>>();
      final a = make(high);
      await a.acquire(id,
          superseded: Completer<void>().future, tier: AudioTier.low);
      final first = await a.acquire(id, superseded: Completer<void>().future);
      expect(first.fromCache, isTrue);
      expect(first.kbps, 50); // the saved copy, no waiting

      final up = a.upgrade(id);
      high.add(data(highSize));
      await high.close();
      expect(await up, isTrue);
      expect(cache.kbpsOf(id), 160);
      expect(cache.belowKbps(110), isEmpty);
    });

    test('a song with no better version is marked and left alone', () async {
      final a = make(StreamController<List<int>>(), highExists: false);
      await a.acquire(id,
          superseded: Completer<void>().future, tier: AudioTier.low);
      expect(await a.upgrade(id), isFalse);
      expect(cache.belowKbps(110), isEmpty);
    });
  });
}
