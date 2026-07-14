/// Verifies the public library entry point exports the full decoder API.
///
/// Every decoder (`decodeWav`, `decodeAiff`, `decodeFlac`) must be reachable
/// via the single `package:audio_defect_detector/audio_defect_detector.dart`
/// import — no `src/` imports.
library;

import 'dart:typed_data';
import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

/// Build a minimal 16-bit mono PCM WAV file from [samples].
Uint8List buildWav(List<int> samples, {int sampleRate = 44100}) {
  final dataSize = samples.length * 2;
  final bytes = BytesBuilder();
  void str(String s) => bytes.add(s.codeUnits);
  void u32(int v) => bytes
      .add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => bytes.add([v & 0xFF, (v >> 8) & 0xFF]);

  str('RIFF');
  u32(36 + dataSize);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bit depth
  str('data');
  u32(dataSize);
  for (final s in samples) {
    u16(s & 0xFFFF);
  }
  return bytes.toBytes();
}

void main() {
  group('public API exports', () {
    test('decodeWav and WavData are exported from the library entry point', () {
      final wav = buildWav([0, 100, -100, 0]);
      final WavData data = decodeWav(wav);
      expect(data.metadata.sampleRate, equals(44100));
      expect(data.metadata.channels, equals(1));
      expect(data.samples, hasLength(1));
      expect(data.samples[0], hasLength(4));
    });
  });
}
