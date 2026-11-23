import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The phone's media volume, 0–1: follows the volume buttons, and can be
/// set from Noor's volume bar. Null where it cannot be read (tests, other
/// platforms).
class PhoneVolumeNotifier extends StateNotifier<double?> {
  PhoneVolumeNotifier() : super(null) {
    _sub = _changes.receiveBroadcastStream().listen((v) {
      if (v is num && mounted && !_dragging) state = v.toDouble();
    }, onError: (Object _) {});
  }

  static const _channel = MethodChannel('noor/volume');
  static const _changes = EventChannel('noor/volume/changes');
  StreamSubscription<dynamic>? _sub;
  bool _dragging = false;
  double? _pending;
  bool _sending = false;

  /// While the bar is held, the phone's own reports do not move it.
  void hold(bool held) => _dragging = held;

  /// Sets the volume (the bar moves at once; the phone follows).
  Future<void> set(double v) async {
    state = v.clamp(0.0, 1.0);
    _pending = state;
    if (_sending) return;
    _sending = true;
    try {
      while (_pending != null) {
        final next = _pending!;
        _pending = null;
        await _channel.invokeMethod<double>('set', {'value': next});
      }
    } catch (_) {
    } finally {
      _sending = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final phoneVolumeProvider = StateNotifierProvider<PhoneVolumeNotifier, double?>(
    (ref) => PhoneVolumeNotifier());

/// The volume bar's dot: blue up to 60 %, red above.
const double kLoudVolume = 0.6;
