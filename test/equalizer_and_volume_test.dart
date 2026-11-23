import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor/services/equalizer_settings.dart';
import 'package:noor/theme/noor_turntable.dart';
import 'package:noor/widgets/equalizer_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const phoneBands = [60.0, 230.0, 910.0, 3600.0, 14000.0];

void main() {
  group('presets', () {
    test('read off a smooth curve at any band', () {
      final rock = presetNamed('Rock')!;
      for (var i = 0; i < kEqReferenceHz.length; i++) {
        expect(presetGainAt(rock, kEqReferenceHz[i]), rock.gains[i]);
      }
      expect(presetGainAt(rock, 20), rock.gains.first); // flat past the ends
      expect(presetGainAt(rock, 20000), rock.gains.last);
      final mid = presetGainAt(presetNamed('Bass Boost')!, 120);
      expect(mid, inExclusiveRange(3, 5)); // between 60 Hz (+5) and 230 Hz (+3)
    });

    test('never boost more than 5 dB (loud songs would distort)', () {
      for (final p in kEqPresets) {
        expect(p.gains.length, 5, reason: p.name);
        expect(p.gains.every((g) => g <= 5 && g >= -5), isTrue, reason: p.name);
      }
      expect(kEqPresets.first.name, 'Flat');
    });

    test('band labels', () {
      expect([for (final b in phoneBands) bandLabel(b)],
          ['60', '230', '910', '3.6k', '14k']);
    });

    test('a saved setting survives junk', () {
      expect(EqState.fromJson('x').preset, 'Flat');
      expect(EqState.fromJson({'on': true, 'preset': 'Nope'}).preset, 'Flat');
      final s = EqState.fromJson({
        'on': true,
        'preset': 'Custom',
        'custom': [1, 'x', 2.5]
      });
      expect(s.on, isTrue);
      expect(s.custom, [1.0, 0.0, 2.5]);
    });

    test('the knob turns with the preset', () {
      expect(knobTurnFor(const EqState()), 0);
      final rock = knobTurnFor(const EqState(on: true, preset: 'Rock'));
      final flat = knobTurnFor(const EqState(on: true, preset: 'Flat'));
      expect(rock, greaterThan(flat));
      expect(knobTurnFor(const EqState(on: true, preset: kEqCustom)), 1);
    });
  });

  group('the setting', () {
    test('switching on, or choosing a preset while off, refreshes the audio path',
        () async {
      SharedPreferences.setMockInitialValues({});
      var refreshed = 0;
      final n = EqualizerNotifier(null, onSwitched: () async => refreshed++);
      await Future<void>.delayed(Duration.zero);
      await n.choose('Rock'); // off → on
      expect(refreshed, 1);
      await n.choose('Pop'); // already on: no refresh needed
      expect(refreshed, 1);
      await n.setOn(false);
      await n.setOn(true);
      expect(refreshed, 3);
    });

    test('choose, fine-tune (becomes Custom), and it is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final n = EqualizerNotifier(null);
      await Future<void>.delayed(Duration.zero);
      // Pretend the phone reported its bands.
      n.state = n.state.copyWith(bands: phoneBands, minDb: -15, maxDb: 15);

      await n.choose('Vocal');
      expect(n.state.on, isTrue);
      expect(n.state.gains, presetNamed('Vocal')!.gains);

      await n.setBand(0, 6);
      expect(n.state.preset, kEqCustom);
      expect(n.state.gains, [6, -1, 3, 4, 1]); // the rest keep Vocal's curve
      await n.setBand(4, 99);
      expect(n.state.gains.last, 15); // limited to what the phone allows

      final again = EqualizerNotifier(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(again.state.on, isTrue);
      expect(again.state.preset, kEqCustom);
      expect(again.state.custom, [6, -1, 3, 4, 15]);
    });
  });

  group('the record player', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('drag the slider up for louder, tap the knob for the equalizer',
        (tester) async {
      final vols = <double>[];
      final holds = <bool>[];
      var knob = 0;
      await tester.pumpWidget(host(NoorTurntable(
        size: 360,
        artUrl: '',
        spinning: false,
        armDown: false,
        volume: 0.3,
        onVolume: vols.add,
        onVolumeHold: holds.add,
        onKnob: () => knob++,
      )));

      final slider = find.byKey(const ValueKey('volume-slider'));
      expect(slider, findsOneWidget);
      await tester.drag(slider, const Offset(0, -40));
      expect(vols, isNotEmpty);
      expect(vols.last, greaterThan(vols.first)); // up = louder
      expect(holds, [true, false]);

      await tester.tap(find.byKey(const ValueKey('eq-knob')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(knob, 1);
    });

    test('top of the slider is loudest; the dot turns red above 60 %', () {
      expect(NoorTurntable.volumeAt(NoorTurntable.sliderTop), 1);
      expect(NoorTurntable.volumeAt(NoorTurntable.sliderBottom), 0);
      expect(NoorTurntable.volumeAt(0), 1); // past the top: still 100 %
      expect(NoorTurntable.volumeDot(0.6), const Color(0xFF3D7BE0));
      expect(NoorTurntable.volumeDot(0.0), const Color(0xFF3D7BE0));
      expect(NoorTurntable.volumeDot(0.61), const Color(0xFFD2412F));
    });
  });

  testWidgets('the equalizer panel: pick a preset, it switches on',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      overrides: [
        equalizerProvider.overrideWith((ref) => EqualizerNotifier(null))
      ],
      child: const MaterialApp(home: Scaffold(body: EqualizerPanel())),
    ));
    await tester.pump();
    expect(find.text('Equalizer'), findsOneWidget);
    for (final p in kEqPresets) {
      expect(find.text(p.name), findsOneWidget);
    }
    expect(find.text('Play a song to fine-tune each band.'), findsOneWidget);
    await tester.tap(find.text('Rock'));
    await tester.pump();
    final c =
        ProviderScope.containerOf(tester.element(find.byType(EqualizerPanel)));
    expect(c.read(equalizerProvider).on, isTrue);
    expect(c.read(equalizerProvider).preset, 'Rock');
  });
}
