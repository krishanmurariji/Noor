import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/settings_screen.dart' show NoorToggle;
import '../services/audio_handler.dart';
import '../services/equalizer_settings.dart';
import '../theme/noor_palette.dart';
import '../theme/noor_song_card.dart';

/// Where the record player's knob points for [eq]: off → 0, then through
/// the presets, Custom at the far right.
double knobTurnFor(EqState eq) {
  if (!eq.on) return 0;
  if (eq.preset == kEqCustom) return 1;
  final i = kEqPresets.indexWhere((p) => p.name == eq.preset);
  return (i + 1) / (kEqPresets.length + 1);
}

/// The equalizer, opened from the knob on the record player: on/off,
/// presets, and the phone's bands to fine-tune. On Samsung phones, where
/// Noor's equalizer silences playback, Samsung's own equalizer opens instead
/// (it applies to Noor's music).
Future<void> showEqualizer(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (await container.read(systemEqualizerProvider.future)) {
    try {
      final opened =
          await container.read(audioHandlerProvider).openSystemEqualizer();
      if (opened) return;
    } catch (_) {}
  }
  if (!context.mounted) return;
  final t = NoorTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.bg,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: t.ac, width: 0.8)),
    builder: (_) => const SafeArea(child: EqualizerPanel()),
  );
}

class EqualizerPanel extends ConsumerWidget {
  const EqualizerPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoorTheme.of(context);
    final eq = ref.watch(equalizerProvider);
    final n = ref.read(equalizerProvider.notifier);
    final gains = eq.gains;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('Equalizer', style: noorSongTitleStyle(t.ac, size: 26)),
          ),
          NoorToggle(
            key: const ValueKey('eq-on'),
            label: 'Equalizer',
            value: eq.on,
            onChanged: n.setOn,
          ),
        ]),
        const SizedBox(height: 14),
        // Presets.
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in [
            ...kEqPresets.map((p) => p.name),
            if (eq.preset == kEqCustom) kEqCustom,
          ])
            _Chip(
              label: p,
              selected: eq.on && eq.preset == p,
              onTap: () {
                HapticFeedback.selectionClick();
                if (p != kEqCustom) n.choose(p);
              },
            ),
        ]),
        const SizedBox(height: 20),
        // The phone's bands.
        if (eq.bands.isEmpty)
          Text('Play a song to fine-tune each band.',
              style: TextStyle(color: t.mute, fontSize: 12.5))
        else
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: eq.on ? 1 : 0.45,
            child: SizedBox(
              height: 200,
              child: Row(children: [
                for (var i = 0; i < eq.bands.length; i++)
                  Expanded(
                    child: Column(children: [
                      Text(
                          '${gains[i] > 0 ? '+' : ''}${gains[i].toStringAsFixed(gains[i].abs() < 10 ? 1 : 0)}',
                          style: TextStyle(
                              color: t.ac,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              activeTrackColor: t.ac,
                              inactiveTrackColor: t.faint,
                              thumbColor: t.ac,
                              overlayColor: t.wash,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                            ),
                            child: Slider(
                              key: ValueKey('eq-band-$i'),
                              min: eq.minDb,
                              max: eq.maxDb,
                              value: gains[i].clamp(eq.minDb, eq.maxDb),
                              onChanged: (v) => n.setBand(i, v),
                            ),
                          ),
                        ),
                      ),
                      Text(bandLabel(eq.bands[i]),
                          style: TextStyle(
                              color: t.mute,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 6),
        Center(
          child:
              Text('Hz · dB', style: TextStyle(color: t.mute, fontSize: 10.5)),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NoorTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? t.ac : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? t.ac : t.soft, width: 1),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? t.onAc : t.ac,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}
