import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import 'library_provider.dart';

/// The list a song "belongs to": what plays next, what swiping the record
/// reaches, and what Up next shows. In priority order:
///  1. the playlist that contains it (a song lives in at most one playlist);
///  2. My Favorites (liked songs);
///  3. My Music, for a file on the phone ([onDevice]);
///  4. My History (recently played). A song that is not there yet (just
///     found by search) is put first, as playing it puts it there;
///  5. otherwise just the song itself.
/// A list of one song repeats it; it never moves on to another list.
List<Song> contextListFor(
  Song song, {
  required List<Playlist> playlists,
  required List<Song> liked,
  required List<Song> history,
  List<Song> onDevice = const [],
}) {
  bool has(List<Song> l) => l.any((s) => s.videoId == song.videoId);
  for (final p in playlists) {
    if (has(p.songs)) return p.songs;
  }
  if (has(liked)) return liked;
  if (song.isLocal && has(onDevice)) return onDevice;
  final seen = <String>{};
  final distinct = history.where((s) => seen.add(s.videoId)).toList();
  if (has(distinct)) return distinct;
  return [song, ...distinct];
}

/// The song before ([step] = -1) or after ([step] = 1) [song] in its context
/// list, wrapping around at the ends. With nothing else in the list the same
/// song is returned (it plays again).
Song neighbourOf(
  Song song,
  int step, {
  required List<Playlist> playlists,
  required List<Song> liked,
  required List<Song> history,
  List<Song> onDevice = const [],
}) {
  final list = contextListFor(song,
      playlists: playlists, liked: liked, history: history, onDevice: onDevice);
  final i = list.indexWhere((s) => s.videoId == song.videoId);
  if (i < 0 || list.length < 2) return song;
  final n = list.length;
  return list[((i + step) % n + n) % n];
}

/// The name of the list [contextListFor] picks: the playlist's name,
/// "My Favorites", or "My History" (also when the song is alone).
String contextTitleFor(
  Song song, {
  required List<Playlist> playlists,
  required List<Song> liked,
  required List<Song> history,
  List<Song> onDevice = const [],
}) {
  bool has(List<Song> l) => l.any((s) => s.videoId == song.videoId);
  for (final p in playlists) {
    if (has(p.songs)) return p.name;
  }
  if (has(liked)) return 'My Favorites';
  if (song.isLocal && has(onDevice)) return 'My Music';
  return 'My History';
}

/// Which list [contextListFor] picks for [song], as a kind and (for a
/// playlist) its id, so Up next can rearrange that very list.
({String kind, String? playlistId}) contextSourceFor(
  Song song, {
  required List<Playlist> playlists,
  required List<Song> liked,
  List<Song> onDevice = const [],
}) {
  bool has(List<Song> l) => l.any((s) => s.videoId == song.videoId);
  for (final p in playlists) {
    if (has(p.songs)) return (kind: 'playlist', playlistId: p.id);
  }
  if (has(liked)) return (kind: 'liked', playlistId: null);
  if (song.isLocal && has(onDevice)) return (kind: 'music', playlistId: null);
  return (kind: 'history', playlistId: null);
}

/// The queue to play [song] in, by the rule of [contextListFor], from the
/// library as it is now. Use it wherever a song is started, so a song
/// always plays on through its own list, whichever card or search it was
/// tapped in.
final playQueueProvider = Provider<List<Song> Function(Song)>((ref) {
  final playlists = ref.watch(playlistProvider);
  final liked = ref.watch(likedSongsProvider);
  final history = ref.watch(historyProvider);
  final onDevice = ref.watch(myMusicProvider);
  return (song) => contextListFor(song,
      playlists: playlists, liked: liked, history: history, onDevice: onDevice);
});
