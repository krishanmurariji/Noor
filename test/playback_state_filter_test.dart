import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noor/services/audio_handler.dart';

void main() {
  final playing = PlaybackState(
    controls: [MediaControl.skipToPrevious, MediaControl.pause],
    processingState: AudioProcessingState.ready,
    playing: true,
    updatePosition: const Duration(seconds: 30),
    bufferedPosition: const Duration(seconds: 60),
    queueIndex: 2,
  );

  test('the buffer growing a little does not reach Android', () {
    final next = playing.copyWith(
        updatePosition: playing.position,
        bufferedPosition: const Duration(seconds: 62));
    expect(NebulaAudioHandler.sameForControls(playing, next), isTrue);
  });

  test('pause, a new song, a seek or a big buffer change do', () {
    expect(
        NebulaAudioHandler.sameForControls(
            playing,
            playing.copyWith(
                playing: false,
                controls: [MediaControl.skipToPrevious, MediaControl.play])),
        isFalse);
    expect(
        NebulaAudioHandler.sameForControls(
            playing, playing.copyWith(queueIndex: 3)),
        isFalse);
    expect(
        NebulaAudioHandler.sameForControls(playing,
            playing.copyWith(updatePosition: const Duration(seconds: 90))),
        isFalse);
    expect(
        NebulaAudioHandler.sameForControls(
            playing,
            playing.copyWith(
                updatePosition: playing.position,
                bufferedPosition: const Duration(seconds: 120))),
        isFalse);
  });
}
