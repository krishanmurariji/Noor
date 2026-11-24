import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Songs play while they download through just_audio's server on the phone
/// itself (http://127.0.0.1). Android blocks plain http unless the network
/// rules allow it, and then every song not yet saved fails ("Source error").
void main() {
  final xml = File('android/app/src/main/res/xml/network_security_config.xml')
      .readAsStringSync();

  test('plain http is allowed for the phone itself, nowhere else', () {
    expect(xml, contains('<base-config cleartextTrafficPermitted="false">'));
    final local = RegExp(
            r'<domain-config cleartextTrafficPermitted="true">([\s\S]*?)</domain-config>')
        .firstMatch(xml);
    expect(local, isNotNull, reason: 'the local player server needs http');
    final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>')
        .allMatches(local!.group(1)!)
        .map((m) => m.group(1))
        .toSet();
    expect(domains, {'127.0.0.1', 'localhost'});
  });
}
