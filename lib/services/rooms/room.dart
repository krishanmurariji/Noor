import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/song.dart';
import '../app_log.dart';
import 'room_store.dart';
import 'room_sync.dart';

/// Most people in a room, the star included.
const kRoomCap = 20;

/// Longest room name (it sits in the pill on the player).
const kRoomNameMax = 10;

/// A member not heard from for this long shows as away…
const kRoomAwayMs = 45000;

/// …and after this long the star's phone takes them out of the room (the
/// app was closed or the phone lost its connection).
const kRoomGoneMs = 120000;

/// How often a phone alone in its room says it's still here (others in
/// the room: every 15 s).
const kRoomAloneBeatMs = 120000;

/// The name a phone has until its person gives theirs: "Guest" and four
/// letters of its id, like a room code.
String guestName(String uid) {
  final letters = uid.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  final tag =
      letters.length >= 4 ? letters.substring(0, 4) : letters.padRight(4, 'X');
  return 'Guest $tag';
}

/// A room name as stored: trimmed, at most [kRoomNameMax] letters.
String cleanRoomName(String name) {
  final r = name.trim().runes.toList();
  return String.fromCharCodes(r.take(kRoomNameMax)).trim();
}

/// Room codes: six letters and digits that can't be mixed up when read
/// aloud or typed (no 0/O, 1/I/L).
const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

