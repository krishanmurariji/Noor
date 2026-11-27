import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';
import 'native_ready.dart';

const _channel = MethodChannel('noor/exits');

/// Android closes an app that uses more than about 10 % of the processor
/// while in the background. Once a minute this looks at how much Noor used;
/// when it was a lot it says so in the Playback Log, with its busiest
/// threads by name, so the cause can be found.
class CpuWatch {
  CpuWatch._();
  static final instance = CpuWatch._();

  Timer? _timer;
  int? _lastTotal;
  DateTime? _lastAt;
  Map<String, int> _lastThreads = {};
  bool? _wasProtected;

  /// Whether music is meant to be playing (set by the app).
  bool Function()? playing;

  /// Extra context for the log line ("playing", "room: star"…).
  String Function()? describe;

  Future<void> start() async {
    if (_timer != null) return;
    if (!await nativeReady()) return;
    await _sample(log: false);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _sample());
  }

  Future<void> _sample({bool log = true}) async {
    Map? m;
    try {
      m = await _channel.invokeMapMethod<String, Object?>('cpu');
    } catch (_) {
      return;
    }
    if (m == null) return;
    final now = DateTime.now();
    final total = (m['totalMs'] as num?)?.toInt() ?? 0;
    final threads = <String, int>{};
    final names = <String, String>{};
    for (final t in (m['threads'] as List? ?? const [])) {
      if (t is! Map) continue;
      final id = '${t['id']}';
      threads[id] = (t['ticks'] as num?)?.toInt() ?? 0;
      names[id] = '${t['name']}';
    }
    // 100 on screen, 125 kept alive by the music notification.
    final importance = (m['importance'] as num?)?.toInt() ?? 0;
    final protected = importance > 0 && importance <= 125;
    final away0 = WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    if (away0 && (playing?.call() ?? false) && protected != _wasProtected) {
      nlog(protected
          ? '[N] music notification keeps Noor alive in the background'
          : '[N] playing in the background without the music notification\'s '
              'protection (Android rank $importance): Android may close Noor');
      _wasProtected = protected;
    } else if (!away0) {
      _wasProtected = null;
    }
    final lastTotal = _lastTotal, lastAt = _lastAt;
    if (log && lastTotal != null && lastAt != null) {
      final wall = now.difference(lastAt).inMilliseconds;
      final used = total - lastTotal;
      final share = wall > 0 ? used / wall : 0.0;
      final state = WidgetsBinding.instance.lifecycleState;
      final away = state != AppLifecycleState.resumed;
      // Busy: over 8 % in the background, or over 40 % on screen.
      if ((away && share > 0.08) || share > 0.40) {
        final top = <(String, int)>[];
        threads.forEach((id, ticks) {
          final d = ticks - (_lastThreads[id] ?? 0);
          if (d > 0) top.add((names[id] ?? id, d));
        });
        top.sort((a, b) => b.$2.compareTo(a.$2));
        // Clock ticks are 10 ms on Android.
        final busiest = top
            .take(4)
            .map((t) => '${t.$1} ${(t.$2 / 100).toStringAsFixed(1)}s')
            .join(', ');
        nlog('[N] busy ${away ? 'in the background' : 'on screen'}: '
            '${(used / 1000).toStringAsFixed(1)}s of processor in '
            '${(wall / 1000).round()}s (${(share * 100).round()}%)'
            '${describe == null ? '' : ' · ${describe!()}'}'
            ' · rank $importance'
            ' · busiest: $busiest');
      }
    }
    _lastTotal = total;
    _lastAt = now;
    _lastThreads = threads;
  }
}
