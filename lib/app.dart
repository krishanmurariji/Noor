import 'dart:math' as math;
import 'widgets/noor_toast.dart';
import 'widgets/offline_pill.dart';
import 'widgets/buds_popup.dart';
import 'widgets/room_sheet.dart';
import 'providers/room_provider.dart';
import 'services/rooms/room.dart';
import 'services/audio_devices.dart';
import 'services/updater.dart';
import 'services/app_log.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/song.dart';
import 'providers/last_played_provider.dart';
import 'providers/library_provider.dart';
import 'providers/player_provider.dart';
import 'providers/queue_rules.dart';
import 'theme/noor_palette.dart';
import 'providers/theme_provider.dart';
import 'screens/main_shell.dart';

final GlobalKey<ScaffoldMessengerState> _messengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// Earbuds / headphones connecting or disconnecting (none in tests).
final audioDeviceChangesProvider =
    StreamProvider<AudioDeviceEvent>((ref) => audioDeviceChanges());

/// Shows the earbuds card. Connecting buds often happens from the quick
/// settings panel or with the phone's own buds pop-up on top, which makes
/// Noor "inactive" for a moment: the card shows then too. Only when Noor is
/// really in the background is it kept, and shown on coming back if that is
/// within 20 seconds.
final _budsAnnouncer = _BudsAnnouncer();

class _BudsAnnouncer {
  _BudsAnnouncer() {
    _listener = AppLifecycleListener(onResume: () {
      final p = _pending;
      _pending = null;
      if (p != null && DateTime.now().difference(p.$2).inSeconds <= 20) {
        _show(p.$1);
      }
    });
  }

  // ignore: unused_field
  late final AppLifecycleListener _listener;
  (AudioDeviceEvent, DateTime)? _pending;

  void announce(AudioDeviceEvent e) {
    final state = WidgetsBinding.instance.lifecycleState;
    nlog('[N] audio device ${e.connected ? 'connected' : 'disconnected'}: '
        '"${e.name}"${e.wired ? ' (wired)' : ''}, app $state');
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive ||
        state == null) {
      _show(e);
    } else {
      _pending = (e, DateTime.now());
    }
  }

  void _show(AudioDeviceEvent e) {
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay != null) BudsPopup.showIn(overlay, e);
  }
}

/// What decides the playing song's queue, as a key that changes only when
/// the queue should: which list it belongs to and, for a playlist, My
/// Favorites or My Music, that list's songs. For My History only the kind.
final _queueContextKeyProvider = Provider<String>((ref) {
  final song = ref.watch(playerProvider.select((s) => s.song));
  if (song == null) return '';
  final source = contextSourceFor(song,
      playlists: ref.watch(playlistProvider),
      liked: ref.watch(likedSongsProvider),
      onDevice: ref.watch(myMusicProvider));
  if (source.kind == 'history') return '${song.videoId}|history';
  final list = ref.read(playQueueProvider)(song);
  return '${song.videoId}|${source.kind}|${source.playlistId}|'
      '${list.map((s) => s.videoId).join(',')}';
});

