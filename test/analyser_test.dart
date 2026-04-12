import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

// ---------------------------------------------------------------------------
// WAV builder helpers (mirrors pattern from wav_decoder_test.dart)
// ---------------------------------------------------------------------------

/// Build a mono 16-bit PCM WAV from normalised float samples.
Uint8List buildWav16MonoFromFloats(
  List<double> floats, {
  int sampleRate = 44100,
}) {
  final dataSize = floats.length * 2;
  final fileSize = 36 + dataSize;
  final buf = Uint8List(fileSize + 8);
  final bd = ByteData.sublistView(buf);
  int pos = 0;

  void writeFourCC(String s) {
    for (final c in s.codeUnits) {
      buf[pos++] = c;
    }
  }

  void writeU16(int v) {
    bd.setUint16(pos, v, Endian.little);
    pos += 2;
  }

  void writeU32(int v) {
    bd.setUint32(pos, v, Endian.little);
    pos += 4;
  }

  writeFourCC('RIFF');
  writeU32(fileSize);
  writeFourCC('WAVE');
  writeFourCC('fmt ');
  writeU32(16);
  writeU16(1); // PCM
  writeU16(1); // mono
  writeU32(sampleRate);
  writeU32(sampleRate * 2); // byte rate
  writeU16(2); // block align
  writeU16(16); // bit depth
  writeFourCC('data');
  writeU32(dataSize);

  for (final f in floats) {
    final clamped = f.clamp(-1.0, 1.0);
    final intVal = (clamped * 32767).round();
    writeU16(intVal & 0xFFFF);
  }
  return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('analyseBytes() – synthetic click', () {
    test('returns defects for WAV containing a click', () async {
      // 1 second of sine wave with a click injected
      const sampleRate = 44100;
      final floats = List<double>.generate(
        sampleRate,
        (i) => 0.1 * math.sin(2 * math.pi * 440 * i / sampleRate),
      );
      // Inject a sharp click
      floats[10000] = 0.98;
      floats[10001] = -0.98;

      final wav = buildWav16MonoFromFloats(floats, sampleRate: sampleRate);
      final result = await analyseBytes(
        wav,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(result.defects, isNotEmpty);
      expect(result.metadata.sampleRate, equals(sampleRate));
      expect(result.metadata.channels, equals(1));
    });
  });

  group('analyseBytes() – silent WAV', () {
    test('returns no defects for silence', () async {
      const sampleRate = 44100;
      final floats = List<double>.filled(sampleRate, 0.0);
      final wav = buildWav16MonoFromFloats(floats, sampleRate: sampleRate);

      final result = await analyseBytes(wav);
      expect(result.defects, isEmpty);
      expect(result.aggregateConfidence, equals(0.0));
    });
  });

  group('analyseBytes() – invalid input', () {
    test('throws UnsupportedFormatException on empty bytes', () async {
      expect(
        () => analyseBytes(Uint8List(0)),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('throws UnsupportedFormatException on non-WAV bytes', () async {
      final garbage = Uint8List.fromList(
        List.generate(256, (i) => i % 256),
      );
      expect(
        () => analyseBytes(garbage),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('throws CorruptFileException on truncated WAV', () async {
      // Valid RIFF/WAVE header but truncated before fmt data
      final buf = Uint8List(20);
      final bd = ByteData.sublistView(buf);
      int pos = 0;

      void writeFourCC(String s) {
        for (final c in s.codeUnits) {
          buf[pos++] = c;
        }
      }

      writeFourCC('RIFF');
      bd.setUint32(pos, 12, Endian.little);
      pos += 4;
      writeFourCC('WAVE');
      // fmt chunk header but no data
      writeFourCC('fmt ');
      bd.setUint32(pos, 16, Endian.little);
      pos += 4;
      // Truncated — no actual fmt payload

      expect(
        () => analyseBytes(buf),
        throwsA(isA<CorruptFileException>()),
      );
    });
  });
}
