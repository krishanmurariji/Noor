import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_log.dart';
import 'room_store.dart';

/// The Firebase project Rooms use. Set at build time
/// (`--dart-define=NOOR_FIREBASE_DB_URL=… --dart-define=NOOR_FIREBASE_API_KEY=…`)
/// or in [_dbUrl] / [_apiKey] below. Both are public client settings (the
/// database rules, firebase/database.rules.json, decide who may do what).
class RoomConfig {
  const RoomConfig(this.dbUrl, this.apiKey);
  final String dbUrl;
  final String apiKey;

  static const _dbUrl = '';
  static const _apiKey = '';

  static const fromBuild = RoomConfig(
    String.fromEnvironment('NOOR_FIREBASE_DB_URL', defaultValue: _dbUrl),
    String.fromEnvironment('NOOR_FIREBASE_API_KEY', defaultValue: _apiKey),
  );

  bool get ready => dbUrl.startsWith('https://') && apiKey.isNotEmpty;
}

/// Firebase Realtime Database over its REST API: an anonymous sign-in
/// (kept across app starts), reads and writes, and live streams
/// (server-sent events) that keep a copy of the tree up to date.
class FirebaseRoomStore extends RoomStore {
  FirebaseRoomStore(this.config, {http.Client? client})
      : _http = client ?? http.Client();

  final RoomConfig config;
  final http.Client _http;

  static const _kRefresh = 'room_auth_refresh';
  static const _kUid = 'room_auth_uid';

  String? _uid;
  String? _token;
  String? _refresh;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _signing;

  @override
  String get uid => _uid ?? '';

  @override
  Future<void> ready() => _fresh();

  Future<String> _fresh() async {
    if (_token != null &&
        DateTime.now()
            .isBefore(_expires.subtract(const Duration(minutes: 5)))) {
      return _token!;
    }
    await (_signing ??= _signIn().whenComplete(() => _signing = null));
    return _token!;
  }

  Future<void> _signIn() async {
    final prefs = await SharedPreferences.getInstance();
    _refresh ??= prefs.getString(_kRefresh);
    _uid ??= prefs.getString(_kUid);
    Map<String, dynamic> body;
    try {
      if (_refresh != null) {
        final r = await _http.post(
          Uri.parse(
              'https://securetoken.googleapis.com/v1/token?key=${config.apiKey}'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'grant_type': 'refresh_token', 'refresh_token': _refresh!},
        ).timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          body = jsonDecode(r.body) as Map<String, dynamic>;
          _set(body['id_token'], body['refresh_token'], body['user_id'],
              body['expires_in']);
          await _save(prefs);
          return;
        }
        nlog('[R] token refresh failed (${r.statusCode}), signing in again');
      }
      final r = await _http
          .post(
            Uri.parse('https://identitytoolkit.googleapis.com/v1/'
                'accounts:signUp?key=${config.apiKey}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        throw RoomStoreError('sign-in failed (${r.statusCode})');
      }
      body = jsonDecode(r.body) as Map<String, dynamic>;
      _set(body['idToken'], body['refreshToken'], body['localId'],
          body['expiresIn']);
      await _save(prefs);
      nlog('[R] signed in as a new room member');
    } on RoomStoreError {
      rethrow;
    } catch (e) {
      throw RoomStoreError('no connection ($e)');
    }
  }

  void _set(Object? token, Object? refresh, Object? uid, Object? expiresIn) {
    _token = '$token';
    _refresh = '$refresh';
    _uid = '$uid';
    final secs = int.tryParse('$expiresIn') ?? 3600;
    _expires = DateTime.now().add(Duration(seconds: secs));
  }

  Future<void> _save(SharedPreferences prefs) async {
    await prefs.setString(_kRefresh, _refresh!);
    await prefs.setString(_kUid, _uid!);
  }

  Future<Uri> _uri(String path) async {
    final token = await _fresh();
    final base = config.dbUrl.endsWith('/')
        ? config.dbUrl.substring(0, config.dbUrl.length - 1)
        : config.dbUrl;
    return Uri.parse('$base/${pathParts(path).join('/')}.json?auth=$token');
  }

  Future<Object?> _send(String method, String path, [Object? body]) async {
    final uri = await _uri(path);
    http.Response r;
    try {
      final req = http.Request(method, uri);
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      r = await http.Response.fromStream(
          await _http.send(req).timeout(const Duration(seconds: 15)));
    } catch (e) {
      throw RoomStoreError('no connection ($e)');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw RoomStoreError('not allowed: $path', denied: true);
    }
    if (r.statusCode >= 300) {
      throw RoomStoreError('${r.statusCode} for $path');
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  @override
  Future<Object?> read(String path) => _send('GET', path);

  @override
  Future<Object?> write(String path, Object? value) =>
      value == null ? _send('DELETE', path) : _send('PUT', path, value);

  @override
  Future<void> update(String path, Map<String, Object?> values) =>
      _send('PATCH', path, values);

  /// A client of its own per live stream (closing it ends the stream).
  @visibleForTesting
  http.Client streamClient() => http.Client();

  @override
  Stream<Object?> watch(String path) {
    late StreamController<Object?> out;
    var closed = false;
    http.Client? client;
    var wait = 1;

    Future<void> loop() async {
      while (!closed) {
        final tree = JsonTree();
        String? last;
        try {
          client = streamClient();
          final req = http.Request('GET', await _uri(path))
            ..headers['Accept'] = 'text/event-stream';
          final res = await client!.send(req);
          if (res.statusCode == 401 || res.statusCode == 403) {
            throw RoomStoreError('not allowed: $path', denied: true);
          }
          if (res.statusCode != 200) throw RoomStoreError('${res.statusCode}');
          String? event;
          await for (final line in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            if (closed) break;
            if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              final data = line.substring(5).trim();
              switch (event) {
                case 'put':
                case 'patch':
                  final m = jsonDecode(data) as Map;
                  final p = '${m['path']}';
                  if (event == 'put') {
                    tree.put(p, m['data']);
                  } else if (m['data'] is Map) {
                    tree.patch(p, m['data'] as Map);
                  }
                  final key = jsonEncode(tree.value);
                  if (key != last) {
                    last = key;
                    wait = 1;
                    out.add(tree.value);
                  }
                  break;
                case 'cancel':
                  throw RoomStoreError('not allowed: $path', denied: true);
                case 'auth_revoked':
                  _token = null; // reconnects with a fresh token
                  throw RoomStoreError('token expired');
              }
            }
          }
        } on RoomStoreError catch (e) {
          if (e.denied) {
            if (!closed) out.addError(e);
            closed = true;
            break;
          }
        } catch (e) {
          nlog('[R] room stream dropped: $e');
        } finally {
          if (!identical(client, _http)) client?.close();
          client = null;
        }
        if (closed) break;
        await Future<void>.delayed(Duration(seconds: wait));
        wait = (wait * 2).clamp(1, 15);
      }
      if (!out.isClosed) await out.close();
    }

    out = StreamController<Object?>(
      onListen: () => unawaited(loop()),
      onCancel: () {
        closed = true;
        if (!identical(client, _http)) client?.close();
      },
    );
    return out.stream;
  }
}
