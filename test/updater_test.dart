import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noor/services/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> release(int build,
        {String branch = 'master',
        bool signed = true,
        String? sha,
        String url =
            'https://github.com/krishanmurariji/Noor/releases/download/b/noor.apk',
        int size = 1000}) =>
    {
      'tag_name': 'build-$build',
      'draft': false,
      'prerelease': false,
      'body': 'Newest build from `$branch` @ `abc1234` (build #$build).\n\n'
          '${branch == 'master' ? 'Channel: stable' : 'Channel: test'}\n\n'
          '${signed ? 'Signed with the Noor release key: installs as an update over earlier builds.' : '**Signed with a throwaway debug key.**'}\n\n'
          'SHA-256: `${sha ?? 'a' * 64}`\n',
      'assets': [
        {'name': 'noor.apk', 'browser_download_url': url, 'size': size},
        {
          'name': 'noor.apk.sha256',
          'browser_download_url': '$url.sha256',
          'size': 75
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which release is an update', () {
    test('the newest stable (master) build newer than this one', () {
      final u = newestStableUpdate([
        release(150, branch: 'claude/x'), // a test build: never
        release(146),
        release(148),
        release(120),
      ], 142)!;
      expect(u.build, 148);
      expect(u.sha256, 'a' * 64);
      expect(u.size, 1000);
    });

    test('older master releases (before the Channel line) still count', () {
      final r = release(146)
        ..['body'] =
            'Newest build from `master` @ `0c96532` (build #146).\n\nSigned with the Noor release key: installs.\n';
      expect(newestStableUpdate([r], 142)!.build, 146);
    });

    test('nothing newer, unsigned, or from elsewhere: no update', () {
      expect(newestStableUpdate([release(142), release(120)], 142), isNull);
      expect(newestStableUpdate([release(150, signed: false)], 142), isNull);
      expect(
          newestStableUpdate(
              [release(150, url: 'https://evil.example/noor.apk')], 142),
          isNull);
      expect(
          newestStableUpdate(
              [release(150, url: 'http://github.com/x/noor.apk')], 142),
          isNull);
      expect(newestStableUpdate('junk', 142), isNull);
      expect(
          newestStableUpdate([
            {'tag_name': 'v1'}
          ], 142),
          isNull);
    });
  });

  group('downloading', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('noor_upd');
    });
    tearDown(() => dir.delete(recursive: true));

    final apk = List<int>.generate(1000, (i) => i % 256);
    final good = sha256.convert(apk).toString();

    Updater make(List<Map<String, Object?>> releases) => Updater(null,
        currentBuild: 142,
        tempDir: () async => dir,
        client: MockClient((req) async {
          if (req.url.host == 'api.github.com') {
            return http.Response(jsonEncode(releases), 200);
          }
          return http.Response.bytes(apk, 200);
        }));

    test('check, download and verify: ready to install', () async {
      final u = make([release(148, sha: good)]);
      final info = await u.check();
      expect(info!.build, 148);
      expect(u.state.phase, UpdatePhase.available);
      expect(await u.download(info), isTrue);
      expect(u.state.phase, UpdatePhase.ready);
      expect(File('${dir.path}/noor-update-148.apk').lengthSync(), 1000);
    });

    test('a download that does not match the release is thrown away', () async {
      final u = make([release(148, sha: 'b' * 64)]);
      final info = (await u.check())!;
      expect(await u.download(info), isFalse);
      expect(u.state.phase, UpdatePhase.failed);
      expect(File('${dir.path}/noor-update-148.apk').existsSync(), isFalse);
    });

    test('up to date', () async {
      final u = make([release(140, sha: good)]);
      expect(await u.check(), isNull);
      expect(u.state.phase, UpdatePhase.upToDate);
    });

    test('the setting is on by default and remembered', () async {
      final u = make([]);
      await Future<void>.delayed(Duration.zero);
      expect(u.state.auto, isTrue);
      await u.setAuto(false);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(kAutoUpdateKey), isFalse);
    });
  });
}
