import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

import 'flac_fixtures.dart';

void main() {
  group('decodeFlac – metadata', () {
    test('decodes 16-bit stereo STREAMINFO', () async {
      final data =
          decodeFlac(await flacFixtureBytes('sine_clean_16_stereo.flac'));
      expect(data.metadata.sampleRate, 8000);
      expect(data.metadata.channels, 2);
      expect(data.metadata.bitDepth, 16);
      expect(data.metadata.duration, const Duration(milliseconds: 250));
      expect(data.samples, hasLength(2));
      expect(data.samples[0], hasLength(2000));
      expect(data.samples[1], hasLength(2000));
    });

    test('decodes a mono stream', () async {
      final data = decodeFlac(await flacFixtureBytes('sine_16_mono.flac'));
      expect(data.metadata.channels, 1);
      expect(data.samples, hasLength(1));
      expect(data.samples[0], hasLength(2000));
    });

    test('reports 24-bit depth', () async {
      final data = decodeFlac(await flacFixtureBytes('sine_24_stereo.flac'));
      expect(data.metadata.bitDepth, 24);
      expect(data.metadata.channels, 2);
      expect(data.samples[0], hasLength(2000));
    });
  });

  group('decodeFlac – samples', () {
    test('all samples are normalised to [-1.0, 1.0]', () async {
      for (final name in [
        'sine_clean_16_stereo.flac',
        'sine_16_mono.flac',
        'sine_24_stereo.flac',
      ]) {
        final data = decodeFlac(await flacFixtureBytes(name));
        for (final channel in data.samples) {
          for (final s in channel) {
            expect(s, inInclusiveRange(-1.0, 1.0), reason: name);
          }
        }
      }
    });

    test('lossless round-trip preserves the injected click', () async {
      final data =
          decodeFlac(await flacFixtureBytes('sine_click_16_stereo.flac'));
      // The fixture injects a +0.9 / -0.9 click at sample 1000 on both channels.
      expect(data.samples[0][1000], closeTo(0.9, 0.005));
      expect(data.samples[0][1001], closeTo(-0.9, 0.005));
      expect(data.samples[1][1000], closeTo(0.9, 0.005));
      expect(data.samples[1][1001], closeTo(-0.9, 0.005));
    });

    test('clean fixture stays well below full scale', () async {
      final data =
          decodeFlac(await flacFixtureBytes('sine_clean_16_stereo.flac'));
      // The background tone is a 0.3-amplitude sine; nothing should approach 1.
      for (final s in data.samples[0]) {
        expect(s.abs(), lessThan(0.5));
      }
    });
  });

  group('decodeFlac – error handling', () {
    test('throws CorruptFileException on empty input', () {
      expect(
          () => decodeFlac(Uint8List(0)), throwsA(isA<CorruptFileException>()));
    });

    test('throws CorruptFileException on non-FLAC data', () {
      final bytes = Uint8List.fromList(List.filled(64, 0x00));
      expect(() => decodeFlac(bytes), throwsA(isA<CorruptFileException>()));
    });

    test('throws CorruptFileException on a truncated stream', () async {
      // Keep the "fLaC" marker but cut off inside the STREAMINFO block.
      final full = await flacFixtureBytes('sine_clean_16_stereo.flac');
      final truncated = Uint8List.sublistView(full, 0, 20);
      expect(() => decodeFlac(truncated), throwsA(isA<CorruptFileException>()));
    });
  });
}
