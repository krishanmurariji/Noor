import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noor/services/rooms/firebase_room_store.dart';
import 'package:noor/services/rooms/room_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config =
    RoomConfig('https://noor-test.firebasedatabase.app', 'test-key');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('config is ready only with both settings', () {
    expect(const RoomConfig('', '').ready, isFalse);
    expect(const RoomConfig('http://x', 'k').ready, isFalse);
    expect(_config.ready, isTrue);
  });

  test('signs in anonymously once, then reads and writes with the token',
      () async {
    final seen = <String>[];
    var signUps = 0;
    final client = MockClient((req) async {
      seen.add('${req.method} ${req.url.path}');
      if (req.url.host == 'identitytoolkit.googleapis.com') {
        signUps++;
        return http.Response(
            jsonEncode({
              'idToken': 'tok1',
              'refreshToken': 'ref1',
              'localId': 'uid-1',
              'expiresIn': '3600'
            }),
            200);
      }
      expect(req.url.queryParameters['auth'], 'tok1');
      if (req.method == 'PUT') {
        final body = jsonDecode(req.body);
        // The server fills in its timestamps.
        return http.Response(
            jsonEncode(body is Map && body['.sv'] != null ? 1700 : body), 200);
      }
      if (req.url.path.endsWith('/denied.json')) {
        return http.Response('{"error":"Permission denied"}', 401);
      }
      return http.Response('null', 200);
    });
    final store = FirebaseRoomStore(_config, client: client);
    await store.ready();
    expect(store.uid, 'uid-1');
    expect(await store.write('rooms/AB/x', {'a': 1}), {'a': 1});
    expect(await store.write('rooms/AB/seen', RoomStore.serverTime), 1700);
    expect(await store.read('rooms/AB'), isNull);
    await store.remove('rooms/AB');
    await expectLater(store.read('denied'),
        throwsA(isA<RoomStoreError>().having((e) => e.denied, 'denied', true)));
    expect(signUps, 1);
    expect(seen, contains('DELETE /rooms/AB.json'));
    expect((await SharedPreferences.getInstance()).getString('room_auth_uid'),
        'uid-1');
  });

  test('a saved sign-in is refreshed instead of a new one', () async {
    SharedPreferences.setMockInitialValues(
        {'room_auth_refresh': 'ref-old', 'room_auth_uid': 'uid-old'});
    var signUps = 0;
    final client = MockClient((req) async {
      if (req.url.host == 'securetoken.googleapis.com') {
        expect(req.bodyFields['refresh_token'], 'ref-old');
        return http.Response(
            jsonEncode({
              'id_token': 'tok2',
              'refresh_token': 'ref2',
              'user_id': 'uid-old',
              'expires_in': '3600'
            }),
            200);
      }
      signUps++;
      return http.Response('{}', 500);
    });
    final store = FirebaseRoomStore(_config, client: client);
    await store.ready();
    expect(store.uid, 'uid-old');
    expect(signUps, 0);
  });

  test('the live stream applies put and patch events', () async {
    final events = StreamController<List<int>>();
    final client = MockClient.streaming((req, _) async {
      if (req.url.host == 'identitytoolkit.googleapis.com') {
        return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({
              'idToken': 't',
              'refreshToken': 'r',
              'localId': 'u',
              'expiresIn': '3600'
            }))),
            200);
      }
      expect(req.headers['Accept'], 'text/event-stream');
      return http.StreamedResponse(events.stream, 200);
    });
    final values = <Object?>[];
    final errors = <Object>[];
    final sub = _Store(_config, client)
        .watch('rooms/AB')
        .listen(values.add, onError: errors.add);
    await Future<void>.delayed(Duration.zero);
    void send(String event, Object data) =>
        events.add(utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n'));
    send('put', {
      'path': '/',
      'data': {
        'info': {'name': 'R'},
        'members': {
          'u': {'name': 'A'}
        }
      }
    });
    send('keep-alive', 'null');
    send('patch', {
      'path': '/members',
      'data': {
        'v': {'name': 'B'}
      }
    });
    send('put', {'path': '/members/u', 'data': null});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(values, [
      {
        'info': {'name': 'R'},
        'members': {
          'u': {'name': 'A'}
        }
      },
      {
        'info': {'name': 'R'},
        'members': {
          'u': {'name': 'A'},
          'v': {'name': 'B'}
        }
      },
      {
        'info': {'name': 'R'},
        'members': {
          'v': {'name': 'B'}
        }
      },
    ]);
    // Not allowed any more (removed, or the room ended): the stream says so.
    send('cancel', 'null');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(errors.single,
        isA<RoomStoreError>().having((e) => e.denied, 'denied', true));
    await sub.cancel();
    await events.close();
  });
}

/// Uses the test client for the live stream too.
class _Store extends FirebaseRoomStore {
  _Store(super.config, this.c) : super(client: c);
  final http.Client c;
  @override
  http.Client streamClient() => c;
}
