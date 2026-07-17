import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import '../tool/wav_writer.dart';

void main() {
  test('buildWav output round-trips through decodeWav', () {
    final left = List<double>.generate(100, (i) => (i % 20) / 20 - 0.5);
    final right = List<double>.generate(100, (i) => -((i % 10) / 10 - 0.5));

    final bytes = buildWav(
      channels: [left, right],
      bitsPerSample: 16,
      sampleRate: 44100,
    );
    final wav = decodeWav(bytes);

    expect(wav.metadata.sampleRate, 44100);
    expect(wav.metadata.channels, 2);
    expect(wav.metadata.bitDepth, 16);
    expect(wav.samples[0].length, 100);
    for (var i = 0; i < 100; i++) {
      expect(wav.samples[0][i], closeTo(left[i], 1 / 32767 + 1e-6));
      expect(wav.samples[1][i], closeTo(right[i], 1 / 32767 + 1e-6));
    }
  });

  test('buildWav clamps out-of-range samples instead of wrapping', () {
    final bytes = buildWav(
      channels: [
        [1.5, -1.5, 0.0]
      ],
      bitsPerSample: 16,
      sampleRate: 8000,
    );
    final wav = decodeWav(bytes);
    expect(wav.samples[0][0], closeTo(1.0, 0.001));
    expect(wav.samples[0][1], closeTo(-1.0, 0.001));
    expect(wav.samples[0][2], closeTo(0.0, 0.001));
  });
}
