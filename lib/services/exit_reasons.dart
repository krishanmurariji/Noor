import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

const _exits = MethodChannel('noor/exits');
const _kSeen = 'exit_reasons_seen_until';

/// Writes into the Playback Log why Noor closed since it last looked
/// (Android keeps the reasons: a crash, a freeze, low memory, killed by the
/// system, closed by the user…), and any crash Noor wrote down itself.
Future<void> logPastExits() async {
  try {
    final crash = await _exits.invokeMethod<String>('crash');
    if (crash != null && crash.trim().isNotEmpty) {
      nlog('[N] last crash: ${crash.trim()}');
    }
    final list = await _exits.invokeListMethod<Map>('recent') ?? const [];
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getInt(_kSeen) ?? 0;
    var newest = seen;
    for (final x in list.reversed) {
      final time = (x['time'] as num?)?.toInt() ?? 0;
      if (time <= seen) continue;
      if (time > newest) newest = time;
      final when = DateTime.fromMillisecondsSinceEpoch(time);
      String two(int n) => n.toString().padLeft(2, '0');
      final desc = '${x['description'] ?? ''}'.trim();
      final mb = ((x['pssKb'] as num?) ?? 0) ~/ 1024;
      nlog('[N] Noor closed ${two(when.day)}/${two(when.month)} '
          '${two(when.hour)}:${two(when.minute)}:${two(when.second)}: '
          '${x['reason']}'
          '${desc.isEmpty ? '' : ' · $desc'}'
          '${mb > 0 ? ' · using $mb MB' : ''}');
    }
    if (newest > seen) await prefs.setInt(_kSeen, newest);
  } catch (_) {/* not Android, or an old one */}
}
