// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'progressive_download.dart';

/// Plays a song while it downloads: the player asks for byte ranges and gets
/// them as soon as they have arrived (seeking ahead simply waits for the
/// download to get there).
///
/// When the download is cancelled because the user moved on, the stream just
/// ends quietly, so a song being replaced never reports an error.
class DownloadAudioSource extends StreamAudioSource {
  DownloadAudioSource(this.download, {required this.mimeType, super.tag});

  final ProgressiveDownload download;
  final String mimeType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final total = download.totalBytes;
    final from = (start ?? 0).clamp(0, total);
    final to = (end ?? total).clamp(from, total);
    return StreamAudioResponse(
      sourceLength: total,
      contentLength: to - from,
      offset: from,
      contentType: mimeType.split(';').first.trim(),
      stream: _read(from, to),
    );
  }

  Stream<List<int>> _read(int from, int to) async* {
    try {
      yield* download.read(from, to);
    } catch (e) {
      if (download.isCancelled) return; // moved on: end quietly
      rethrow;
    }
  }
}
