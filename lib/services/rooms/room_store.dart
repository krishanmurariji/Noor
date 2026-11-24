import 'dart:async';

/// Where a room's shared data lives: a JSON tree that several phones read,
/// write and watch. [FirebaseRoomStore] is the real one; [MemoryRoomStore]
/// keeps the tree in memory (tests, and several "phones" in one test).
abstract class RoomStore {
  /// This phone's id in the store (stable across app starts).
  String get uid;

  /// Signs in if needed. Throws [RoomStoreError] when the store can't be
  /// reached.
  Future<void> ready();

  Future<Object?> read(String path);

  /// Replaces the value at [path] (null removes it). Returns what was
  /// stored, with server timestamps ([serverTime]) filled in.
  Future<Object?> write(String path, Object? value);

  /// Sets some children of [path], leaving the others.
  Future<void> update(String path, Map<String, Object?> values);

  Future<void> remove(String path) => write(path, null);

  /// The value at [path] now and every time it changes (null: nothing there).
  Stream<Object?> watch(String path);

  /// A value the store replaces with its own clock, in milliseconds.
  static const Map<String, String> serverTime = {'.sv': 'timestamp'};
}

class RoomStoreError implements Exception {
  RoomStoreError(this.message, {this.denied = false});
  final String message;

  /// The store's rules refused (not a member, blocked, room gone).
  final bool denied;
  @override
  String toString() => 'RoomStoreError($message)';
}

/// Splits "a/b/c" into its parts, ignoring empty ones.
List<String> pathParts(String path) =>
    path.split('/').where((p) => p.isNotEmpty).toList();

/// A JSON tree kept up to date from "put" and "patch" changes at a path,
/// the way Firebase's live stream reports them.
class JsonTree {
  Object? value;

  void put(String path, Object? data) {
    value = _set(value, pathParts(path), _clean(data));
  }

  void patch(String path, Map data) {
    data.forEach((k, v) => put('$path/$k', v));
  }

  Object? at(String path) {
    Object? node = value;
    for (final p in pathParts(path)) {
      if (node is Map) {
        node = node[p];
      } else {
        return null;
      }
    }
    return node;
  }

  static Object? _set(Object? node, List<String> parts, Object? data) {
    if (parts.isEmpty) return data;
    final map = node is Map
        ? Map<String, Object?>.from(node)
        : node is List
            ? {for (var i = 0; i < node.length; i++) '$i': node[i]}
            : <String, Object?>{};
    final child = _set(map[parts.first], parts.sublist(1), data);
    if (child == null) {
      map.remove(parts.first);
    } else {
      map[parts.first] = child;
    }
    return map.isEmpty ? null : map;
  }

  /// Copies [data] as plain maps, dropping nulls (Firebase stores none).
  static Object? _clean(Object? data) {
    if (data is Map) {
      final m = <String, Object?>{};
      data.forEach((k, v) {
        final c = _clean(v);
        if (c != null) m['$k'] = c;
      });
      return m.isEmpty ? null : m;
    }
    if (data is List) {
      final m = <String, Object?>{};
      for (var i = 0; i < data.length; i++) {
        final c = _clean(data[i]);
        if (c != null) m['$i'] = c;
      }
      return m.isEmpty ? null : m;
    }
    return data;
  }
}

/// The whole tree in memory, shared by every [MemoryRoomStore] made on it
/// (each one a different phone).
class MemoryRoomDb {
  final JsonTree tree = JsonTree();
  final _changes = StreamController<void>.broadcast();
  int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  /// Writes that should fail, as `(uid, path) → denied?`.
  bool Function(String uid, String path)? refuse;

  void _changed() => _changes.add(null);
}

class MemoryRoomStore extends RoomStore {
  MemoryRoomStore(this.db, this.uid);
  final MemoryRoomDb db;
  @override
  final String uid;

  @override
  Future<void> ready() async {}

  @override
  Future<Object?> read(String path) async => _copy(db.tree.at(path));

  @override
  Future<Object?> write(String path, Object? value) async {
    _check(path);
    final v = _resolve(value);
    db.tree.put(path, v);
    db._changed();
    return _copy(db.tree.at(path));
  }

  @override
  Future<void> update(String path, Map<String, Object?> values) async {
    _check(path);
    db.tree.patch(path, _resolve(values) as Map);
    db._changed();
  }

  void _check(String path) {
    if (db.refuse?.call(uid, path) ?? false) {
      throw RoomStoreError('refused: $path', denied: true);
    }
  }

  Object? _resolve(Object? v) {
    if (v is Map) {
      if (v.length == 1 && v['.sv'] == 'timestamp') return db.clock();
      return v.map((k, x) => MapEntry('$k', _resolve(x)));
    }
    if (v is List) return v.map(_resolve).toList();
    return v;
  }

  @override
  Stream<Object?> watch(String path) {
    late StreamController<Object?> c;
    StreamSubscription<void>? sub;
    String? last;
    void emit() {
      final v = _copy(db.tree.at(path));
      final key = '$v';
      if (key == last) return;
      last = key;
      c.add(v);
    }

    c = StreamController<Object?>(
      onListen: () {
        sub = db._changes.stream.listen((_) => emit());
        scheduleMicrotask(emit);
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  static Object? _copy(Object? v) {
    if (v is Map) return v.map((k, x) => MapEntry('$k', _copy(x)));
    return v;
  }
}
