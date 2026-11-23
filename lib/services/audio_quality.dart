/// Song quality: what the user chose, the version picked for each song, and
/// the "Auto" rules.
///
/// Quality is decided once per song, when its download starts: a song always
/// plays from start to finish in one version (YouTube's versions are separate
/// files, and Noor plays one file per song).
library;

/// The user's setting.
enum SoundQuality { auto, high, low }

/// The version actually asked for, for one song.
enum AudioTier { low, normal, high }

extension SoundQualityText on SoundQuality {
  String get label => switch (this) {
        SoundQuality.auto => 'Auto',
        SoundQuality.high => 'High',
        SoundQuality.low => 'Low',
      };

  /// One line for Settings.
  String get detail => switch (this) {
        SoundQuality.auto =>
          'High on Wi-Fi and good mobile data, lower on a slow network',
        SoundQuality.high => 'Best available · about 70 MB per hour',
        SoundQuality.low => 'Saves data · about 22 MB per hour',
      };
}

/// What a song's version is called on the player, from its bitrate.
String qualityName(int kbps) {
  if (kbps >= 110) return 'High';
  if (kbps >= 60) return 'Normal';
  return 'Low';
}

/// The tier a saved song is in, from its bitrate (0: unknown, saved by an
/// older Noor, which always chose the lowest version).
AudioTier tierOfKbps(int kbps) {
  if (kbps >= 110) return AudioTier.high;
  if (kbps >= 60) return AudioTier.normal;
  return AudioTier.low;
}

/// One downloadable version of a song.
class AudioOption {
  const AudioOption({
    required this.bitrate,
    required this.mimeType,
    this.drc = false,
  });

  /// Bits per second.
  final int bitrate;
  final String mimeType;

  /// A "stable volume" version with its dynamic range squashed. Never
  /// chosen when a normal version exists.
  final bool drc;

  int get kbps => (bitrate / 1000).round();
  bool get isOpus => mimeType.contains('webm') || mimeType.contains('opus');
}

/// Whether a YouTube media URL is a "stable volume" (DRC) version.
bool isDrcUrl(Uri url) {
  final x = url.queryParameters['xtags'] ?? '';
  return x.contains('drc=1') || url.queryParameters['drc'] == '1';
}

/// Picks the version of a song for [tier]:
///
///  * high:   the best version (Opus ~160 kbps, else AAC 128 kbps);
///  * normal: the best version up to ~100 kbps (Opus ~70 kbps);
///  * low:    the smallest version.
///
/// "Stable volume" versions are skipped whenever a normal one exists. At
/// equal bitrate Opus wins: it sounds better than AAC at the same size.
T? pickOption<T extends Object>(
    List<T> all, AudioOption Function(T) info, AudioTier tier) {
  if (all.isEmpty) return null;
  final plain = all.where((o) => !info(o).drc).toList();
  final pool = plain.isEmpty ? all : plain;

  int better(T a, T b) {
    final x = info(a), y = info(b);
    final byRate = x.bitrate.compareTo(y.bitrate);
    if (byRate != 0) return byRate;
    return (x.isOpus ? 1 : 0).compareTo(y.isOpus ? 1 : 0);
  }

  final sorted = [...pool]..sort(better); // worst → best
  switch (tier) {
    case AudioTier.high:
      return sorted.last;
    case AudioTier.low:
      return sorted.first;
    case AudioTier.normal:
      final upTo = sorted.where((o) => info(o).bitrate <= 100000).toList();
      return upTo.isEmpty ? sorted.first : upTo.last;
  }
}

/// What Noor knows about the network right now.
class NetworkState {
  const NetworkState({
    this.wifi = false,
    this.dataSaver = false,
    this.speedBps,
  });

  /// Wi-Fi or ethernet (not metered).
  final bool wifi;

  /// Android's Data Saver is on.
  final bool dataSaver;

  /// Measured download speed of recent songs, bits per second (null: none
  /// measured yet).
  final double? speedBps;
}

/// The "Auto" rules, and the fixed settings.
AudioTier tierFor(SoundQuality q, NetworkState net) {
  switch (q) {
    case SoundQuality.high:
      return AudioTier.high;
    case SoundQuality.low:
      return AudioTier.low;
    case SoundQuality.auto:
      final speed = net.speedBps;
      // A really poor connection: smallest version, on any network.
      if (speed != null && speed < 300000) return AudioTier.low;
      if (net.wifi) return AudioTier.high;
      if (net.dataSaver) return AudioTier.normal;
      if (speed != null && speed < 1000000) return AudioTier.normal;
      return AudioTier.high;
  }
}

/// Measures how fast songs download (the honest measure of the network,
/// better than signal bars). Keeps the last few downloads.
class SpeedMeter {
  final List<double> _recent = [];

  /// Records a finished download. Tiny downloads say little; ignored.
  void record(int bytes, Duration took) {
    if (bytes < 256 * 1024 || took.inMilliseconds <= 0) return;
    _recent.add(bytes * 8 * 1000 / took.inMilliseconds);
    if (_recent.length > 3) _recent.removeAt(0);
  }

  /// Average of the recent downloads, bits per second; null when none.
  double? get bitsPerSecond =>
      _recent.isEmpty ? null : _recent.reduce((a, b) => a + b) / _recent.length;
}
