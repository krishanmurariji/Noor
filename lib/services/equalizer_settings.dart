import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'audio_handler.dart';

/// Settings key for the equalizer.
const kEqualizerKey = 'noor_equalizer';

/// A preset: gains in dB at five reference frequencies. Phones have their
/// own bands (usually five, not always at these frequencies), so a preset is
/// read off a smooth curve through these points ([presetGainAt]).
///
/// Boosts stay at +5 dB or less: bigger boosts make loud songs distort.
class EqPreset {
  const EqPreset(this.name, this.gains);
  final String name;
  final List<double> gains;
}

const kEqReferenceHz = [60.0, 230.0, 910.0, 3600.0, 14000.0];

const kEqPresets = [
  EqPreset('Flat', [0, 0, 0, 0, 0]),
  EqPreset('Bass Boost', [5, 3, 0, 0, 0]),
  EqPreset('Vocal', [-2, -1, 3, 4, 1]),
  EqPreset('Bollywood', [3, 1, 0, 2, 2]),
  EqPreset('Pop', [-1, 2, 3, 2, -1]),
  EqPreset('Rock', [4, 2, -1, 2, 4]),
  EqPreset('Electronic', [5, 2, 0, 2, 4]),
  EqPreset('Acoustic', [2, 1, 2, 2, 3]),
  EqPreset('Classical', [3, 1, -1, 1, 3]),
  EqPreset('Late Night', [-3, 0, 2, 1, -2]),
];

/// The custom setting's name (bands moved by hand).
const kEqCustom = 'Custom';

/// [preset]'s gain at [hz]: straight lines between the reference points on
/// a log-frequency scale, flat beyond the ends.
double presetGainAt(EqPreset preset, double hz) {
  final f = kEqReferenceHz;
  final g = preset.gains;
  if (hz <= f.first) return g.first;
  if (hz >= f.last) return g.last;
  for (var i = 0; i < f.length - 1; i++) {
    if (hz <= f[i + 1]) {
      final a = math.log(f[i]), b = math.log(f[i + 1]);
      final t = (math.log(hz) - a) / (b - a);
      return g[i] + (g[i + 1] - g[i]) * t;
    }
  }
  return g.last;
}

EqPreset? presetNamed(String name) {
  for (final p in kEqPresets) {
    if (p.name == name) return p;
  }
  return null;
}

/// Short label for a band: "60", "230", "3.6k", "14k".
String bandLabel(double hz) {
  if (hz >= 1000) {
    final k = hz / 1000;
    return '${k >= 10 ? k.round() : (k * 10).round() / 10}k'
        .replaceAll('.0k', 'k');
  }
  return '${hz.round()}';
}

/// just_audio passes Android's band levels as millibels / 1000, i.e. in
/// units of 10 dB (+15 dB arrives as 1.5). Noor works in dB and converts.
const double kJustAudioGainUnit = 10;

/// What the user chose.
class EqState {
  const EqState({
    this.on = false,
    this.preset = 'Flat',
    this.custom = const [],
    this.bands = const [],
    this.minDb = -15,
    this.maxDb = 15,
  });

  final bool on;
  final String preset;

  /// Gains (dB) per band for [kEqCustom], in band order.
  final List<double> custom;

  /// The phone's bands (centre frequencies, Hz). Empty until the player has
  /// started once (Android reports them then).
  final List<double> bands;
  final double minDb, maxDb;

  /// The gain for each of the phone's bands.
  List<double> get gains => [
        for (var i = 0; i < bands.length; i++)
          (preset == kEqCustom
                  ? (i < custom.length ? custom[i] : 0.0)
                  : presetGainAt(
                      presetNamed(preset) ?? kEqPresets.first, bands[i]))
              .clamp(minDb, maxDb)
              .toDouble(),
      ];

