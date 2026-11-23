import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import 'app_log.dart';
import 'audio_handler.dart';

/// Settings key: install new versions by themselves (on by default).
const kAutoUpdateKey = 'noor_auto_update';

/// Where Noor's releases are published.
const kReleasesApi =
    'https://api.github.com/repos/krishanmurariji/Noor/releases?per_page=30';

/// A newer stable build that can be installed.
class UpdateInfo {
  const UpdateInfo({
    required this.build,
    required this.apkUrl,
    required this.size,
    this.sha256,
  });

  final int build;
  final Uri apkUrl;
  final int size;

  /// The APK's SHA-256 as the release states it (lower-case hex).
  final String? sha256;
}

/// The newest stable (master) build in [releases] (GitHub's JSON) that is
/// newer than [currentBuild] and signed with the Noor release key, or null.
///
/// Test builds from other branches are never offered, and neither is a
/// build signed with a throwaway key (it could not install over this one).
UpdateInfo? newestStableUpdate(Object? releases, int currentBuild) {
  if (releases is! List) return null;
  UpdateInfo? best;
  for (final r in releases) {
    if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
    final body = (r['body'] as String?) ?? '';
    final stable =
        body.contains('Channel: stable') || body.contains('from `master`');
    if (!stable || !body.contains('Signed with the Noor release key')) continue;
    final tag = (r['tag_name'] as String?) ?? '';
    final build = int.tryParse(tag.replaceFirst('build-', ''));
    if (build == null || build <= currentBuild) continue;
    final assets = r['assets'];
    if (assets is! List) continue;
    Map? apk;
    for (final a in assets) {
      if (a is Map && a['name'] == 'noor.apk') apk = a;
    }
    final url = apk?['browser_download_url'];
    final size = apk?['size'];
    if (url is! String || size is! int || size <= 0) continue;
    final uri = Uri.tryParse(url);
    // Only ever download from GitHub, over https.
    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'github.com' || uri.host.endsWith('.github.com'))) {
      continue;
    }
    final sha = RegExp(r'SHA-256: `([0-9a-f]{64})`').firstMatch(body)?.group(1);
    if (best == null || build > best.build) {
      best = UpdateInfo(build: build, apkUrl: uri, size: size, sha256: sha);
    }
  }
  return best;
}

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
  needsPermission,
  failed,
}

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.info,
    this.progress = 0,
    this.message,
    this.auto = true,
  });

  final UpdatePhase phase;
  final UpdateInfo? info;

  /// Download progress, 0–1.
  final double progress;
  final String? message;

  /// "Update automatically" is on.
  final bool auto;

  UpdateState copyWith({
    UpdatePhase? phase,
    UpdateInfo? info,
    double? progress,
    String? message,
    bool? auto,
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        info: info ?? this.info,
        progress: progress ?? this.progress,
        message: message,
        auto: auto ?? this.auto,
      );
}

/// Keeps Noor up to date from its GitHub releases.
///
/// Automatically (on by default): checks when Noor opens and every six hours
/// while it runs; on Wi-Fi it downloads a newer stable build, checks its
/// SHA-256, and installs it once nothing is playing (Noor restarts). Android
/// may still ask for one tap (always the first time, and on some phones
/// every time); then the update waits in Settings → Updates.
class Updater extends StateNotifier<UpdateState> {
  Updater(this._handler,
      {http.Client? client,
      int? currentBuild,
      Future<Directory> Function()? tempDir})
      : _http = client ?? http.Client(),
        _tempDir = tempDir ?? getTemporaryDirectory,
        _current = currentBuild ?? int.tryParse(AppVersion.build) ?? 0,
        super(const UpdateState()) {
    unawaited(_start());
  }

  final NebulaAudioHandler? _handler;
  final http.Client _http;
  final int _current;
  final Future<Directory> Function() _tempDir;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  File? _apk;
  bool _busy = false;

  static const _channel = MethodChannel('noor/updater');
  static const _network = MethodChannel('noor/network');

  int get currentBuild => _current;

