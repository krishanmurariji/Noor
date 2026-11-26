import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noor/services/app_log.dart';

/// The log survives Noor closing unexpectedly: it is kept on the phone as
/// it is written, and the last session's lines come back on the next start.
void main() {
  test('last session comes back under a divider, this one is kept too',
      () async {
    final dir = await Directory.systemTemp.createTemp('noor_log');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/noor_log.txt').writeAsStringSync(
        '10:00:00.000  [N] playing\n10:00:01.000  [R] sync\n');
    final log = AppLog.instance..clear();
    log.add('started');
    await log.persistTo(dir);
    final lines = log.lines;
    expect(lines.first, contains('previous session'));
    expect(lines, contains('10:00:01.000  [R] sync'));
    expect(lines.indexWhere((l) => l.contains('this session')),
        lessThan(lines.indexWhere((l) => l.endsWith('started'))));
    log.add('[N] after');
    // On the phone straight away (nothing held back).
    final kept = File('${dir.path}/noor_log.txt').readAsStringSync();
    expect(kept, contains('started'));
    expect(kept, contains('[N] after'));
    expect(File('${dir.path}/noor_log_previous.txt').existsSync(), isTrue);
  });
}
