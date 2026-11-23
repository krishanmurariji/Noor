import 'dart:async';

import 'package:flutter/services.dart';

/// Completes once Noor's Android side answers on its channels.
///
/// With background audio, Flutter starts before the Android activity has
/// registered its channels. Listening to an event channel that early fails
/// quietly (reported, not retried), so Noor never heard earbuds connect.
/// Everything that listens at start-up waits for this first. Gives up
/// (returns false) after [patience].
Future<bool> nativeReady({Duration patience = const Duration(minutes: 2)}) {
  return _ready ??= _probe(patience);
}

Future<bool>? _ready;

Future<bool> _probe(Duration patience) async {
  const probe = MethodChannel('noor/network');
  final until = DateTime.now().add(patience);
  while (DateTime.now().isBefore(until)) {
    try {
      await probe.invokeMethod<Object?>('info');
      return true;
    } on MissingPluginException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } catch (_) {
      return true; // it answered, even if with an error
    }
  }
  _ready = null; // try again next time someone asks
  return false;
}
