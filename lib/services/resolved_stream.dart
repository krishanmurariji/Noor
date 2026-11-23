import 'audio_quality.dart';

/// Everything the player needs to start a song, independent of where the
/// stream came from (YouTube directly, or a backup instance).
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.totalBytes,
    required this.mimeType,
    required this.open,
    this.origin = 'youtube',
    this.clientIndex = -1,
    this.userAgent,
    this.bitrate = 0,
    this.drc = false,
    this.alternatives = const [],
  });

  /// Bits per second of this version (0: unknown).
  final int bitrate;

  /// A "stable volume" version (dynamic range squashed).
  final bool drc;

  /// The song's other versions (other bitrates / formats), so the version
  /// can be chosen per song without asking YouTube again.
  final List<ResolvedStream> alternatives;

  int get kbps => (bitrate / 1000).round();

  AudioOption get option =>
      AudioOption(bitrate: bitrate, mimeType: mimeType, drc: drc);

  /// The version for [tier] among this one and its [alternatives].
  ResolvedStream choose(AudioTier tier) {
    final all = [this, ...alternatives];
    final picked = pickOption<ResolvedStream>(all, (s) => s.option, tier)!;
    if (identical(picked, this)) return this;
    return picked._with(alternatives: [
      for (final s in all)
        if (!identical(s, picked)) s._with(alternatives: const [])
    ]);
  }

  ResolvedStream _with(
          {List<ResolvedStream>? alternatives, int? clientIndex}) =>
      ResolvedStream(
        url: url,
        totalBytes: totalBytes,
        mimeType: mimeType,
        open: open,
        origin: origin,
        clientIndex: clientIndex ?? this.clientIndex,
        userAgent: userAgent,
        bitrate: bitrate,
        drc: drc,
        alternatives: alternatives ?? this.alternatives,
      );

  /// Direct URL (used by the raw-URL fallback source).
  final Uri url;
  final int totalBytes;
  final String mimeType;

  /// Opens a fresh byte stream of the whole file (chunking/retries included).
  final Stream<List<int>> Function() open;

  /// For logs: 'youtube' or the backup instance host.
  final String origin;

  /// Which resolver client produced this stream (-1 = unknown). Lets the
  /// player penalize a client whose streams cannot actually be downloaded.
  final int clientIndex;

  /// The User-Agent the media server expects for this URL (the client it was
  /// issued to), or null when unknown.
  final String? userAgent;

  ResolvedStream withClient(int index) => _with(
      clientIndex: index,
      alternatives: [for (final a in alternatives) a.withClient(index)]);
}
