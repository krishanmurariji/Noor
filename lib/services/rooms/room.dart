import 'dart:async';
import 'dart:math';

import '../../models/song.dart';
import '../app_log.dart';
import 'room_store.dart';

/// Most people in a room, the star included.
const kRoomCap = 20;

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
      {this.fromPhone = false});
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
          fromPhone: p['phone'] == true);
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
  });

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
  const RoomEvent(this.text, {this.openRoom = false});
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
  int _offset = 0;
  int _lastNote = 0;
  bool _leaving = false;

  /// The store's clock, as best this phone knows it.
  int serverNow() => _clock() + _offset;

  /// Round trip of the best clock reading so far (ms); null before one.
  int? get clockRtt => _rtt;
  int? _rtt;
  int _rttAt = 0;

  /// True once this phone knows the store's clock well enough to stamp
  /// positions itself.
  bool get clockReady => _rtt != null;

  /// Reads the store's clock once: writes its timestamp and halves the
  /// round trip. Keeps the reading with the shortest round trip (the most
  /// exact), refreshed every few minutes as phone clocks drift.
  Future<void> _readClock(String path) async {
    final before = _clock();
    final at = await store.write(path, RoomStore.serverTime);
    final after = _clock();
    if (at is! num) return;
    final rtt = after - before;
    final stale = after - _rttAt > const Duration(minutes: 5).inMilliseconds;
    if (_rtt == null || rtt <= _rtt! + 20 || stale) {
      _offset = at.toInt() - (before + after) ~/ 2;
      _rtt = rtt;
      _rttAt = after;
    }
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
        'name': roomName ?? "$myName's room",
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
    _beat = Timer.periodic(const Duration(seconds: 30), (_) => _heartbeat());
    unawaited(() async {
      // A few readings at the start: the quickest round trip wins.
      for (var i = 0; i < 4 && _state.code == code; i++) {
        await _heartbeat();
      }
      nlog('[R] clock: offset ${_offset}ms, round trip ${_rtt ?? '?'}ms');
    }());
  }

  Future<void> _heartbeat() async {
    final code = _state.code;
    if (!_state.inRoom || code == null) return;
    try {
      await _readClock('${_room(code)}/members/$uid/seen');
    } catch (_) {/* next beat */}
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
    final note = room.notes[uid];
    if (note != null && note.$2 > _lastNote) {
      _lastNote = note.$2;
      _events.add(RoomEvent(note.$1));
    }
    _set(RoomState(role: role, code: code, room: room));
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
        _events.add(RoomEvent('${k.name} wants to join', openRoom: true));
      }
    }
    final oldAsks = was.asks.map((a) => a.id).toSet();
    for (final a in now.asks) {
      if (oldAsks.contains(a.id)) continue;
      _events.add(RoomEvent(
          a.isSong
              ? '${a.name} asked for ${a.song!.title}'
              : '${a.name} asks to be the star',
          openRoom: true));
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
      for (final a in room.asks.where((a) => !a.isSong)) 'asks/${a.id}': null,
    });
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
