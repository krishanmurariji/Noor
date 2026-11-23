import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'audio_cache.dart';
import 'audio_quality.dart';
import 'http_range_download.dart';
import 'playback_failure.dart';
import 'progressive_download.dart';
import 'resolved_stream.dart';
import 'stream_resolver.dart';

/// The caller moved on (skipped, changed song): abandon quietly.
class AcquireSuperseded implements Exception {
  const AcquireSuperseded();
  @override
  String toString() => 'AcquireSuperseded';
}

/// No stream could be found for the video.
class ResolveFailure implements Exception {
  const ResolveFailure(this.kind);
  final FailureKind kind;
  @override
  String toString() => 'ResolveFailure($kind)';
}

/// A stream was found but could not be downloaded.
class DownloadFailure implements Exception {
  const DownloadFailure(this.client, this.cause);
  final int client;
  final Object cause;
  @override
  String toString() => 'DownloadFailure(client $client): $cause';
}

/// Where the player can get the song from: a local file (preferred) or, when
/// that is not possible, a URL it streams itself.
class AcquiredSong {
  const AcquiredSong.file(this.file, {this.fromCache = false, this.kbps = 0})
      : url = null,
        headers = const {},
        download = null,
        mimeType = '';
  const AcquiredSong.stream(this.url, {this.headers = const {}, this.kbps = 0})
      : file = null,
        fromCache = false,
        download = null,
        mimeType = '';

  /// Playing while it downloads: the player reads [download] as it arrives;
  /// the finished song goes into the cache by itself.
  const AcquiredSong.downloading(this.download,
      {required this.mimeType, this.kbps = 0})
      : file = null,
        url = null,
        headers = const {},
        fromCache = false;

  final File? file;
  final Uri? url;
  final Map<String, String> headers;
  final bool fromCache;
  final ProgressiveDownload? download;
  final String mimeType;

  /// The version's bitrate (0: unknown, e.g. saved by an older Noor).
  final int kbps;
}

/// Turns a video id into something playable, as reliably as possible:
///
///  1. the disk cache (instant, works offline);
///  2. resolve a stream, download the whole song (plain ranged request with the
///     right User-Agent first, the library's downloader as a fallback) and put
///     it in the cache;
///  3. if the song is too big or the disk cannot store it, hand the player the
///     URL to stream itself.
///
/// Every step can be abandoned the moment the caller moves on, and no failure
/// leaves a download running.
class SongAcquirer {
  SongAcquirer({
    required this.resolver,
    required this.cache,
    this.httpClient,
    this.stallTimeout = const Duration(seconds: 10),
    this.maxDownloadFirstBytes = 40 * 1024 * 1024,
    this.log,
  });

  final StreamResolver<ResolvedStream> resolver;

  /// Looked up on every call: the cache is created asynchronously at start-up
  /// and may never become available (no usable disk).
  final AudioCache? Function() cache;
  final http.Client? httpClient;
  final Duration stallTimeout;
  final int maxDownloadFirstBytes;
  final void Function(String message)? log;

  /// How fast recent songs downloaded (feeds the "Auto" quality).
  final SpeedMeter speed = SpeedMeter();

  /// With "play while downloading", playback starts once this much of the
  /// song has arrived (a second or two of audio).
  static const int kStartBytes = 96 * 1024;

  ProgressiveDownload? _active;
  ProgressiveDownload? _prefetch;

  /// A song is downloading now (playing one or a prefetch).
  bool get isBusy =>
      (_active != null &&
          !_active!.isComplete &&
          !_active!.isFailed &&
          !_active!.isCancelled) ||
      (_prefetch != null &&
          !_prefetch!.isComplete &&
          !_prefetch!.isFailed &&
          !_prefetch!.isCancelled);

  /// Stops the download for the song being loaded (the user moved on).
  void cancelActive() {
    _active?.cancel();
    _active = null;
  }

  /// Stops a background prefetch.
  void cancelPrefetch() {
    _prefetch?.cancel();
    _prefetch = null;
  }

  void cancelAll() {
    cancelActive();
    cancelPrefetch();
  }

