import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/src/wav_decoder.dart';
import 'package:audio_defect_detector/src/models.dart';

// ---------------------------------------------------------------------------
// WAV builder helper
// ---------------------------------------------------------------------------

/// Build a minimal 16-bit mono PCM WAV byte array from [samples].
Uint8List buildWav16Mono(List<int> samples, {int sampleRate = 44100}) {
  final dataSize = samples.length * 2;
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
  writeU32(16); // fmt chunk size
  writeU16(1); // PCM
  writeU16(1); // channels
  writeU32(sampleRate);
  writeU32(sampleRate * 2); // byte rate
  writeU16(2); // block align
  writeU16(16); // bit depth
  writeFourCC('data');
  writeU32(dataSize);
  for (final s in samples) {
    writeU16(s & 0xFFFF);
  }
  return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WAV decoder – basic', () {
    test('decodes 16-bit mono PCM header correctly', () {
      final samples = List.generate(44100, (i) => 0); // 1 s silence
      final wav = buildWav16Mono(samples, sampleRate: 44100);
      final data = decodeWav(wav);

      expect(data.metadata.sampleRate, equals(44100));
      expect(data.metadata.bitDepth, equals(16));
      expect(data.metadata.channels, equals(1));
      expect(data.metadata.duration.inSeconds, equals(1));
      expect(data.samples.length, equals(1)); // 1 channel
      expect(data.samples[0].length, equals(44100));
    });

    test('decodes silence as zeros', () {
      final samples = List.filled(1000, 0);
      final wav = buildWav16Mono(samples);
      final data = decodeWav(wav);
      for (final v in data.samples[0]) {
        expect(v, closeTo(0.0, 1e-4));
      }
    });

    test('decodes positive peak (32767) to ~1.0', () {
      const peak = 32767;
      final samples = [peak];
      final wav = buildWav16Mono(samples);
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(1.0, 0.0001));
    });

    test('decodes negative peak (-32768) to ~-1.0', () {
      // -32768 as two's complement unsigned 16-bit = 32768
      const peakNeg = 0x8000; // -32768 signed
      final samples = [peakNeg];
      final wav = buildWav16Mono(samples);
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(-1.0, 0.0001));
    });

    test('throws CorruptFileException on empty bytes', () {
      expect(
        () => decodeWav(Uint8List(0)),
        throwsA(isA<CorruptFileException>()),
      );
    });

    test('throws CorruptFileException on non-RIFF data', () {
      final bytes = Uint8List.fromList(List.filled(16, 0x00));
      expect(
        () => decodeWav(bytes),
        throwsA(isA<CorruptFileException>()),
      );
    });

    test('throws UnsupportedFormatException for unsupported audio format', () {
      // Build a WAV with audioFormat = 6 (A-law – not supported)
      final samples = List.filled(100, 0);
      final wav = buildWav16Mono(samples);
      // Patch audioFormat at offset 20 (little-endian uint16)
      final bd = ByteData.sublistView(wav);
      bd.setUint16(20, 6, Endian.little);
      expect(
        () => decodeWav(wav),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });
  });

  group('WAV decoder – stereo', () {
    test('decodes 16-bit stereo PCM', () {
      // Build stereo WAV manually
      final sampleRate = 44100;
      final numFrames = 100;
      final dataSize = numFrames * 4; // 2 ch * 2 bytes
      final fileSize = 36 + dataSize;
      final buf = Uint8List(fileSize + 8);
      final bd = ByteData.sublistView(buf);
      int pos = 0;

      void writeFCC(String s) {
        for (final c in s.codeUnits) { buf[pos++] = c; }
      }
      void u16(int v) { bd.setUint16(pos, v, Endian.little); pos += 2; }
      void u32(int v) { bd.setUint32(pos, v, Endian.little); pos += 4; }

      writeFCC('RIFF'); u32(fileSize); writeFCC('WAVE');
      writeFCC('fmt '); u32(16);
      u16(1); u16(2); u32(sampleRate); u32(sampleRate * 4); u16(4); u16(16);
      writeFCC('data'); u32(dataSize);
      for (int i = 0; i < numFrames; i++) {
        u16(1000 & 0xFFFF); // L
        u16(2000 & 0xFFFF); // R
      }

      final data = decodeWav(buf);
      expect(data.metadata.channels, equals(2));
      expect(data.samples.length, equals(2));
      expect(data.samples[0].length, equals(numFrames));
      expect(data.samples[1].length, equals(numFrames));
      // Left channel should be ~1000/32768
      expect(data.samples[0][0], closeTo(1000 / 32768.0, 1e-4));
      // Right channel should be ~2000/32768
      expect(data.samples[1][0], closeTo(2000 / 32768.0, 1e-4));
    });
  });
}