String newRoomCode([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(6, (_) => _codeAlphabet[r.nextInt(_codeAlphabet.length)])
      .join();
}

/// Tidies what someone typed into a code ("k7qm 2x" → "K7QM2X"), or null
/// when it can't be one.
String? cleanRoomCode(String typed) {
  final c = typed.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (c.length != 6) return null;
  return c.split('').every(_codeAlphabet.contains) ? c : null;
}

enum RoomRole { none, knocking, star, listener }

class RoomMember {
  const RoomMember(this.uid, this.name, this.joinedAt, this.seen);
  final String uid;
  final String name;
  final int joinedAt;
  final int seen;

  String get initial => name.isEmpty ? '?' : name.characters1.toUpperCase();
}

extension on String {
  String get characters1 =>
      runes.isEmpty ? '' : String.fromCharCode(runes.first);
}

class RoomKnock {
  const RoomKnock(this.uid, this.name, this.at);
  final String uid;
  final String name;
  final int at;
}

/// A listener asking for something: a song, or to be the star.
class RoomAsk {
  const RoomAsk(this.id, this.kind, this.uid, this.name, this.song, this.at);
  final String id;

  /// 'song' or 'star'.
  final String kind;
  final String uid;
  final String name;
  final Song? song;
  final int at;
  bool get isSong => kind == 'song';
}

/// What the star is playing, as of [at] (the store's clock).
class RoomPlay {
  const RoomPlay(this.song, this.positionMs, this.playing, this.at,
      {this.fromPhone = false, this.sync = 0});

  /// Goes up when the star taps "Sync everyone": every listener jumps to
  /// the star's place.
  final int sync;
  final Song? song;
  final int positionMs;
  final bool playing;
  final int at;

  /// A song file on the star's phone: the others can't play it.
  final bool fromPhone;

  /// Where the song is at [serverNow].
  Duration positionAt(int serverNow) => Duration(
      milliseconds: positionMs + (playing ? max(0, serverNow - at) : 0));
}

/// A room as the store holds it, read tolerantly.
class RoomSnapshot {
  const RoomSnapshot({
    required this.code,
    required this.name,
    required this.starUid,
    required this.starName,
    required this.members,
    required this.knocks,
    required this.asks,
    required this.blocked,
    required this.play,
    required this.queue,
    required this.notes,
  });

  final String code;
  final String name;
  final String starUid;
  final String starName;

  /// In the order they joined (the star first if they started it).
  final List<RoomMember> members;
  final List<RoomKnock> knocks;
  final List<RoomAsk> asks;
  final Set<String> blocked;
  final RoomPlay? play;
  final List<Song> queue;

  /// The latest note to each member: uid → (text, at).
  final Map<String, (String, int)> notes;

  int get waiting => knocks.length + asks.length;
  bool has(String uid) => members.any((m) => m.uid == uid);

  static RoomSnapshot? parse(String code, Object? tree) {
    if (tree is! Map) return null;
    final info = tree['info'];
    if (info is! Map) return null;
    String s(Object? v) => v is String ? v : '';
    int n(Object? v) => v is num ? v.toInt() : 0;
    Map m(Object? v) => v is Map ? v : const {};

    final members = <RoomMember>[];
    m(tree['members']).forEach((k, v) {
      if (v is Map) {
        members.add(RoomMember('$k', s(v['name']), n(v['at']), n(v['seen'])));
      }
    });
    members.sort((a, b) => a.joinedAt.compareTo(b.joinedAt));

    final knocks = <RoomKnock>[];
    m(tree['knocks']).forEach((k, v) {
      if (v is Map && v['answer'] == null) {
        knocks.add(RoomKnock('$k', s(v['name']), n(v['at'])));
      }
    });
    knocks.sort((a, b) => a.at.compareTo(b.at));

    final asks = <RoomAsk>[];
    m(tree['asks']).forEach((k, v) {
      if (v is! Map) return;
      final kind = v['kind'] == 'star' ? 'star' : 'song';
      final song = v['song'] is Map ? Song.fromMap(v['song'] as Map) : null;
      if (kind == 'song' && (song == null || !song.isPlayable)) return;
      asks.add(
          RoomAsk('$k', kind, s(v['uid']), s(v['name']), song, n(v['at'])));
    });
    asks.sort((a, b) => a.at.compareTo(b.at));

    RoomPlay? play;
    final p = tree['play'];
    if (p is Map) {
      final song = p['song'] is Map ? Song.fromMap(p['song'] as Map) : null;
      play = RoomPlay(song, n(p['pos']), p['playing'] == true, n(p['at']),
          fromPhone: p['phone'] == true, sync: n(p['sync']));
    }

    final queue = <Song>[];
    final q = tree['queue'];
    final items = q is List
        ? q
        : q is Map
            ? (q.keys.toList()
                  ..sort((a, b) => (int.tryParse('$a') ?? 0)
                      .compareTo(int.tryParse('$b') ?? 0)))
                .map((k) => q[k])
                .toList()
            : const [];
    for (final v in items) {
      if (v is Map) {
        final song = Song.fromMap(v);
        if (song.isPlayable) queue.add(song);
      }
    }

    final notes = <String, (String, int)>{};
    m(tree['notes']).forEach((k, v) {
      if (v is Map) notes['$k'] = (s(v['text']), n(v['at']));
    });

    return RoomSnapshot(
      code: code,
      name: s(info['name']),
      starUid: s(info['star']),
      starName: s(info['starName']),
      members: members,
      knocks: knocks,
      asks: asks,
      blocked: m(tree['blocked']).keys.map((k) => '$k').toSet(),
      play: play,
      queue: queue,
      notes: notes,
    );
  }
}

class RoomState {
  const RoomState({
    this.role = RoomRole.none,
    this.code,
    this.room,
    this.knockingName,
    this.busy = false,
    this.away = const {},
  });

  /// Members not heard from for a while ([kRoomAwayMs]).
  final Set<String> away;

  final RoomRole role;
  final String? code;
  final RoomSnapshot? room;

  /// While knocking: the room's name.
  final String? knockingName;
  final bool busy;

  bool get inRoom => role == RoomRole.star || role == RoomRole.listener;
  bool get isStar => role == RoomRole.star;
  bool get isListener => role == RoomRole.listener;
}

/// Something worth saying in the capsule.
class RoomEvent {
  const RoomEvent(this.text,
      {this.openRoom = false, this.openRequests = false});

  /// Its "See" button opens the requests to answer (someone wants in, a
  /// song or the star asked for).
  final bool openRequests;
  final String text;

  /// Its "See" button opens the room.
  final bool openRoom;
}

/// One phone's side of a room: starting, knocking, letting people in and
/// the requests. Playback itself is followed by the app (room_provider).
class RoomController {
  RoomController(this.store, {int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RoomStore store;
  final int Function() _clock;

  RoomState _state = const RoomState();
  RoomState get state => _state;
  final _states = StreamController<RoomState>.broadcast();
  Stream<RoomState> get changes => _states.stream;
  final _events = StreamController<RoomEvent>.broadcast();
  Stream<RoomEvent> get events => _events.stream;

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _beat;
  String _myName = '';
  int _lastNote = 0;
  bool _leaving = false;

  /// The store's clock, as best this phone knows it.
  int serverNow() => clock.serverNow(_clock());
  final ClockSync clock = ClockSync();

  /// Round trip of the clock reading in use (ms); null before one.
  int? get clockRtt => clock.rtt;

  /// True once this phone knows the store's clock well enough to stamp
  /// positions itself.
  bool get clockReady => clock.ready;

  Future<void> _readClock(String path) async {
    final before = _clock();
    final at = await store.write(path, RoomStore.serverTime);
    final after = _clock();
    if (at is num) clock.add(before, at.toInt(), after);
  }

  String get uid => store.uid;
  String _room(String code) => 'rooms/$code';

  void _set(RoomState s) {
    final was = _state;
    _state = s;
    _states.add(s);
    if (was.role != s.role) {
      nlog('[R] room role ${was.role.name} → ${s.role.name}');
    }
  }

  // ── Starting and joining ──────────────────────────────────────────────

  /// Starts a room with this phone as the star. Returns its code.
  Future<String> start(String myName, {String? roomName}) async {
    await store.ready();
    _myName = myName;
    String code;
    var tries = 0;
    do {
      code = newRoomCode();
      if (++tries > 5) throw RoomStoreError('no free room code');
    } while (await store.read('${_room(code)}/info') != null);
    const now = RoomStore.serverTime;
    await store.write(_room(code), {
      'info': {
        'name': cleanRoomName(roomName ?? myName).isEmpty
            ? 'Room'
            : cleanRoomName(roomName ?? myName),
        'star': uid,
        'starName': myName,
        'at': now,
      },
      'members': {
        uid: {'name': myName, 'at': now, 'seen': now},
      },
    });
    _enter(code, RoomRole.star);
    return code;
  }

  /// Asks to join the room [code]. The star lets you in (or not).
  /// Returns null when the knock went in, or why it couldn't.
  Future<String?> knock(String code, String myName) async {
    await store.ready();
    _myName = myName;
    Object? info;
    try {
      info = await store.read('${_room(code)}/info');
    } on RoomStoreError catch (e) {
      if (!e.denied) rethrow;
    }
    if (info is! Map) return 'No room with that code';
    try {
      await store.write('${_room(code)}/knocks/$uid',
          {'name': myName, 'at': RoomStore.serverTime});
    } on RoomStoreError catch (e) {
      if (e.denied) return "You can't join this room";
      rethrow;
    }
    _stop();
    _set(RoomState(
        role: RoomRole.knocking,
        code: code,
        knockingName: info['name'] is String ? info['name'] as String : code));
    _subs.add(store.watch('${_room(code)}/members/$uid').listen((v) {
      if (v != null && _state.role == RoomRole.knocking) {
        _enter(code, RoomRole.listener);
        _events
            .add(RoomEvent("You're in · ${_state.knockingName ?? 'the room'}"));
      }
    }, onError: (_) {}));
    _subs.add(store.watch('${_room(code)}/knocks/$uid/answer').listen((v) {
      if (v == null || _state.role != RoomRole.knocking) return;
      _stop();
      _set(const RoomState());
      _events.add(RoomEvent(v == 'blocked'
          ? "You can't join this room"
          : 'Not this time · the star said no'));
    }, onError: (_) {}));
    return null;
  }

  Future<void> cancelKnock() async {
    final code = _state.code;
    if (_state.role != RoomRole.knocking || code == null) return;
    _stop();
    _set(const RoomState());
    try {
      await store.remove('${_room(code)}/knocks/$uid');
    } catch (_) {}
  }

  void _enter(String code, RoomRole role) {
    _stop();
    _leaving = false;
    _lastNote = serverNow();
    _set(RoomState(role: role, code: code));
    _subs.add(store.watch(_room(code)).listen((tree) => _onRoom(code, tree),
        // Firebase stops the stream once this phone may no longer read the
        // room: removed, blocked, or the room ended.
        onError: (Object e) => _ended(code, "You're no longer in the room")));
    _beat = Timer.periodic(const Duration(seconds: 15), (_) {
      // Alone (this phone's own room, as it is most of the time): nobody
      // needs to see it's still here, so far fewer trips to the server.
      final alone = (_state.room?.members.length ?? 1) <= 1;
      final since = DateTime.now().millisecondsSinceEpoch - _lastBeatMs;
      if (alone && since < kRoomAloneBeatMs) return;
      unawaited(_heartbeat());
    });
    unawaited(() async {
      // A few readings at the start: the quickest round trip wins.
      for (var i = 0; i < 12 && _state.code == code; i++) {
        await _heartbeat();
      }
      nlog(
          '[R] clock: offset ${clock.offset}ms, round trip ${clock.rtt ?? '?'}ms');
    }());
  }

  int _lastBeatMs = 0;

  Future<void> _heartbeat() async {
    final code = _state.code;
    if (!_state.inRoom || code == null) return;
    _lastBeatMs = DateTime.now().millisecondsSinceEpoch;
    try {
      await _readClock('${_room(code)}/members/$uid/seen');
    } catch (_) {/* next beat */}
    // The star clears out phones gone for good (closed, no connection).
    final room = _state.room;
    if (_state.isStar && room != null && clock.ready) {
      final now = serverNow();
      for (final m in room.members) {
        if (m.uid != uid && m.seen > 0 && now - m.seen > kRoomGoneMs) {
          try {
            await store.remove('${_room(code)}/members/${m.uid}');
            nlog('[R] ${m.name} gone for ${(now - m.seen) ~/ 1000}s: '
                'taken out of the room');
          } catch (_) {/* offline: next beat */}
        }
      }
    }
  }

  /// One heartbeat now (tests).
  @visibleForTesting
  Future<void> beat() => _heartbeat();

  /// Rejoins [code] after the app was closed, if this phone is still in
  /// it. False when it isn't (removed meanwhile, or the room ended).
  Future<bool> resume(String code) async {
    if (_state.role != RoomRole.none) return false;
    try {
      await store.ready();
      final me = await store.read('${_room(code)}/members/$uid');
      if (me is! Map) return false;
      final info = await store.read('${_room(code)}/info');
      if (info is! Map) return false;
      _myName = me['name'] is String ? me['name'] as String : _myName;
      _enter(code, info['star'] == uid ? RoomRole.star : RoomRole.listener);
      nlog('[R] back in room $code after the app was closed');
      return true;
    } catch (e) {
      nlog('[R] could not rejoin $code: $e');
      return false;
    }
  }

  void _onRoom(String code, Object? tree) {
    if (_state.code != code || !(_state.inRoom)) return;
    final room = RoomSnapshot.parse(code, tree);
    if (room == null) {
      _ended(code, 'The room has ended');
      return;
    }
    if (!room.has(uid)) {
      _ended(
          code,
          room.blocked.contains(uid)
              ? 'You were removed from the room'
              : 'You left the room');
      return;
    }
    final was = _state;
    final role = room.starUid == uid ? RoomRole.star : RoomRole.listener;

    if (was.room != null) _announce(was.room!, room, role);
    // Someone came in: show them at once that this phone is here.
    if ((was.room?.members.length ?? 1) <= 1 && room.members.length > 1) {
      unawaited(_heartbeat());
    }
    final note = room.notes[uid];
    if (note != null && note.$2 > _lastNote) {
      _lastNote = note.$2;
      _events.add(RoomEvent(note.$1));
    }
    final now = serverNow();
    _set(RoomState(
      role: role,
      code: code,
      room: room,
      away: {
        if (clock.ready)
          for (final m in room.members)
            if (m.uid != uid && m.seen > 0 && now - m.seen > kRoomAwayMs) m.uid,
      },
    ));
  }

  void _announce(RoomSnapshot was, RoomSnapshot now, RoomRole role) {
    if (role == RoomRole.star && was.starUid != uid) {
      _events.add(const RoomEvent("You're the star now", openRoom: true));
      return;
    }
    if (role == RoomRole.listener && was.starUid != now.starUid) {
      _events.add(RoomEvent('${now.starName} is the star now'));
    }
    if (role != RoomRole.star) return;
    final oldKnocks = was.knocks.map((k) => k.uid).toSet();
    for (final k in now.knocks) {
      if (!oldKnocks.contains(k.uid)) {
        _events.add(RoomEvent('${k.name} wants to join', openRequests: true));
      }
    }
    final oldAsks = was.asks.map((a) => a.id).toSet();
    for (final a in now.asks) {
      if (oldAsks.contains(a.id)) continue;
      _events.add(RoomEvent(
          a.isSong
              ? '${a.name} asked for ${a.song!.title}'
              : '${a.name} asks to be the star',
          openRequests: true));
    }
  }

  void _ended(String code, String why) {
    if (_state.code != code) return;
    final quiet = _leaving;
    _stop();
    _set(const RoomState());
    if (!quiet) _events.add(RoomEvent(why));
  }

  void _stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _beat?.cancel();
    _beat = null;
  }

  /// Leaves the room. A star hands the room to whoever has been in it
  /// longest; the last one out closes it.
  Future<void> leave() async {
    final code = _state.code;
    final room = _state.room;
    if (code == null) return;
    if (_state.role == RoomRole.knocking) return cancelKnock();
    _leaving = true;
    _stop();
    _set(const RoomState());
    try {
      if (room != null && room.starUid == uid) {
        final next = room.members.where((m) => m.uid != uid).toList();
        if (next.isEmpty) {
          await store.remove(_room(code));
        } else {
          await store.update(_room(code), {
            'info/star': next.first.uid,
            'info/starName': next.first.name,
            'info/name': cleanRoomName(next.first.name),
            'members/$uid': null,
          });
        }
      } else {
        await store.remove('${_room(code)}/members/$uid');
      }
    } catch (e) {
      nlog('[R] leaving the room: $e');
    }
  }

  // ── The star's side ───────────────────────────────────────────────────

  String get _code => _state.code ?? '';

  /// Lets [uid] in. False when the room is full.
  Future<bool> letIn(RoomKnock k) async {
    final room = _state.room;
    if (room == null || room.members.length >= kRoomCap) return false;
    await store.update(_room(_code), {
      'members/${k.uid}': {
        'name': k.name,
        'at': RoomStore.serverTime,
        'seen': RoomStore.serverTime,
      },
      'knocks/${k.uid}': null,
    });
    return true;
  }

  Future<void> notNow(RoomKnock k) =>
      store.write('${_room(_code)}/knocks/${k.uid}/answer', 'no');

  /// Keeps [uid] out for as long as the room lasts (and removes them).
  Future<void> block(String uid, String name) => store.update(_room(_code), {
        'blocked/$uid': name.isEmpty ? true : name,
        'knocks/$uid/answer': 'blocked',
        'members/$uid': null,
      });

  Future<void> remove(String uid) =>
      store.remove('${_room(_code)}/members/$uid');

  /// Takes a song request off the list and tells whoever asked.
  /// The caller adds the song to what plays.
  Future<void> acceptSong(RoomAsk a, {required bool next}) =>
      store.update(_room(_code), {
        'asks/${a.id}': null,
        'notes/${a.uid}': {
          'text': next
              ? '${a.song!.title} plays next'
              : '${a.song!.title} is in the queue',
          'at': RoomStore.serverTime,
        },
      });

  Future<void> decline(RoomAsk a) =>
      store.remove('${_room(_code)}/asks/${a.id}');

  /// Makes [m] the star; this phone becomes a listener.
  Future<void> handOver(RoomMember m) async {
    final room = _state.room;
    if (room == null) return;
    await store.update(_room(_code), {
      'info/star': m.uid,
      'info/starName': m.name,
      'info/name': cleanRoomName(m.name),
      for (final a in room.asks.where((a) => !a.isSong)) 'asks/${a.id}': null,
    });
  }

  /// Renames the room (the star only; at most [kRoomNameMax] letters).
  Future<void> rename(String name) async {
    final n = cleanRoomName(name);
    if (!_state.isStar || n.isEmpty) return;
    await store.write('${_room(_code)}/info/name', n);
  }

  /// This phone's name changed: it shows at once in the room. A room
  /// carries its star's name, so the star's room is renamed with it.
  Future<void> setMyName(String name) async {
    final n = cleanRoomName(name);
    if (n.isEmpty) return;
    _myName = n;
    final code = _state.code;
    if (!_state.inRoom || code == null) return;
    if (_state.isStar) {
      await store.update(_room(code), {
        'members/$uid/name': n,
        'info/starName': n,
        'info/name': n,
      });
    } else {
      try {
        await store.write('${_room(code)}/members/$uid/name', n);
      } on RoomStoreError catch (_) {/* the room's rules keep it */}
    }
  }

  int _sync = 0;

  /// "Sync everyone": the next [publishPlay] tells every listener to jump
  /// to the star's place.
  void syncEveryone() {
    _sync = (_state.room?.play?.sync ?? _sync) + 1;
  }

  /// What plays now, for everyone to follow. [at] is when [position] was
  /// read, on the store's clock ([serverNow]); without it the store stamps
  /// the write when it arrives (late by the upload time).
  Future<void> publishPlay(Song? song, Duration position, bool playing,
      {int? at}) async {
    if (!_state.isStar) return;
    await store.write('${_room(_code)}/play', {
      if (song != null) 'song': song.toMap()..remove('localUri'),
      if (song?.isLocal ?? false) 'phone': true,
      'pos': position.inMilliseconds,
      'playing': playing,
      'at': at ?? RoomStore.serverTime,
      if (_sync > 0) 'sync': _sync,
    });
  }

  Future<void> publishQueue(List<Song> upNext) async {
    if (!_state.isStar) return;
    final shareable = upNext.where((s) => !s.isLocal).take(kRoomCap);
    await store.write('${_room(_code)}/queue',
        shareable.isEmpty ? null : shareable.map((s) => s.toMap()).toList());
  }

  // ── A listener's side ─────────────────────────────────────────────────

  Future<void> askForSong(Song song) async {
    if (!_state.isListener || song.isLocal || !song.isPlayable) return;
    final id = '${serverNow()}-${uid.length > 6 ? uid.substring(0, 6) : uid}';
    await store.write('${_room(_code)}/asks/$id', {
      'kind': 'song',
      'uid': uid,
      'name': _myName,
      'song': song.toMap(),
      'at': RoomStore.serverTime,
    });
  }

  Future<void> askToBeStar() async {
    if (!_state.isListener) return;
    await store.write('${_room(_code)}/asks/star-$uid', {
      'kind': 'star',
      'uid': uid,
      'name': _myName,
      'at': RoomStore.serverTime,
    });
  }

  /// True after this phone already asked to be the star (still waiting).
  bool get askedToBeStar =>
      _state.room?.asks.any((a) => !a.isSong && a.uid == uid) ?? false;

  /// The name this phone shows in the room.
  String get myName {
    final me = _state.room?.members.where((m) => m.uid == uid);
    return (me != null && me.isNotEmpty) ? me.first.name : _myName;
  }

  void dispose() {
    _stop();
    _states.close();
    _events.close();
  }
}
