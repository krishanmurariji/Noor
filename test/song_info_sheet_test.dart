import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor/models/song.dart';
import 'package:noor/services/song_details.dart';
import 'package:noor/widgets/song_info_sheet.dart';

const song = Song(
    videoId: 'abcdefghijk',
    title: 'Monsoon Letters',
    artist: 'Aanya Rao',
    thumbnailUrl: '');

void main() {
  testWidgets(
      'the details drop in (record and numbers only); a swipe up puts them away',
      (t) async {
    t.view.physicalSize = const Size(411, 891);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var added = 0;
    await t.pumpWidget(ProviderScope(
      overrides: [
        songDetailsProvider.overrideWith((ref, id) async => SongDetails(
              videoId: id,
              channel: 'Aanya Rao - Topic',
              description: 'Singer: Aanya Rao\nLyrics: Irshad Kamil',
              views: 12400000,
              likes: 284000,
              published: DateTime(2023, 7),
            )),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showSongInfo(context, song, onAddToPlaylist: () => added++),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    for (var i = 0; i < 14; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Monsoon Letters'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    // Just the record and its numbers: no liner notes, tags or about.
    expect(find.text('LINER NOTES'), findsNothing);
    expect(find.text('SINGER'), findsNothing);
    expect(find.text('ABOUT'), findsNothing);
    expect(find.textContaining('#'), findsNothing);
    // No YouTube or Add to playlist buttons any more.
    expect(find.text('YouTube'), findsNothing);
    expect(find.text('Add to playlist'), findsNothing);

    // Swipe it back up: it follows the finger and goes.
    await t.drag(find.text('Monsoon Letters'), const Offset(0, -200));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('12.4M'), findsNothing);

    // Again, with a long swipe that first scrolls the details to their
    // end: going on past the end puts the panel away too.
    await t.tap(find.text('open'));
    for (var i = 0; i < 14; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('12.4M'), findsOneWidget);
    await t.drag(find.text('12.4M'), const Offset(0, -900));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('12.4M'), findsNothing);
    expect(added, 0);
  });
}
