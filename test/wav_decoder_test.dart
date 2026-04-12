import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/src/wav_decoder.dart';
import 'package:audio_defect_detector/src/models.dart';

// ---------------------------------------------------------------------------
// WAV builder helpers
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

/// Build a mono WAV with configurable bit depth and format code.
///
/// [rawSampleBytes] is the pre-encoded PCM/float data for the data chunk.
/// [audioFormat] is 1 for PCM, 3 for IEEE float.
Uint8List buildWavRaw({
  required Uint8List rawSampleBytes,
  int sampleRate = 44100,
  int channels = 1,
  int bitDepth = 16,
  int audioFormat = 1,
  List<Uint8List>? extraChunksBefore,
}) {
  // Calculate sizes for any extra chunks injected before 'data'
  int extraSize = 0;
  if (extraChunksBefore != null) {
    for (final chunk in extraChunksBefore) {
      extraSize += chunk.length;
    }
  }

  final dataSize = rawSampleBytes.length;
  final bytesPerSample = bitDepth ~/ 8;
  final blockAlign = channels * bytesPerSample;
  final byteRate = sampleRate * blockAlign;
  // RIFF size = 4 (WAVE) + 8+16 (fmt) + extraSize + 8+dataSize (data)
  final riffSize = 4 + 24 + extraSize + 8 + dataSize;
  final totalFileSize = 8 + riffSize; // 8 for RIFF + size field

  final buf = Uint8List(totalFileSize);
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
  writeU32(riffSize);
  writeFourCC('WAVE');

  // fmt chunk
  writeFourCC('fmt ');
  writeU32(16);
  writeU16(audioFormat);
  writeU16(channels);
  writeU32(sampleRate);
  writeU32(byteRate);
  writeU16(blockAlign);
  writeU16(bitDepth);

  // Extra chunks (injected before data)
  if (extraChunksBefore != null) {
    for (final chunk in extraChunksBefore) {
      for (int i = 0; i < chunk.length; i++) {
        buf[pos++] = chunk[i];
      }
    }
  }

  // data chunk
  writeFourCC('data');
  writeU32(dataSize);
  for (int i = 0; i < rawSampleBytes.length; i++) {
    buf[pos++] = rawSampleBytes[i];
  }

  return buf;
}