class NebulaApp extends ConsumerWidget {
  const NebulaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    // Every song that starts playing goes to My History and is remembered
    // as the last played song (shown paused when the app opens again).
    ref.listen<Song?>(playerProvider.select((s) => s.song), (prev, song) {
      if (song == null || prev?.videoId == song.videoId) return;
      ref.read(historyProvider.notifier).add(song);
      ref.read(lastPlayedProvider.notifier).set(song);
    });
    // The queue follows the song's own list: when the playing song joins or
    // leaves a playlist or My Favorites (or that list changes), what plays
    // next becomes that list. History reordering itself as songs play does
    // not count (it would bounce between the last two songs).
    ref.listen<String>(_queueContextKeyProvider, (prev, next) {
      if (prev == null || prev == next) return;
      // In a room the listeners' queue is the star's.
      if (ref.read(roomProvider).isListener) return;
      // Only a change for the same song (a new song brought its queue).
      if (prev.split('|').first != next.split('|').first) return;
      final song = ref.read(playerProvider).song;
      if (song == null) return;
      final queue = ref.read(playQueueProvider)(song);
      if (queue.contains(song)) {
        ref.read(playerProvider.notifier).setQueueOrder(queue);
      }
    });
    ref.listen<String?>(playerProvider.select((s) => s.notice), (_, n) {
      if (n == null) return;
      final overlay = _navigatorKey.currentState?.overlay;
      if (overlay != null) NoorToast.showIn(overlay, n);
    });
    // Rooms: who wants in, requests, "you're the star now"… in the capsule.
    ref.listen<AsyncValue<RoomEvent>>(roomEventsProvider, (_, next) {
      final e = next.valueOrNull;
      final overlay = _navigatorKey.currentState?.overlay;
      if (e == null || overlay == null) return;
      final rooms = ref.read(roomProvider.notifier);
      final ask = e.text.startsWith('Ask ') ? rooms.takePendingAsk() : null;
      if (ask != null) {
        NoorToast.showIn(overlay, e.text,
            action: 'Ask', onAction: () => rooms.askForSong(ask));
      } else if (e.openRequests) {
        // Someone wants in, or asked for something: "See" answers it in a
        // pop-up in the middle of the screen.
        NoorToast.showIn(overlay, e.text, action: 'See', onAction: () {
          final ctx = _navigatorKey.currentContext;
          if (ctx != null) showRoomRequests(ctx);
        });
      } else if (e.openRoom) {
        NoorToast.showIn(overlay, e.text, action: 'See', onAction: () {
          final ctx = _navigatorKey.currentContext;
          if (ctx != null) showRoomSheet(ctx);
        });
      } else {
        NoorToast.showIn(overlay, e.text);
      }
    });
    // Earbuds connected / disconnected while Noor is on screen: the card.
    ref.listen<AsyncValue<AudioDeviceEvent>>(audioDeviceChangesProvider,
        (_, next) {
      final e = next.valueOrNull;
      if (e != null) _budsAnnouncer.announce(e);
    });
    // Updates: started with the app (checks, downloads on Wi-Fi, installs
    // when idle). Says so just before Noor restarts into the new build.
    ref.listen<UpdateState>(updaterProvider, (prev, next) {
      if (next.phase == UpdatePhase.installing &&
          prev?.phase != UpdatePhase.installing) {
        final overlay = _navigatorKey.currentState?.overlay;
        if (overlay != null) {
          NoorToast.showIn(
              overlay, 'Updating Noor to build ${next.info?.build ?? ''}…');
        }
      }
    });
    return MaterialApp(
      title: 'Noor',
      scaffoldMessengerKey: _messengerKey,
      navigatorKey: _navigatorKey,
      builder: (context, child) =>
          ResponsiveFrame(child: child ?? const SizedBox.shrink()),
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _light(),
      darkTheme: _dark(),
      // Going offline / back online is said once, in the top capsule.
      home: const NoorOfflineAnnouncer(child: MainShell()),
    );
  }

  ThemeData _light() => _themeFor(NoorTheme.light);
  ThemeData _dark() => _themeFor(NoorTheme.dark);

  ThemeData _themeFor(NoorTheme t) => ThemeData(
        useMaterial3: true,
        brightness: t.isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: t.bg,
        canvasColor: t.bg,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        textTheme:
            ThemeData(brightness: t.isDark ? Brightness.dark : Brightness.light)
                .textTheme
                .apply(bodyColor: t.ac, displayColor: t.ac),
        colorScheme: ColorScheme(
          brightness: t.isDark ? Brightness.dark : Brightness.light,
          primary: t.ac,
          onPrimary: t.bg,
          secondary: t.ac,
          onSecondary: t.bg,
          error: const Color(0xFFA83836),
          onError: Colors.white,
          surface: t.bg,
          onSurface: t.ac,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: t.ac,
          contentTextStyle: TextStyle(color: t.bg),
          behavior: SnackBarBehavior.floating,
        ),
      );
}

/// Widest the app content is allowed to get. The layouts are designed for a
/// phone; on tablets, unfolded foldables and large windows the content stays
/// phone-sized and centered instead of stretching into odd proportions.
const double kMaxContentWidth = 600;

/// Text-scale limits: below 0.85 text becomes unreadable, above 1.35 the fixed
/// phone layouts start to overflow. (The OS may still go higher or lower.)
const double kMinTextScale = 0.85;
const double kMaxTextScale = 1.35;

/// Makes the whole app behave on any screen:
///  * clamps the system font scale so layouts cannot overflow,
///  * caps and centers the content width on wide screens,
///  * lets tablets rotate while phones stay in portrait.
class ResponsiveFrame extends StatefulWidget {
  const ResponsiveFrame({super.key, required this.child});
  final Widget child;

  @override
  State<ResponsiveFrame> createState() => _ResponsiveFrameState();
}

class _ResponsiveFrameState extends State<ResponsiveFrame> {
  bool? _wasTablet;

  void _applyOrientation(bool isTablet) {
    if (_wasTablet == isTablet) return;
    _wasTablet = isTablet;
    SystemChrome.setPreferredOrientations(isTablet
        ? DeviceOrientation.values
        : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    _applyOrientation(mq.size.shortestSide >= 600);

    final width = math.min(mq.size.width, kMaxContentWidth);
    final data = mq.copyWith(
      size: Size(width, mq.size.height),
      textScaler: mq.textScaler
          .clamp(minScaleFactor: kMinTextScale, maxScaleFactor: kMaxTextScale),
    );

    Widget content = MediaQuery(data: data, child: widget.child);
    if (mq.size.width > kMaxContentWidth) {
      content = ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(child: SizedBox(width: width, child: content)),
      );
    }
    return content;
  }
}
