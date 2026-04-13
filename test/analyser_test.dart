import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

// ---------------------------------------------------------------------------
// AIFF builder helpers (for integration tests)
// ---------------------------------------------------------------------------

/// Build an 80-bit IEEE 754 extended precision float for common sample rates.
Uint8List _buildExtended(double value) {
  // Use a lookup table of pre-computed byte sequences for common rates.
  final known = <double, List<int>>{
    44100.0: [0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    48000.0: [0x40, 0x0E, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    8000.0: [0x40, 0x0B, 0xFA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  };

  if (known.containsKey(value)) {
    return Uint8List.fromList(known[value]!);
  }

  // Fallback: manually encode the integer value.
  final bytes = ByteData(10);
  final intVal = value.toInt();
  if (intVal <= 0) return bytes.buffer.asUint8List();

  final log2 = intVal.bitLength - 1;
  final exp = 16383 + log2;
  final mantissa = intVal << (63 - log2);

  bytes.setUint16(0, exp, Endian.big);
  bytes.setUint32(2, (mantissa >> 32) & 0xFFFFFFFF, Endian.big);
  bytes.setUint32(6, mantissa & 0xFFFFFFFF, Endian.big);

  return bytes.buffer.asUint8List();
}

/// Build a minimal AIFF byte array for integration testing.
Uint8List buildAiffForAnalyser({
  int channels = 1,
  int bitDepth = 16,
  int sampleRate = 44100,
  required Uint8List pcmData,
}) {
  final numFrames = pcmData.length ~/ (channels * (bitDepth ~/ 8));
  final commChunkDataSize = 18;
  final ssndChunkDataSize = 8 + pcmData.length;
  final totalSize = 12 + (8 + commChunkDataSize) + (8 + ssndChunkDataSize);

  final bd = ByteData(totalSize);
  var offset = 0;

  for (final c in 'FORM'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, totalSize - 8, Endian.big);
  offset += 4;
  for (final c in 'AIFF'.codeUnits) {
    bd.setUint8(offset++, c);
  }

  // COMM chunk
  for (final c in 'COMM'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, commChunkDataSize, Endian.big);
  offset += 4;
  bd.setInt16(offset, channels, Endian.big);
  offset += 2;
  bd.setUint32(offset, numFrames, Endian.big);
  offset += 4;
  bd.setInt16(offset, bitDepth, Endian.big);
  offset += 2;
  final extBytes = _buildExtended(sampleRate.toDouble());
  for (var i = 0; i < 10; i++) {
    bd.setUint8(offset++, extBytes[i]);
  }

  // SSND chunk
  for (final c in 'SSND'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, ssndChunkDataSize, Endian.big);
  offset += 4;
  bd.setUint32(offset, 0, Endian.big);
  offset += 4; // offset field
  bd.setUint32(offset, 0, Endian.big);
  offset += 4; // blockSize field
  for (var i = 0; i < pcmData.length; i++) {
    bd.setUint8(offset++, pcmData[i]);
  }

  return bd.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Raw PCM builder helpers
// ---------------------------------------------------------------------------

/// Build raw 16-bit signed LE stereo PCM bytes from two channels of int samples.
Uint8List buildRawPcm16Stereo(List<int> left, List<int> right, {int? length}) {
  final n = length ?? left.length;
  final bd = ByteData(n * 4); // 2 channels * 2 bytes per sample
  for (var i = 0; i < n; i++) {
    bd.setInt16(i * 4, left[i], Endian.little);
    bd.setInt16(i * 4 + 2, right[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

/// Build raw 16-bit signed LE mono PCM bytes from int samples.
Uint8List buildRawPcm16Mono(List<int> samples) {
  final bd = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

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
      final result = analyseBytes(
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

      final result = analyseBytes(wav);
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

  // -------------------------------------------------------------------------
  // analysePcm()
  // -------------------------------------------------------------------------

  group('analysePcm()', () {
    test('detects defects in raw PCM with injected spike', () async {
      const sampleRate = 44100;
      // 1 second of stereo silence
      final left = List<int>.filled(sampleRate, 0);
      final right = List<int>.filled(sampleRate, 0);
      // Inject a spike at the midpoint on the left channel
      left[22050] = 32767;
      left[22051] = -32767;

      final bytes = buildRawPcm16Stereo(left, right);
      final format = PcmFormat(
        sampleRate: sampleRate,
        bitDepth: 16,
        channels: 2,
      );

      final result = analysePcm(
        bytes,
        format: format,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(result.defects, isNotEmpty);
      expect(result.metadata.sampleRate, equals(sampleRate));
      expect(result.metadata.channels, equals(2));
    });

    test('returns no defects for clean sine wave', () async {
      const sampleRate = 44100;
      // Generate a clean 440 Hz sine as 16-bit samples
      final samples = List<int>.generate(
        sampleRate,
        (i) => (0.3 * math.sin(2 * math.pi * 440 * i / sampleRate) * 32767)
            .round(),
      );

      final bytes = buildRawPcm16Mono(samples);
      final format = PcmFormat(
        sampleRate: sampleRate,
        bitDepth: 16,
        channels: 1,
      );

      final result = analysePcm(bytes, format: format);
      expect(result.defects, isEmpty);
    });

    test('propagates config sensitivity', () async {
      const sampleRate = 44100;
      // 1 second of sine with a weak spike
      final samples = List<int>.generate(
        sampleRate,
        (i) => (0.1 * math.sin(2 * math.pi * 440 * i / sampleRate) * 32767)
            .round(),
      );
      // Inject a moderate spike
      samples[22050] = (0.3 * 32767).round();
      samples[22051] = (-0.3 * 32767).round();

      final bytes = buildRawPcm16Mono(samples);
      final format = PcmFormat(
        sampleRate: sampleRate,
        bitDepth: 16,
        channels: 1,
      );

      final resultHigh = analysePcm(
        bytes,
        format: format,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );
      final resultLow = analysePcm(
        bytes,
        format: format,
        config: const DetectorConfig(sensitivity: Sensitivity.low),
      );

      // High sensitivity should find at least as many defects as low
      expect(resultHigh.defects.length,
          greaterThanOrEqualTo(resultLow.defects.length));
    });
  });

  // -------------------------------------------------------------------------
  // analyseSamples()
  // -------------------------------------------------------------------------

  group('analyseSamples()', () {
    test('detects defects in pre-normalised samples', () async {
      const sampleRate = 44100;
      final channel = Float32List(sampleRate);
      // Inject a sharp spike
      channel[22050] = 0.98;
      channel[22051] = -0.98;

      final result = analyseSamples(
        [channel],
        sampleRate: sampleRate,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(result.defects, isNotEmpty);
    });

    test('returns no defects for silence', () async {
      const sampleRate = 44100;
      final channel = Float32List(sampleRate); // all zeros

      final result = analyseSamples(
        [channel],
        sampleRate: sampleRate,
      );

      expect(result.defects, isEmpty);
      expect(result.aggregateConfidence, equals(0.0));
    });

    test('empty channels returns no defects', () async {
      final result = analyseSamples(
        [Float32List(0)],
        sampleRate: 44100,
      );

      expect(result.defects, isEmpty);
      expect(result.metadata.channels, equals(1));
      expect(result.metadata.duration, equals(Duration.zero));
    });
  });

  // -------------------------------------------------------------------------
  // Format detection edge cases
  // -------------------------------------------------------------------------

  group('analyseBytes() – format detection', () {
    test(
        'file with .wav extension but invalid magic bytes throws UnsupportedFormatException or CorruptFileException',
        () {
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
      ]);
      expect(
        () => analyseBytes(bytes, path: 'test.wav'),
        throwsA(anyOf(
            isA<UnsupportedFormatException>(), isA<CorruptFileException>())),
      );
    });

    test(
        'file with unknown extension and no valid magic bytes throws UnsupportedFormatException',
        () {
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
      ]);
      expect(
        () => analyseBytes(bytes, path: 'test.xyz'),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('no path and no valid magic bytes throws UnsupportedFormatException',
        () {
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
      ]);
      expect(
        () => analyseBytes(bytes),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('bytes shorter than 12 with no path throws UnsupportedFormatException',
        () {
      final bytes = Uint8List.fromList([0x52, 0x49, 0x46, 0x46]); // Just "RIFF"
      expect(
        () => analyseBytes(bytes),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // analysePcm() – validation
  // -------------------------------------------------------------------------

  group('analysePcm() – validation', () {
    test('misaligned bytes throws CorruptFileException', () {
      // 16-bit stereo needs 4 bytes per frame; 5 bytes is misaligned
      final format = PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 2);
      final bytes = Uint8List(5);
      expect(
        () => analysePcm(bytes, format: format),
        throwsA(isA<CorruptFileException>()),
      );
    });

    test('empty bytes returns no defects', () async {
      final format = PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 1);
      final bytes = Uint8List(0);
      final result = analysePcm(bytes, format: format);
      expect(result.defects, isEmpty);
      expect(result.aggregateConfidence, equals(0.0));
    });
  });

  // -------------------------------------------------------------------------
  // analyseSamples() – edge cases
  // -------------------------------------------------------------------------

  group('analyseSamples() – edge cases', () {
    test('single-sample channels returns no defects', () async {
      final samples = [
        Float32List.fromList([0.5])
      ];
      final result = analyseSamples(samples, sampleRate: 44100);
      expect(result.defects, isEmpty);
    });

    test('metadata reflects correct values', () async {
      final samples = [
        Float32List(44100),
        Float32List(44100),
      ]; // 1 second stereo
      final result = analyseSamples(samples, sampleRate: 44100, bitDepth: 24);
      expect(result.metadata.sampleRate, equals(44100));
      expect(result.metadata.bitDepth, equals(24));
      expect(result.metadata.channels, equals(2));
      expect(result.metadata.duration.inMilliseconds, closeTo(1000, 1));
    });

    test('config sensitivity propagates to analyseSamples', () async {
      // Create signal with a weak click
      final n = 44100;
      final samples = Float32List(n);
      samples[22050] = 0.3; // weak
      samples[22051] = -0.3;

      final highResult = analyseSamples(
        [samples],
        sampleRate: 44100,
        config: DetectorConfig(sensitivity: Sensitivity.high),
      );
      final lowResult = analyseSamples(
        [samples],
        sampleRate: 44100,
        config: DetectorConfig(sensitivity: Sensitivity.low),
      );
      // High sensitivity should find more or equal defects than low
      expect(highResult.defects.length,
          greaterThanOrEqualTo(lowResult.defects.length));
    });
  });

  // -------------------------------------------------------------------------
  // analyseBytes() – AIFF integration
  // -------------------------------------------------------------------------

  group('analyseBytes() – AIFF', () {
    test('detects defects in AIFF with click', () async {
      // Build 1 second of silence with a click spike injected
      const sampleRate = 44100;
      final numSamples = sampleRate;
      final pcmBd = ByteData(numSamples * 2); // 16-bit mono

      // Fill with silence, then inject a sharp click at sample 22050
      for (var i = 0; i < numSamples; i++) {
        pcmBd.setInt16(i * 2, 0, Endian.big);
      }
      pcmBd.setInt16(22050 * 2, 32000, Endian.big); // sharp positive spike
      pcmBd.setInt16(22051 * 2, -32000, Endian.big); // sharp negative spike

      final aiff = buildAiffForAnalyser(
        channels: 1,
        bitDepth: 16,
        sampleRate: sampleRate,
        pcmData: pcmBd.buffer.asUint8List(),
      );

      final result = analyseBytes(
        aiff,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(result.defects, isNotEmpty);
      expect(result.metadata.sampleRate, equals(sampleRate));
      expect(result.metadata.channels, equals(1));
    });

    test('returns no defects for silent AIFF', () async {
      const sampleRate = 44100;
      final numSamples = sampleRate;
      final pcmData = Uint8List(numSamples * 2); // all zeros = silence

      final aiff = buildAiffForAnalyser(
        channels: 1,
        bitDepth: 16,
        sampleRate: sampleRate,
        pcmData: pcmData,
      );

      final result = analyseBytes(aiff);
      expect(result.defects, isEmpty);
      expect(result.aggregateConfidence, equals(0.0));
    });

    test('auto-detects AIFF format from magic bytes', () async {
      // Build a silent AIFF, pass without path
      const sampleRate = 44100;
      final pcmData = Uint8List(1000 * 2); // 1000 frames of silence

      final aiff = buildAiffForAnalyser(
        channels: 1,
        bitDepth: 16,
        sampleRate: sampleRate,
        pcmData: pcmData,
      );

      // Should not throw UnsupportedFormatException – AIFF is auto-detected
      final result = analyseBytes(aiff);
      expect(result.metadata.sampleRate, equals(sampleRate));
      expect(result.metadata.channels, equals(1));
    });
  });

  // -------------------------------------------------------------------------
  // New defect types: clipping, dropout, DC offset
  // -------------------------------------------------------------------------

  group('AnalysisResult – new defect types', () {
    test('clipping detected in WAV analysis', () async {
      const sampleRate = 44100;
      // 1 second of a moderate sine wave with a long run of clipped samples.
      final floats = List<double>.generate(
        sampleRate,
        (i) => 0.3 * math.sin(2 * math.pi * 440 * i / sampleRate),
      );
      // Inject a run of samples saturated at full-scale (clipping).
      for (var i = 10000; i < 10050; i++) {
        floats[i] = 1.0;
      }

      final wav = buildWav16MonoFromFloats(floats, sampleRate: sampleRate);
      final result = analyseBytes(
        wav,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(
        result.defects.any((d) => d.type == DefectType.clipping),
        isTrue,
      );
    });

    test('dropout detected in analysePcm', () {
      const sampleRate = 44100;
      // Build 1 second of a sine wave, then inject ~10ms of silence mid-way.
      final samples = List<int>.generate(
        sampleRate,
        (i) => (0.5 * math.sin(2 * math.pi * 440 * i / sampleRate) * 32767)
            .round(),
      );
      for (var i = 22000; i < 22441; i++) {
        samples[i] = 0;
      }

      final bytes = buildRawPcm16Mono(samples);
      final format = PcmFormat(
        sampleRate: sampleRate,
        bitDepth: 16,
        channels: 1,
      );

      final result = analysePcm(
        bytes,
        format: format,
        config: const DetectorConfig(sensitivity: Sensitivity.high),
      );

      expect(
        result.defects.any((d) => d.type == DefectType.dropout),
        isTrue,
      );
    });

    test('AnalysisResult includes dcOffsetPerChannel', () async {
      const sampleRate = 44100;
      final floats = List<double>.generate(
        sampleRate,
        (i) => 0.1 * math.sin(2 * math.pi * 440 * i / sampleRate),
      );
      final wav = buildWav16MonoFromFloats(floats, sampleRate: sampleRate);

      final result = analyseBytes(wav);

      expect(result.dcOffsetPerChannel, isNotNull);
      expect(result.dcOffsetPerChannel.length, equals(1));
    });
  });
}