/// Build a WAV that has no fmt chunk — only RIFF/WAVE header and a data chunk.
Uint8List buildWavMissingFmt({int dataSize = 100}) {
  final riffSize = 4 + 8 + dataSize; // WAVE + data chunk header + data
  final totalSize = 8 + riffSize;
  final buf = Uint8List(totalSize);
  final bd = ByteData.sublistView(buf);
  int pos = 0;

  void writeFourCC(String s) {
    for (final c in s.codeUnits) {
      buf[pos++] = c;
    }
  }

  void writeU32(int v) {
    bd.setUint32(pos, v, Endian.little);
    pos += 4;
  }

  writeFourCC('RIFF');
  writeU32(riffSize);
  writeFourCC('WAVE');
  writeFourCC('data');
  writeU32(dataSize);
  // Fill data with zeros
  pos += dataSize;

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

  group('WAV decoder – 8-bit unsigned PCM', () {
    test('silence (128) maps to ~0.0', () {
      final raw = Uint8List.fromList([128, 128, 128]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 8,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.metadata.bitDepth, equals(8));
      for (final v in data.samples[0]) {
        expect(v, closeTo(0.0, 1e-4));
      }
    });

    test('0 maps to ~-1.0', () {
      final raw = Uint8List.fromList([0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 8,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(-1.0, 0.01));
    });

    test('255 maps to ~+1.0', () {
      final raw = Uint8List.fromList([255]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 8,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      // 255 → (255 - 128) / 128.0 = 0.9921875
      expect(data.samples[0][0], closeTo(1.0, 0.01));
    });
  });

  group('WAV decoder – 24-bit PCM', () {
    Uint8List encode24(List<int> signedValues) {
      final bb = BytesBuilder();
      for (final v in signedValues) {
        final unsigned = v < 0 ? v + 0x1000000 : v;
        bb.addByte(unsigned & 0xFF);
        bb.addByte((unsigned >> 8) & 0xFF);
        bb.addByte((unsigned >> 16) & 0xFF);
      }
      return bb.toBytes();
    }

    test('positive max (0x7FFFFF) maps to ~+1.0', () {
      final raw = encode24([0x7FFFFF]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 24,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.metadata.bitDepth, equals(24));
      expect(data.samples[0][0], closeTo(1.0, 0.0001));
    });

    test('negative max (0x800000 sign-extended) maps to ~-1.0', () {
      // -8388608 in 24-bit two's complement
      final raw = encode24([-8388608]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 24,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(-1.0, 0.0001));
    });

    test('zero maps to 0.0', () {
      final raw = encode24([0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 24,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(0.0, 1e-6));
    });
  });

  group('WAV decoder – 32-bit PCM', () {
    Uint8List encode32(List<int> signedValues) {
      final bytes = Uint8List(signedValues.length * 4);
      final bd = ByteData.sublistView(bytes);
      for (int i = 0; i < signedValues.length; i++) {
        bd.setInt32(i * 4, signedValues[i], Endian.little);
      }
      return bytes;
    }

    test('positive max (0x7FFFFFFF) maps to ~+1.0', () {
      final raw = encode32([0x7FFFFFFF]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.metadata.bitDepth, equals(32));
      expect(data.samples[0][0], closeTo(1.0, 0.001));
    });

    test('negative max (-2147483648) maps to ~-1.0', () {
      final raw = encode32([-2147483648]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(-1.0, 0.0001));
    });

    test('zero maps to 0.0', () {
      final raw = encode32([0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 1,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(0.0, 1e-6));
    });
  });

  group('WAV decoder – IEEE float 32-bit', () {
    Uint8List encodeFloat32(List<double> values) {
      final bytes = Uint8List(values.length * 4);
      final bd = ByteData.sublistView(bytes);
      for (int i = 0; i < values.length; i++) {
        bd.setFloat32(i * 4, values[i], Endian.little);
      }
      return bytes;
    }

    test('1.0 passes through (clamped)', () {
      final raw = encodeFloat32([1.0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 3,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(1.0, 1e-6));
    });

    test('-1.0 passes through (clamped)', () {
      final raw = encodeFloat32([-1.0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 3,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(-1.0, 1e-6));
    });

    test('0.0 passes through', () {
      final raw = encodeFloat32([0.0]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 3,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(0.0, 1e-6));
    });

    test('values beyond 1.0 are clamped', () {
      final raw = encodeFloat32([1.5, -1.5]);
      final wav = buildWavRaw(
        rawSampleBytes: raw,
        bitDepth: 32,
        audioFormat: 3,
      );
      final data = decodeWav(wav);
      expect(data.samples[0][0], closeTo(1.0, 1e-6));
      expect(data.samples[0][1], closeTo(-1.0, 1e-6));
    });
  });

  group('WAV decoder – odd chunk padding', () {
    test('skips odd-sized unknown chunk before data', () {
      // Build an unknown chunk 'XXXX' with odd size (5 bytes)
      final unknownChunkSize = 5;
      // Chunk: 4 (id) + 4 (size) + 5 (data) + 1 (pad) = 14 bytes
      final chunkBytes = Uint8List(14);
      final chunkBd = ByteData.sublistView(chunkBytes);
      int cp = 0;
      for (final c in 'XXXX'.codeUnits) {
        chunkBytes[cp++] = c;
      }
      chunkBd.setUint32(cp, unknownChunkSize, Endian.little);
      cp += 4;
      // 5 bytes of dummy data
      for (int i = 0; i < 5; i++) {
        chunkBytes[cp++] = 0xAA;
      }
      // 1 byte padding
      chunkBytes[cp++] = 0x00;

      // Build a simple 16-bit sample
      final sampleBytes = Uint8List(2);
      final sampleBd = ByteData.sublistView(sampleBytes);
      sampleBd.setInt16(0, 16384, Endian.little); // ~0.5

      final wav = buildWavRaw(
        rawSampleBytes: sampleBytes,
        bitDepth: 16,
        audioFormat: 1,
        extraChunksBefore: [chunkBytes],
      );

      final data = decodeWav(wav);
      expect(data.samples[0].length, equals(1));
      expect(data.samples[0][0], closeTo(0.5, 0.001));
    });
  });

  group('WAV decoder – missing fmt chunk', () {
    test('throws CorruptFileException when fmt chunk is absent', () {
      final wav = buildWavMissingFmt();
      expect(
        () => decodeWav(wav),
        throwsA(isA<CorruptFileException>()),
      );
    });
  });
}