  Future<void> _start() async {
    try {
      final p = await SharedPreferences.getInstance();
      state = state.copyWith(auto: p.getBool(kAutoUpdateKey) ?? true);
    } catch (_) {}
    // Back from Android's "Install unknown apps" page: carry on installing.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (state.phase == UpdatePhase.needsPermission) unawaited(install());
    });
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status') _onInstallStatus(call.arguments);
      return null;
    });
    // A development build (no build number) never updates itself.
    if (_current <= 0 || kIsWeb || !Platform.isAndroid) return;
    await Future<void>.delayed(const Duration(seconds: 20)); // let it start
    await _autoRound();
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _autoRound());
  }

  Future<void> setAuto(bool on) async {
    state = state.copyWith(auto: on, phase: state.phase);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(kAutoUpdateKey, on);
    } catch (_) {}
    if (on) unawaited(_autoRound());
  }

  Future<bool> _onWifi() async {
    try {
      final m = await _network.invokeMapMethod<String, Object?>('info');
      return m?['wifi'] == true;
    } catch (_) {
      return false;
    }
  }

  bool get _playing => _handler?.playbackState.value.playing ?? false;

  /// One automatic round: check, download on Wi-Fi, install when idle.
  Future<void> _autoRound() async {
    if (!state.auto || _busy) return;
    if (!await _onWifi()) return;
    final info = await check(quiet: true);
    if (info == null) return;
    if (!await download(info)) return;
    // Wait until nothing is playing (checked every two minutes).
    while (_playing) {
      await Future<void>.delayed(const Duration(minutes: 2));
      if (!state.auto) return;
    }
    await install();
  }

  /// Asks GitHub for a newer stable build.
  Future<UpdateInfo?> check({bool quiet = false}) async {
    if (_busy) return state.info;
    state = state.copyWith(phase: UpdatePhase.checking);
    try {
      final res = await _http.get(Uri.parse(kReleasesApi), headers: {
        'Accept': 'application/vnd.github+json'
      }).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final info = newestStableUpdate(jsonDecode(res.body), _current);
      if (info == null) {
        state = state.copyWith(phase: UpdatePhase.upToDate);
        return null;
      }
      nlog('[N] update: build ${info.build} available (this is $_current)');
      final ready = _apk != null && state.info?.build == info.build;
      state = state.copyWith(
          phase: ready ? UpdatePhase.ready : UpdatePhase.available, info: info);
      return info;
    } catch (e) {
      nlog('[N] update check failed: $e');
      state = state.copyWith(
          phase: quiet ? UpdatePhase.idle : UpdatePhase.failed,
          message: 'Could not check for updates right now.');
      return null;
    }
  }

  /// Downloads [info]'s APK and checks its SHA-256. True when ready.
  Future<bool> download(UpdateInfo info) async {
    if (_busy) return false;
    if (_apk != null && state.info?.build == info.build) return true;
    _busy = true;
    state =
        state.copyWith(phase: UpdatePhase.downloading, info: info, progress: 0);
    IOSink? sink;
    try {
      final dir = await _tempDir();
      final file = File('${dir.path}/noor-update-${info.build}.apk');
      final res = await _http.send(http.Request('GET', info.apkUrl));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      sink = file.openWrite();
      var got = 0;
      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (got > info.size + 1024) throw StateError('larger than announced');
        state = state.copyWith(
            phase: UpdatePhase.downloading, progress: got / info.size);
      }
      await sink.close();
      sink = null;
      hasher.close();
      final hash = digest.events.single.toString();
      if (got != info.size || (info.sha256 != null && hash != info.sha256)) {
        await file.delete().catchError((_) => file);
        throw StateError('the download does not match the release');
      }
      _apk = file;
      nlog('[N] update: build ${info.build} downloaded and checked');
      state = state.copyWith(phase: UpdatePhase.ready, progress: 1);
      return true;
    } catch (e) {
      await sink?.close().catchError((_) {});
      nlog('[N] update download failed: $e');
      state = state.copyWith(
          phase: UpdatePhase.failed,
          message: 'The update could not be downloaded.');
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Installs the downloaded update (Noor closes and restarts).
  Future<void> install() async {
    final apk = _apk;
    if (apk == null) return;
    try {
      final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
      if (!allowed) {
        state = state.copyWith(phase: UpdatePhase.needsPermission);
        return;
      }
      state = state.copyWith(phase: UpdatePhase.installing);
      nlog('[N] update: installing build ${state.info?.build}');
      await _channel.invokeMethod<void>('install', {'path': apk.path});
    } catch (e) {
      nlog('[N] update install failed: $e');
      state = state.copyWith(
          phase: UpdatePhase.failed,
          message: 'The update could not be installed.');
    }
  }

  /// Opens Android's "Install unknown apps" page for Noor.
  Future<void> allowInstalls() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } catch (_) {}
  }

  void _onInstallStatus(Object? args) {
    final m = args is Map ? args : const {};
    final status = m['status'];
    nlog('[N] update install status: $status ${m['message'] ?? ''}');
    switch (status) {
      case 'pending_user':
        // Android asked the user; if they say no, it waits here.
        state = state.copyWith(phase: UpdatePhase.ready);
      case 'success':
        break; // Noor is being replaced and restarts.
      default:
        state = state.copyWith(
            phase: UpdatePhase.ready,
            message: 'The update was not installed. Tap to try again.');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}

/// Collects a single result from a chunked hash.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}

final updaterProvider = StateNotifierProvider<Updater, UpdateState>((ref) {
  NebulaAudioHandler? h;
  try {
    h = ref.read(audioHandlerProvider);
  } catch (_) {}
  return Updater(h);
});