  /// Completes when the current song's download has ended (either way).
  Future<void> activeSettled() async {
    final a = _active;
    if (a == null) return;
    await a.completed.then((_) {}, onError: (Object _) {});
  }

  ///
  /// [tier] picks the song's version. With [whileDownloading] the song is
  /// handed over once its first bytes arrive and plays as it downloads.
  Future<AcquiredSong> acquire(
    String videoId, {
    required Future<void> superseded,
    Set<String> protect = const {},
    AudioTier tier = AudioTier.high,
    bool whileDownloading = false,
  }) async {
    final store = cache();

    final cached = await store?.lookup(videoId);
    if (cached != null) {
      return AcquiredSong.file(cached,
          fromCache: true, kbps: store!.kbpsOf(videoId));
    }

    final res = await resolver.resolve(videoId, superseded: superseded);
    final found = res.value;
    if (found == null) {
      if (res.kind == FailureKind.cancelled) throw const AcquireSuperseded();
      throw ResolveFailure(res.kind);
    }
    final info = found.choose(tier);

    final canDownload = store != null &&
        info.totalBytes > 0 &&
        info.totalBytes <= maxDownloadFirstBytes;
    if (!canDownload) {
      log?.call('streaming directly from URL');
      return _stream(info);
    }

    log?.call('downloading ${info.totalBytes} bytes (${info.kbps} kbps) '
        'via ${info.origin} (client ${info.clientIndex})');
    if (whileDownloading) {
      final dl = await _startPlayable(info, superseded);
      final clock = Stopwatch()..start();
      unawaited(dl.completed.then((bytes) async {
        speed.record(bytes.length, clock.elapsed);
        await store.put(videoId, bytes, protect: protect, kbps: info.kbps);
        log?.call('saved: ${bytes.length} bytes');
      }, onError: (Object _) {}));
      return AcquiredSong.downloading(dl,
          mimeType: info.mimeType, kbps: info.kbps);
    }
    final clock = Stopwatch()..start();
    final bytes = await _downloadBytes(info, superseded, prefetch: false);
    speed.record(bytes.length, clock.elapsed);

    await store.put(videoId, bytes, protect: protect, kbps: info.kbps);
    final stored = await store.lookup(videoId);
    if (stored != null) {
      log?.call('ready: ${bytes.length} bytes');
      return AcquiredSong.file(stored, kbps: info.kbps);
    }
    // Disk full / unwritable: the download was fine, so do NOT blame the
    // client. Let the player stream the URL instead.
    log?.call('could not store the song on disk; streaming from URL');
    return _stream(info);
  }

  /// Downloads [videoId] into the cache in the background. Returns true when
  /// the song is (now) cached. Never throws; cancelled by [cancelPrefetch].
  Future<bool> prefetch(String videoId,
      {Set<String> protect = const {}, AudioTier tier = AudioTier.high}) async {
    final store = cache();
    if (store == null) return false;
    if (store.contains(videoId)) return true;
    try {
      final res = await resolver.resolve(videoId);
      final info = res.value?.choose(tier);
      if (info == null ||
          info.totalBytes <= 0 ||
          info.totalBytes > maxDownloadFirstBytes) {
        return false;
      }
      final clock = Stopwatch()..start();
      final bytes =
          await _downloadBytes(info, Completer<void>().future, prefetch: true);
      speed.record(bytes.length, clock.elapsed);
      await store.put(videoId, bytes, protect: protect, kbps: info.kbps);
      return store.contains(videoId);
    } catch (e) {
      log?.call('prefetch skipped: $e');
      return false;
    }
  }