  EqState copyWith({
    bool? on,
    String? preset,
    List<double>? custom,
    List<double>? bands,
    double? minDb,
    double? maxDb,
  }) =>
      EqState(
        on: on ?? this.on,
        preset: preset ?? this.preset,
        custom: custom ?? this.custom,
        bands: bands ?? this.bands,
        minDb: minDb ?? this.minDb,
        maxDb: maxDb ?? this.maxDb,
      );

  Map<String, Object?> toJson() =>
      {'on': on, 'preset': preset, 'custom': custom};

  static EqState fromJson(Object? j) {
    if (j is! Map) return const EqState();
    final preset = j['preset'];
    final custom = j['custom'];
    return EqState(
      on: j['on'] == true,
      preset: preset is String &&
              (preset == kEqCustom || presetNamed(preset) != null)
          ? preset
          : 'Flat',
      custom: custom is List
          ? [for (final v in custom) (v is num ? v.toDouble() : 0.0)]
          : const [],
    );
  }
}

/// The equalizer setting, saved, and applied to the player.
class EqualizerNotifier extends StateNotifier<EqState> {
  EqualizerNotifier(this._eq, {Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance,
        super(const EqState()) {
    unawaited(_load());
  }

  /// Null where there is no Android equalizer (tests, other platforms).
  final AndroidEqualizer? _eq;
  final Future<SharedPreferences> Function() _prefs;
  AndroidEqualizerParameters? _params;

  Future<void> _load() async {
    try {
      final p = await _prefs();
      final raw = p.getString(kEqualizerKey);
      if (raw != null && mounted) {
        final saved = EqState.fromJson(jsonDecode(raw));
        state = saved.copyWith(
            bands: state.bands, minDb: state.minDb, maxDb: state.maxDb);
      }
    } catch (_) {}
    unawaited(_apply());
    // The phone's bands are known once the player has started.
    final eq = _eq;
    if (eq == null) return;
    try {
      final params = await eq.parameters;
      _params = params;
      if (!mounted) return;
      state = state.copyWith(
        bands: [for (final b in params.bands) b.centerFrequency],
        minDb: params.minDecibels * kJustAudioGainUnit,
        maxDb: params.maxDecibels * kJustAudioGainUnit,
      );
      await _apply();
    } catch (e) {
      nlog('[N] equalizer not available: $e');
    }
  }

  Future<void> _save() async {
    try {
      final p = await _prefs();
      await p.setString(kEqualizerKey, jsonEncode(state.toJson()));
    } catch (_) {}
  }

  Future<void> _apply() async {
    final eq = _eq;
    if (eq == null) return;
    try {
      await eq.setEnabled(state.on);
      final params = _params;
      if (params == null) return;
      final g = state.gains;
      for (var i = 0; i < params.bands.length && i < g.length; i++) {
        await params.bands[i].setGain(g[i] / kJustAudioGainUnit);
      }
    } catch (e) {
      nlog('[N] equalizer: $e');
    }
  }

  Future<void> setOn(bool on) async {
    state = state.copyWith(on: on);
    await _apply();
    await _save();
  }

  /// Picks a preset (and switches the equalizer on).
  Future<void> choose(String preset) async {
    state = state.copyWith(preset: preset, on: true);
    await _apply();
    await _save();
  }

  /// Moves one band by hand: the setting becomes Custom, starting from the
  /// curve that was showing.
  Future<void> setBand(int index, double db) async {
    final g = [...state.gains];
    if (index < 0 || index >= g.length) return;
    g[index] = db.clamp(state.minDb, state.maxDb).toDouble();
    state = state.copyWith(preset: kEqCustom, custom: g, on: true);
    await _apply();
    await _save();
  }
}

final equalizerProvider =
    StateNotifierProvider<EqualizerNotifier, EqState>((ref) {
  AndroidEqualizer? eq;
  try {
    eq = ref.read(audioHandlerProvider).equalizer;
  } catch (_) {}
  return EqualizerNotifier(eq);
});
