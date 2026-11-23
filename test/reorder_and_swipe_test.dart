import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor/models/song.dart';
import 'package:noor/providers/library_provider.dart';
import 'package:noor/providers/player_provider.dart';
import 'package:noor/screens/home_screen.dart';
import 'package:noor/screens/settings_screen.dart';
import 'package:noor/screens/upnext_screen.dart';
import 'package:noor/services/audio_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_empty_state_test.dart' show openHome;
import 'search_filter_test.dart' show FakePlayer;

Song s(String t) => Song(
    videoId: t.padRight(11, 'x').substring(0, 11),
    title: t,
    artist: 'A',
    thumbnailUrl: '');
final songs = [s('One'), s('Two'), s('Three'), s('Four')];
String enc(List<Song> l) => jsonEncode(l.map((x) => x.toMap()).toList());

class _P extends StateNotifier<NebulaPlayerState> implements PlayerNotifier {
  _P(super.s);
  @override
  Future<void> setQueueOrder(List<Song> songs) async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

Future<void> frames(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> holdAndDrag(WidgetTester t, String title, String past) async {
  final from = t.getCenter(find.text(title));
  final below = t.getCenter(find.text(past));
  final g = await t.startGesture(from);
  await t.pump(const Duration(milliseconds: 700)); // the hold
  for (var i = 1; i <= 10; i++) {
    await g.moveTo(Offset.lerp(from, below + const Offset(0, 30), i / 10)!);
    await t.pump(const Duration(milliseconds: 30));
  }
  // The held song stays visible under the finger while it moves.
  expect(find.text(title), findsOneWidget);
  expect(t.getSize(find.text(title)).height, greaterThan(0));
  await g.up();
  await frames(t, 6);
}

void main() {
  testWidgets('Up next: a swipe to the left opens the song\'s actions',
      (t) async {
    SharedPreferences.setMockInitialValues({'nebula_liked': enc(songs)});
    t.view.physicalSize = const Size(411, 891);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        playerProvider.overrideWith((ref) => _P(NebulaPlayerState(
            song: songs[0], status: NebulaPlayerStatus.paused)))
      ],
      child: const MaterialApp(home: UpNextScreen()),
    ));
    await frames(t, 3);
    expect(find.byKey(const ValueKey('actions')), findsNothing);
    await t.fling(find.text('Two'), const Offset(-300, 0), 1200);
    await frames(t, 6);
    expect(find.byKey(const ValueKey('actions')), findsOneWidget);
  });

  testWidgets('Home: hold a song and drag it to move it in My Favorites',
      (t) async {
    await openHome(t, {'nebula_liked': enc(songs)});
    await frames(t, 15);
    await t.tap(find.byIcon(Icons.favorite_rounded));
    await frames(t, 20);
    expect(find.text('Four'), findsOneWidget);
    await holdAndDrag(t, 'One', 'Three');
    final c = ProviderScope.containerOf(t.element(find.byType(HomeScreen)));
    expect(c.read(likedProvider).map((x) => x.title),
        ['Two', 'Three', 'One', 'Four']);
    // Saved, too.
    final p = await SharedPreferences.getInstance();
    expect((jsonDecode(p.getString('nebula_liked')!) as List).first['title'],
        'Two');
  });

  testWidgets('Settings from the player: only Sound', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(ProviderScope(
        overrides: [playerProvider.overrideWith((ref) => FakePlayer())],
        child: const MaterialApp(home: SettingsScreen(soundOnly: true))));
    await frames(t, 2);
    expect(find.text('Sound'), findsOneWidget); // the title
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Equalizer'), findsOneWidget);
    expect(find.text('Gestures'), findsNothing);
    expect(find.text('Voice & start'), findsNothing);
    expect(find.text('Library'), findsNothing);
    expect(find.text('About'), findsNothing);

    await t.pumpWidget(ProviderScope(
        overrides: [playerProvider.overrideWith((ref) => FakePlayer())],
        child: const MaterialApp(home: SettingsScreen(key: ValueKey('all')))));
    await frames(t, 2);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Gestures'), findsOneWidget);
  });

  test('earbud events from Android', () {
    final on = AudioDeviceEvent.fromMap(
        {'event': 'connected', 'name': ' Galaxy Buds3 ', 'kind': 'buds'})!;
    expect(on.connected, isTrue);
    expect(on.name, 'Galaxy Buds3');
    expect(on.wired, isFalse);
    final off = AudioDeviceEvent.fromMap(
        {'event': 'disconnected', 'name': null, 'kind': 'wired'})!;
    expect(off.connected, isFalse);
    expect(off.name, '');
    expect(off.wired, isTrue);
    expect(AudioDeviceEvent.fromMap({'event': 'other'}), isNull);
    expect(AudioDeviceEvent.fromMap('x'), isNull);
  });
}
