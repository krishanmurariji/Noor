import 'dart:async';

import 'package:flutter/services.dart';

/// Earbuds or headphones connecting / disconnecting.
class AudioDeviceEvent {
  const AudioDeviceEvent(
      {required this.connected, required this.name, required this.wired});
  final bool connected;

  /// What the device calls itself ("Galaxy Buds3"); may be empty.
  final String name;

  /// Plugged in (wired / USB) rather than Bluetooth.
  final bool wired;

  static AudioDeviceEvent? fromMap(Object? m) {
    if (m is! Map) return null;
    final e = m['event'];
    if (e != 'connected' && e != 'disconnected') return null;
    return AudioDeviceEvent(
      connected: e == 'connected',
      name: (m['name'] as String?)?.trim() ?? '',
      wired: m['kind'] == 'wired',
    );
  }
}

/// The changes, as they happen (none for the devices already connected
/// when Noor starts). The same change reported twice within a moment
/// (Android sometimes does) comes through once.
Stream<AudioDeviceEvent> audioDeviceChanges() {
  const channel = EventChannel('noor/audio_devices');
  String? lastKey;
  var lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  return channel
      .receiveBroadcastStream()
      .map(AudioDeviceEvent.fromMap)
      .where((e) {
        if (e == null) return false;
        final key = '${e.connected}|${e.name}';
        final now = DateTime.now();
        final repeat =
            key == lastKey && now.difference(lastAt).inMilliseconds < 2000;
        lastKey = key;
        lastAt = now;
        return !repeat;
      })
      .cast<AudioDeviceEvent>()
      .handleError((Object _) {});
}
