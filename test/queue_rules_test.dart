import 'package:flutter_test/flutter_test.dart';
import 'package:noor/models/song.dart';
import 'package:noor/providers/library_provider.dart';
import 'package:noor/providers/queue_rules.dart';

Song s(String id) => Song(
    videoId: id.padRight(11, 'x'), title: id, artist: 'a', thumbnailUrl: '');

void main() {
  final a = s('a'), b = s('b'), c = s('c'), d = s('d');

  test('a song in a playlist moves within that playlist first', () {
    final pls = [
      Playlist(id: 'p', name: 'P', songs: [a, b, c])
    ];
    expect(neighbourOf(b, 1, playlists: pls, liked: [d, b], history: []), c);
    expect(neighbourOf(b, -1, playlists: pls, liked: [d, b], history: []), a);
    expect(
        neighbourOf(c, 1, playlists: pls, liked: [], history: []), a); // wraps
  });

  test('otherwise liked songs, then history', () {
    expect(
        neighbourOf(b, 1, playlists: [], liked: [a, b, c], history: [d, b]), c);
    expect(
        neighbourOf(b, 1, playlists: [], liked: [], history: [d, b, b, a]), a);
  });

  test('nowhere else to go: the same song again', () {
    expect(neighbourOf(a, 1, playlists: [], liked: [], history: []), a);
    expect(neighbourOf(a, -1, playlists: [], liked: [a], history: [a]), a);
  });

  group('what plays next, wherever the song was tapped', () {
    final pls = [
      Playlist(id: 'p', name: 'P', songs: [a, b])
    ];

    test('playlist first, even when it is also liked and in history', () {
      expect(contextListFor(a, playlists: pls, liked: [c, a], history: [a, d]),
          [a, b]);
      expect(
          contextTitleFor(a, playlists: pls, liked: [c, a], history: [a]), 'P');
    });

    test('then My Favorites, then My History', () {
      expect(contextListFor(c, playlists: pls, liked: [c, d], history: [c]),
          [c, d]);
      expect(contextListFor(d, playlists: pls, liked: [c], history: [d, a, d]),
          [d, a]);
    });

    test('a song found by search leads the history it is about to join', () {
      final e = s('e');
      expect(contextListFor(e, playlists: pls, liked: [c], history: [d, a]),
          [e, d, a]);
      // Nothing played yet: it repeats.
      expect(
          contextListFor(e,
              playlists: const [], liked: const [], history: const []),
          [e]);
      expect(
          neighbourOf(e, 1,
              playlists: const [], liked: const [], history: const []),
          e);
    });

    test('a one-song list repeats; it never moves to another list', () {
      final one = [
        Playlist(id: 'q', name: 'Q', songs: [c])
      ];
      expect(contextListFor(c, playlists: one, liked: [c, d], history: [a, b]),
          [c]);
      expect(
          neighbourOf(c, 1, playlists: one, liked: [c, d], history: [a, b]), c);
    });

    test(
        'a phone file plays on through My Music unless it is in a playlist or liked',
        () {
      final f1 = Song(
          videoId: 'local_1',
          title: 'f1',
          artist: '',
          thumbnailUrl: '',
          localUri: 'content://media/1');
      final f2 = Song(
          videoId: 'local_2',
          title: 'f2',
          artist: '',
          thumbnailUrl: '',
          localUri: 'content://media/2');
      expect(
          contextListFor(f1,
              playlists: pls, liked: [], history: [f1, a], onDevice: [f1, f2]),
          [f1, f2]);
      expect(
          contextTitleFor(f1,
              playlists: pls, liked: [], history: [f1], onDevice: [f1, f2]),
          'My Music');
      expect(
          contextListFor(f1,
              playlists: pls, liked: [f1, c], history: [], onDevice: [f1, f2]),
          [f1, c]);
    });
  });
}
