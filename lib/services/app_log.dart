import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Removes anything in a log line that should not be shared: query strings of
/// URLs (YouTube stream URLs carry signed, IP-bound tokens) and long opaque
/// tokens. Hosts and paths stay so the log is still useful.
String redactSecrets(String line) {
  var out = line.replaceAllMapped(
    RegExp(r'''(https?://[^\s"'<>?#]+)[?#][^\s"'<>]*'''),
    (m) => '${m[1]}?…',
  );
  out = out.replaceAllMapped(
    RegExp(r'\b(key|token|sig|signature|authorization|password)=([^\s&]+)',
        caseSensitive: false),
    (m) => '${m[1]}=…',
  );
  return out;
}

/// In-memory ring buffer of recent log lines, shown on the Playback Log screen
/// so problems can be diagnosed on a phone without a USB cable.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int capacity = 600;
  final ListQueue<String> _lines = ListQueue<String>();

  /// Bumped on every new line so the UI can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<String> get lines => List.unmodifiable(_lines);

  RandomAccessFile? _file;
  File? _path;
  int _written = 0;

  /// The last this many bytes are kept on the phone.
  static const int keepBytes = 300 * 1024;

  /// Keeps the log on the phone as it is written (straight to the file,
  /// nothing held back), so it survives the app closing unexpectedly. The
  /// previous session's lines come back first, under a divider.
  Future<void> persistTo(Directory dir) async {
    try {
      final current = File('${dir.path}/noor_log.txt');
      final previous = File('${dir.path}/noor_log_previous.txt');
      if (await current.exists()) {
        final old = (await current.readAsString())
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        if (old.isNotEmpty) {
          final keep = old.length > 350 ? old.sublist(old.length - 350) : old;
          final now = _lines.toList();
          _lines
            ..clear()
            ..add(
                '──────── previous session (before Noor last closed) ────────')
            ..addAll(keep)
            ..add('──────── this session ────────')
            ..addAll(now);
          while (_lines.length > capacity) {
            _lines.removeFirst();
          }
          revision.value++;
        }
        if (await previous.exists()) await previous.delete();
        await current.rename(previous.path);
      }
      _path = current;
      _file = await current.open(mode: FileMode.append);
      // This session's lines so far.
      final start = _lines.toList();
      final at = start.indexOf('──────── this session ────────');
      for (final l in at >= 0 ? start.sublist(at + 1) : start) {
        _write(l);
      }
    } catch (e) {
      debugPrint('[N] log file: $e');
    }
  }

  void _write(String line) {
    final f = _file;
    if (f == null) return;
    try {
      f.writeStringSync('$line\n');
      _written += line.length + 1;
      if (_written > keepBytes) _trim();
    } catch (_) {}
  }

  /// Keeps the file to the newest half when it grows past [keepBytes].
  void _trim() {
    final p = _path;
    final f = _file;
    if (p == null || f == null) return;
    try {
      f.closeSync();
      final text = p.readAsStringSync();
      final tail = text.substring(text.length - keepBytes ~/ 2);
      p.writeAsStringSync(tail.substring(tail.indexOf('\n') + 1));
      _written = keepBytes ~/ 2;
      _file = p.openSync(mode: FileMode.append);
    } catch (_) {}
  }

  void add(String message, {DateTime? now}) {
    final t = (now ?? DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    final line = '$stamp  ${redactSecrets(message)}';
    _lines.addLast(line);
    _write(line);
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    revision.value++;
  }

  void clear() {
    _lines.clear();
    revision.value++;
  }

  String dump() => _lines.join('\n');
}

/// Logs to the console and to the in-app log.
void nlog(String message) {
  debugPrint(message);
  AppLog.instance.add(message);
}
