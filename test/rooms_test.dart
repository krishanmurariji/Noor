import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor/models/song.dart';
import 'package:noor/providers/player_provider.dart';
import 'package:noor/providers/room_provider.dart';
import 'package:noor/services/rooms/room.dart';
import 'package:noor/services/rooms/room_store.dart';
import 'package:noor/services/rooms/room_sync.dart';
import 'package:noor/theme/noor_palette.dart';
import 'package:noor/widgets/room_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _song = Song(
    videoId: 'abcdefghijk',
    title: 'Monsoon Letters',
    artist: 'Aanya Rao',
    thumbnailUrl: '');
const _other = Song(
    videoId: 'zyxwvutsrqp',
    title: 'Velvet Night',
    artist: 'Zaid',
    thumbnailUrl: '');

class _P extends StateNotifier<NebulaPlayerState> implements PlayerNotifier {
  _P() : super(const NebulaPlayerState(song: _song));
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FakePlayer implements FollowPlayer {
  double pos = 35000;
  final seeks = <Duration>[];
  @override
  String? get songId => _song.videoId;
  @override
  Duration get position => Duration(milliseconds: pos.round());
  @override
  bool get playing => true;
  @override
  bool get loading => false;
  @override
  void load(Song song) {}
  @override
  void seek(Duration to) {
    seeks.add(to);
    pos = to.inMilliseconds.toDouble();
  }

  @override
  void play() {}
  @override
  void pause() {}
  @override
  void setSpeed(double speed) {}
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('codes', () {
    test('new codes are six unmistakable characters', () {
      for (var i = 0; i < 50; i++) {
        final c = newRoomCode();
        expect(c, hasLength(6));
        expect(cleanRoomCode(c), c);
        expect(c, isNot(matches(RegExp('[01OIL]'))));
      }
    });

    test('typed codes are tidied, wrong ones refused', () {
      expect(cleanRoomCode(' k7qm 2x'), 'K7QM2X');
      expect(cleanRoomCode('K7-QM-2X'), 'K7QM2X');
      expect(cleanRoomCode('K7QM2'), isNull);
      expect(cleanRoomCode('K7QM2O'), isNull); // O looks like 0
    });
  });

  group('JsonTree (the live stream copy)', () {
    test('put and patch at paths, nulls remove', () {
      final t = JsonTree();
      t.put('/', {
        'a': 1,
        'b': {'c': 2}
      });
      t.put('/b/d', 3);
      expect(t.value, {
        'a': 1,
        'b': {'c': 2, 'd': 3}
      });
      t.patch('/b', {'c': null, 'e': 5});
      expect(t.at('b'), {'d': 3, 'e': 5});
      t.put('/a', null);
      expect(t.at('a'), isNull);
      t.put('/', null);
      expect(t.value, isNull);
    });

    test('lists become maps by index, like Firebase sends them', () {
      final t = JsonTree();
      t.put('/q', [
        {'x': 1},
        {'x': 2}
      ]);
      t.put('/q/1/x', 9);
      expect(t.at('q/1/x'), 9);
      expect(t.at('q/0/x'), 1);
    });
  });

  group('a room between phones', () {
    late MemoryRoomDb db;
    late RoomController aanya, rohan, zaid;
    final events = <String, List<String>>{};

    setUp(() {
      db = MemoryRoomDb();
      aanya = RoomController(MemoryRoomStore(db, 'uid-aanya'));
      rohan = RoomController(MemoryRoomStore(db, 'uid-rohan'));
      zaid = RoomController(MemoryRoomStore(db, 'uid-zaid'));
      events.clear();
      for (final (name, c) in [('a', aanya), ('r', rohan), ('z', zaid)]) {
        events[name] = [];
        c.events.listen((e) => events[name]!.add(e.text));
      }
    });

    tearDown(() {
      aanya.dispose();
      rohan.dispose();
      zaid.dispose();
    });

    Future<String> startAndLetIn() async {
      final code = await aanya.start('Aanya');
      await _settle();
      expect(await rohan.knock(code, 'Rohan'), isNull);
      await _settle();
      expect(rohan.state.role, RoomRole.knocking);
      expect(aanya.state.room!.knocks.single.name, 'Rohan');
      expect(events['a'], contains('Rohan wants to join'));
      await aanya.letIn(aanya.state.room!.knocks.single);
      await _settle();
      return code;
    }

    test('start, ask to join, let in', () async {
      final code = await startAndLetIn();
      expect(aanya.state.isStar, isTrue);
      expect(rohan.state.isListener, isTrue);
      expect(rohan.state.code, code);
      expect(rohan.state.room!.starName, 'Aanya');
      expect(aanya.state.room!.members.map((m) => m.name), ['Aanya', 'Rohan']);
      expect(aanya.state.room!.knocks, isEmpty);
      expect(events['r']!.single, startsWith("You're in"));
    });

    test('a wrong code says so', () async {
      expect(await rohan.knock('ZZZZZZ', 'Rohan'), 'No room with that code');
      expect(rohan.state.role, RoomRole.none);
    });

    test('not now, and block keeps them out', () async {
      final code = await aanya.start('Aanya');
      await _settle();
      await zaid.knock(code, 'Zaid');
      await _settle();
      await aanya.notNow(aanya.state.room!.knocks.single);
      await _settle();
      expect(zaid.state.role, RoomRole.none);
      expect(events['z']!.last, contains('said no'));

      await zaid.knock(code, 'Zaid');
      await _settle();
      await aanya.block('uid-zaid', 'Zaid');
      await _settle();
      expect(zaid.state.role, RoomRole.none);
      expect(events['z']!.last, "You can't join this room");
      expect(aanya.state.room!.blocked, contains('uid-zaid'));
    });

    test('a member removed is told so', () async {
      await startAndLetIn();
      await aanya.block('uid-rohan', 'Rohan');
      await _settle();
      expect(rohan.state.role, RoomRole.none);
      expect(events['r']!.last, 'You were removed from the room');
    });

    test('song requests: ask, accept, the asker hears back', () async {
      await startAndLetIn();
      await rohan.askForSong(_other);
      await _settle();
      final ask = aanya.state.room!.asks.single;
      expect(ask.song!.title, 'Velvet Night');
      expect(ask.name, 'Rohan');
      expect(events['a'], contains('Rohan asked for Velvet Night'));
      await aanya.acceptSong(ask, next: true);
      await _settle();
      expect(aanya.state.room!.asks, isEmpty);
      expect(events['r'], contains('Velvet Night plays next'));
    });

    test('phone songs are never asked for', () async {
      await startAndLetIn();
      await rohan.askForSong(const Song(
          videoId: 'local-12345',
          title: 'Voice memo',
          artist: '',
          thumbnailUrl: '',
          localUri: 'content://media/external/audio/media/5'));
      await _settle();
      expect(aanya.state.room!.asks, isEmpty);
    });

    test('asking to be the star and handing over', () async {
      await startAndLetIn();
      await rohan.askToBeStar();
      await _settle();
      expect(rohan.askedToBeStar, isTrue);
      final m = aanya.state.room!.members.firstWhere((m) => m.name == 'Rohan');
      await aanya.handOver(m);
      await _settle();
      expect(rohan.state.isStar, isTrue);
      expect(aanya.state.isListener, isTrue);
      expect(rohan.state.room!.asks, isEmpty);
      expect(events['r'], contains("You're the star now"));
      expect(events['a'], contains('Rohan is the star now'));
    });

    test('the star leaving hands the room on; the last one out ends it',
        () async {
      final code = await startAndLetIn();
      await aanya.leave();
      await _settle();
      expect(aanya.state.role, RoomRole.none);
      expect(rohan.state.isStar, isTrue);
      expect(rohan.state.room!.members.single.name, 'Rohan');
      await rohan.leave();
      await _settle();
      expect(await rohan.store.read('rooms/$code'), isNull);
    });

    test('the room ending tells the listeners', () async {
      final code = await startAndLetIn();
      await aanya.store.remove('rooms/$code');
      await _settle();
      expect(rohan.state.role, RoomRole.none);
      expect(events['r']!.last, 'The room has ended');
    });

    test('a full room lets nobody else in', () async {
      final code = await aanya.start('Aanya');
      await _settle();
      for (var i = 1; i < kRoomCap; i++) {
        await aanya.store.write(
            'rooms/$code/members/m$i', {'name': 'M$i', 'at': i, 'seen': i});
      }
      await rohan.knock(code, 'Rohan');
      await _settle();
      expect(await aanya.letIn(aanya.state.room!.knocks.single), isFalse);
    });

    test('the star stamps positions with the store\'s clock', () async {
      var now = 1000000;
      db.clock = () => now + 250; // the store's clock runs 250 ms ahead
      final star =
          RoomController(MemoryRoomStore(db, 'uid-star'), clock: () => now);
      addTearDown(star.dispose);
      await star.start('Star');
      await _settle();
      expect(star.clockReady, isTrue);
      expect(star.serverNow(), now + 250);
      await star.publishPlay(_song, const Duration(seconds: 10), true,
          at: star.serverNow());
      final p = await star.store.read('rooms/${star.state.code}/play');
      expect((p as Map)['at'], now + 250);
    });

    test('closed and opened again: back in the room', () async {
      final code = await startAndLetIn();
      rohan.dispose(); // the app was swiped away
      final again = RoomController(MemoryRoomStore(db, 'uid-rohan'));
      addTearDown(again.dispose);
      expect(await again.resume(code), isTrue);
      await _settle();
      expect(again.state.isListener, isTrue);
      expect(again.myName, 'Rohan');
      // Not in it any more (removed meanwhile): no rejoining.
      final zed = RoomController(MemoryRoomStore(db, 'uid-zaid'));
      addTearDown(zed.dispose);
      expect(await zed.resume(code), isFalse);
      expect(zed.state.role, RoomRole.none);
    });

    test('a phone not heard from shows as away, then is taken out', () async {
      var now = 5000000;
      db.clock = () => now;
      final star =
          RoomController(MemoryRoomStore(db, 'uid-star'), clock: () => now);
      final fan =
          RoomController(MemoryRoomStore(db, 'uid-fan'), clock: () => now);
      addTearDown(star.dispose);
      final code = await star.start('Star');
      await _settle();
      await fan.knock(code, 'Fan');
      await _settle();
      await star.letIn(star.state.room!.knocks.single);
      await _settle();
      fan.dispose(); // its app was closed: no more heartbeats
      now += kRoomAwayMs + 1000;
      await star.beat();
      await _settle();
      expect(star.state.away, {'uid-fan'});
      expect(star.state.room!.members, hasLength(2));
      now += kRoomGoneMs;
      await star.beat();
      await _settle();
      expect(star.state.room!.members.map((m) => m.name), ['Star']);
    });

    test('playback and the queue go up to the room', () async {
      await startAndLetIn();
      await aanya.publishPlay(_song, const Duration(seconds: 40), true);
      await aanya.publishQueue([_other]);
      await _settle();
      final play = rohan.state.room!.play!;
      expect(play.song!.title, 'Monsoon Letters');
      expect(play.playing, isTrue);
      expect(play.positionAt(play.at + 5000), const Duration(seconds: 45));
      expect(rohan.state.room!.queue.single.title, 'Velvet Night');
      // Listeners can't publish.
      await rohan.publishPlay(_other, Duration.zero, false);
      await _settle();
      expect(aanya.state.room!.play!.song!.title, 'Monsoon Letters');
    });
  });

  test('timing: tuned by ear in steps, kept, never past the limit', () async {
    SharedPreferences.setMockInitialValues({});
    final tune = RoomTuneNotifier();
    await Future<void>.delayed(Duration.zero);
    tune.nudge(20);
    tune.nudge(20);
    expect(tune.state, 40);
    await tune.set(5000);
    expect(tune.state, RoomTuneNotifier.limit);
    final again = RoomTuneNotifier();
    await Future<void>.delayed(Duration.zero);
    expect(again.state, RoomTuneNotifier.limit, reason: 'remembered');
  });

  group('following the star', () {
    test('"Sync now" and "Sync everyone" jump straight to the star', () {
      final p = _FakePlayer();
      // The stand-in player lands exactly where it seeks.
      final f = RoomFollower(p)..leadMs = 0;
      RoomPlay at(int sync) => RoomPlay(_song, 30000, true, 1000, sync: sync);
      // In step within 100 ms: left alone.
      f.tick(at(0), serverNow: 6000, nowMs: 0);
      p.pos = 35080;
      f.tick(at(0), serverNow: 6000, nowMs: 500);
      expect(p.seeks, isEmpty);
      f.resync();
      f.tick(at(0), serverNow: 6000, nowMs: 1000);
      expect(p.seeks, hasLength(1));
      // The star's "Sync everyone".
      f.tick(at(1), serverNow: 6000, nowMs: 5000);
      expect(p.seeks, hasLength(2));
      f.tick(at(1), serverNow: 6000, nowMs: 9000);
      expect(p.seeks, hasLength(2));
    });

    RoomPlay play({bool playing = true, int pos = 30000, Song? song}) =>
        RoomPlay(song ?? _song, pos, playing, 1000);

    test('another song: load it at the star\'s place', () {
      final s = followStep(
          play: play(),
          serverNow: 6000,
          mine: _other,
          myPosition: Duration.zero,
          myPlaying: true,
          myLoading: false,
          last: null);
      expect(s.kind, FollowKind.load);
      expect(s.song, _song);
      expect(s.at, const Duration(seconds: 35));
    });

    FollowStep at(int myMs, {double speed = 1.0, int lead = 0}) => followStep(
        play: play(),
        serverNow: 6000, // the star is at 35 000 ms
        mine: _song,
        myPosition: Duration(milliseconds: myMs),
        myPlaying: true,
        myLoading: false,
        mySpeed: speed,
        leadMs: lead,
        last: (id: _song.videoId, playing: true));

    test('far apart: seek, aimed ahead by the learned lead', () {
      final s = at(30000, lead: 150);
      expect(s.kind, FollowKind.seek);
      expect(s.at, const Duration(milliseconds: 35150));
      expect(s.driftMs, -5000);
    });

    test('a little behind: play faster; a little ahead: slower', () {
      final behind = at(34750);
      expect(behind.kind, FollowKind.speed);
      expect(behind.speed, 1.06);
      final ahead = at(35100);
      expect(ahead.kind, FollowKind.speed);
      expect(ahead.speed, 0.95);
      // Never more than 6 % either way.
      expect(at(34400).speed, 1.06);
    });

    test('in sync: normal speed again; tiny gaps are left alone', () {
      final back = at(35005, speed: 1.02);
      expect(back.kind, FollowKind.speed);
      expect(back.speed, 1.0);
      expect(at(35020).kind, FollowKind.none);
    });

    test('the star pauses or plays: so does this phone', () {
      expect(
          followStep(
              play: play(playing: false),
              serverNow: 6000,
              mine: _song,
              myPosition: const Duration(seconds: 30),
              myPlaying: true,
              myLoading: false,
              last: (id: _song.videoId, playing: true)).kind,
          FollowKind.pause);
      expect(
          followStep(
              play: play(),
              serverNow: 6000,
              mine: _song,
              myPosition: const Duration(seconds: 30),
              myPlaying: false,
              myLoading: false,
              last: (id: _song.videoId, playing: false)).kind,
          FollowKind.play);
    });

    test('a listener\'s own pause holds until the star changes something', () {
      final s = followStep(
          play: play(),
          serverNow: 6000,
          mine: _song,
          myPosition: const Duration(seconds: 10),
          myPlaying: false,
          myLoading: false,
          last: (id: _song.videoId, playing: true));
      expect(s.kind, FollowKind.none);
    });

    test('a song from the star\'s phone: pause, nothing to load', () {
      final s = followStep(
          play: const RoomPlay(null, 0, true, 1000, fromPhone: true),
          serverNow: 2000,
          mine: _song,
          myPosition: Duration.zero,
          myPlaying: true,
          myLoading: false,
          last: null);
      expect(s.kind, FollowKind.pause);
    });

    test('while loading the star\'s song, wait', () {
      final s = followStep(
          play: play(),
          serverNow: 6000,
          mine: _song,
          myPosition: Duration.zero,
          myPlaying: false,
          myLoading: true,
          last: (id: _song.videoId, playing: true));
      expect(s.kind, FollowKind.none);
    });
  });

  group('the room panel', () {
    Widget app(MemoryRoomDb db, {String uid = 'uid-aanya'}) => ProviderScope(
          overrides: [
            roomStoreProvider.overrideWithValue(MemoryRoomStore(db, uid)),
            playerProvider.overrideWith((ref) => _P()),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: NoorTheme.light.bg,
                body: const Center(
                    child: Padding(
                        padding: EdgeInsets.all(20), child: RoomPill())),
              ),
            ),
          ),
        );

    Future<void> realTime(WidgetTester tester) async {
      // The saved name loads in the test's clock, the room in real time.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(_settle);
      }
      await tester.pump(const Duration(milliseconds: 400));
    }