  /// Replaces the saved copy of [videoId] with its best version, when that
  /// is clearly better (Wi-Fi upgrades). Returns true when upgraded. Never
  /// throws; cancelled by [cancelPrefetch]. The song must not be playing
  /// (pass it in [protect] and skip it).
  Future<bool> upgrade(String videoId, {Set<String> protect = const {}}) async {
    final store = cache();
    if (store == null || !store.contains(videoId)) return false;
    try {
      final res = await resolver.resolve(videoId);
      final info = res.value?.choose(AudioTier.high);
      if (info == null) return false;
      final have = store.kbpsOf(videoId);
      if (info.kbps <= have + 10 ||
          info.totalBytes <= 0 ||
          info.totalBytes > maxDownloadFirstBytes) {
        store.markBest(videoId); // nothing better to get
        return false;
      }
      final clock = Stopwatch()..start();
      final bytes =
          await _downloadBytes(info, Completer<void>().future, prefetch: true);
      speed.record(bytes.length, clock.elapsed);
      await store.put(videoId, bytes, protect: protect, kbps: info.kbps);
      log?.call('upgraded $videoId: $have → ${info.kbps} kbps');
      return store.kbpsOf(videoId) == info.kbps;
    } catch (e) {
      log?.call('upgrade skipped: $e');
      return false;
    }
  }

  /// Starts downloading [info] and returns once its first bytes have
  /// arrived, so the player can start while the rest comes in. Same two
  /// strategies as [_downloadBytes]; a failure before playback starts is a
  /// [DownloadFailure].
  Future<ProgressiveDownload> _startPlayable(
      ResolvedStream info, Future<void> superseded) async {
    Object? directError;
    for (final direct in [true, false]) {
      final dl = ProgressiveDownload(
        open: direct
            ? () => openRangedDownload(info.url, info.totalBytes,
                userAgent: info.userAgent, client: httpClient)
            : info.open,
        totalBytes: info.totalBytes,
        stallTimeout: stallTimeout,
      );
      _active = dl;
      dl.start();
      try {
        await Future.any<void>([
          dl.receivedAtLeast(kStartBytes),
          superseded.then<void>((_) => throw const AcquireSuperseded()),
        ]);
        return dl;
      } catch (e) {
        final wasCancelled = dl.isCancelled;
        dl.cancel();
        if (e is AcquireSuperseded || wasCancelled) {
          throw const AcquireSuperseded();
        }
        if (direct) {
          directError = e;
          log?.call('direct download failed: $e');
        } else {
          log?.call('library download failed: $e');
          throw DownloadFailure(
              info.clientIndex, 'direct: $directError; library: $e');
        }
      }
    }
    throw StateError('unreachable');
  }

  AcquiredSong _stream(ResolvedStream info) => AcquiredSong.stream(
        info.url,
        headers:
            info.userAgent == null ? const {} : {'User-Agent': info.userAgent!},
      );

  /// Two strategies, in order. Throws [AcquireSuperseded] or [DownloadFailure].
  Future<Uint8List> _downloadBytes(ResolvedStream info, Future<void> superseded,
      {required bool prefetch}) async {
    Object? directError;
    try {
      return await _download(
        () => openRangedDownload(info.url, info.totalBytes,
            userAgent: info.userAgent, client: httpClient),
        info.totalBytes,
        superseded,
        prefetch: prefetch,
      );
    } on AcquireSuperseded {
      rethrow;
    } catch (e) {
      directError = e;
      log?.call('direct download failed: $e');
    }
    try {
      return await _download(info.open, info.totalBytes, superseded,
          prefetch: prefetch);
    } on AcquireSuperseded {
      rethrow;
    } catch (e) {
      log?.call('library download failed: $e');
      throw DownloadFailure(
          info.clientIndex, 'direct: $directError; library: $e');
    }
  }

  Future<Uint8List> _download(
    Stream<List<int>> Function() open,
    int total,
    Future<void> superseded, {
    required bool prefetch,
  }) async {
    final dl = ProgressiveDownload(
      open: open,
      totalBytes: total,
      stallTimeout: stallTimeout,
    );
    if (prefetch) {
      _prefetch = dl;
    } else {
      _active = dl;
    }
    dl.start();
    try {
      return await Future.any<Uint8List>([
        dl.completed,
        superseded.then<Uint8List>((_) => throw const AcquireSuperseded()),
      ]);
    } catch (e) {
      final wasCancelled = dl.isCancelled;
      dl.cancel();
      if (e is AcquireSuperseded || wasCancelled) {
        throw const AcquireSuperseded();
      }
      rethrow;
    }
  }
}