    String codeOf(MemoryRoomDb db, {String star = 'uid-aanya'}) {
      final rooms = (db.tree.value as Map)['rooms'] as Map;
      return rooms.entries
          .firstWhere((e) => ((e.value as Map)['info'] as Map)['star'] == star)
          .key as String;
    }

    testWidgets(
        'every phone has its own room code; Join a room opens the field '
        '(the name first, once)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = MemoryRoomDb();
      await tester.pumpWidget(app(db));
      await realTime(tester);
      final code = codeOf(db);
      expect(find.text(code), findsOneWidget);
      expect(find.text('Join a room'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-join-open')));
      await tester.pumpAndSettle();
      // No name yet: that first.
      await tester.enterText(find.byKey(const ValueKey('room-name')), 'Rohan');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-name-save')));
      await tester.pumpAndSettle();
      // The code field, with cancel and Join on the right.
      expect(find.byKey(const ValueKey('room-code')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-join-cancel')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('room-code')), 'k7q');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('room-join')));
      await tester.pump();
      expect(find.text('Asking to join · '), findsNothing, reason: 'not yet');
      // Cancel: this phone's own code again.
      await tester.tap(find.byKey(const ValueKey('room-join-cancel')));
      await tester.pumpAndSettle();
      expect(find.text(code), findsOneWidget);
      await tester.runAsync(() async {
        // Stop its heartbeat (real timers).
        ProviderScope.containerOf(tester.element(find.byType(RoomPill)))
            .read(roomProvider.notifier)
            .controller!
            .dispose();
      });
    });

    testWidgets(
        'someone joins: their faces and the star; swiped, the others only; '
        'the panel renames; leaving gives this phone a room again',
        (tester) async {
      SharedPreferences.setMockInitialValues({'room_my_name': 'Aanya'});
      final db = MemoryRoomDb();
      await tester.pumpWidget(app(db));
      await realTime(tester);
      final code = codeOf(db);

      await tester.runAsync(() async {
        await MemoryRoomStore(db, 'x').write('rooms/$code/members/uid-r',
            {'name': 'Rohan', 'at': 9e12, 'seen': 9e15});
        await _settle();
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(code), findsNothing);
      expect(find.text('R'), findsOneWidget);
      expect(find.text('Aanya'), findsOneWidget); // ★ Aanya on the right

      // Swipe right: the others (not the star) as circles; tap for a name.
      await tester.fling(
          find.byKey(const ValueKey('room-pill')), const Offset(300, 0), 1000);
      await tester.pumpAndSettle();
      final everyone = find.byKey(const ValueKey('room-everyone'));
      expect(find.descendant(of: everyone, matching: find.text('A')),
          findsNothing);
      await tester.tap(find.descendant(of: everyone, matching: find.text('R')));
      await tester.pumpAndSettle();
      expect(find.text('Rohan'), findsOneWidget);
      await tester.fling(everyone, const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(everyone, findsNothing);

      // The panel: the name pill renames (ten letters at most)…
      await tester.tap(find.byKey(const ValueKey('room-pill')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-rename-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('room-rename')), '');
      await tester.enterText(
          find.byKey(const ValueKey('room-rename')), 'Sunday night');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('room-rename-save')));
        await _settle();
      });
      await tester.pumpAndSettle();
      expect(find.text('Sunday nig'), findsOneWidget);
      // …swiped right it has Sync and Share…
      await tester.fling(find.byKey(const ValueKey('room-name-pill')),
          const Offset(300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-sync-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-share')), findsOneWidget);
      await tester.fling(find.byKey(const ValueKey('room-share')),
          const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      // …and leaving hands the room to Rohan; this phone gets its own
      // room again, with a new code.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('room-leave')));
        await _settle();
      });
      await realTime(tester);
      final old = (db.tree.value as Map)['rooms'][code] as Map;
      expect((old['info'] as Map)['star'], 'uid-r');
      final fresh = codeOf(db);
      expect(fresh, isNot(code));
      expect(find.text(fresh), findsOneWidget);
      await tester.runAsync(() async {
        // Stop its heartbeat (real timers).
        ProviderScope.containerOf(tester.element(find.byType(RoomPill)))
            .read(roomProvider.notifier)
            .controller!
            .dispose();
      });
    });

    testWidgets('requests are answered in a pop-up in the middle',
        (tester) async {
      SharedPreferences.setMockInitialValues({'room_my_name': 'Aanya'});
      final db = MemoryRoomDb();
      await tester.pumpWidget(app(db));
      await realTime(tester);
      final code = codeOf(db);
      await tester.runAsync(() async {
        await MemoryRoomStore(db, 'uid-z')
            .write('rooms/$code/knocks/uid-z', {'name': 'Zaid', 'at': 5});
        await _settle();
      });
      await tester.pump(const Duration(milliseconds: 400));
      // The count on the pill (still showing this phone's code) opens them.
      await tester.tap(find.byKey(const ValueKey('room-waiting')));
      await tester.pumpAndSettle();
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('wants to join'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.bySemanticsLabel('Let in'));
        await _settle();
      });
      await tester.pumpAndSettle();
      // Answered: the pop-up closes by itself.
      expect(find.text('Requests'), findsNothing);
      final members =
          ((db.tree.value as Map)['rooms'][code] as Map)['members'] as Map;
      expect(members.keys, contains('uid-z'));
      await tester.runAsync(() async {
        // Stop its heartbeat (real timers).
        ProviderScope.containerOf(tester.element(find.byType(RoomPill)))
            .read(roomProvider.notifier)
            .controller!
            .dispose();
      });
    });
  });
}
