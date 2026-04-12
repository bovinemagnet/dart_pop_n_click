import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

// ---------------------------------------------------------------------------
// AIFF builder helpers
// ---------------------------------------------------------------------------

/// Build an 80-bit IEEE 754 extended precision float for common sample rates.
///
/// This is a simplified implementation that handles the sample rates typically
/// used in tests. AIFF stores sample rates in this format.
///
/// The 80-bit extended format is: 1 sign bit, 15 exponent bits (bias 16383),
/// 64 mantissa bits with explicit integer bit.
Uint8List buildExtended(double value) {
  final bytes = ByteData(10);
  if (value == 0) return bytes.buffer.asUint8List();

  // Use a lookup table of pre-computed byte sequences for common rates.
  // These are the exact 80-bit extended representations.
  final known = <double, List<int>>{
    // 44100 Hz: exp=0x400E, mantissa=0xAC44000000000000
    44100.0: [0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    // 48000 Hz: exp=0x400E, mantissa=0xBB80000000000000
    48000.0: [0x40, 0x0E, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    // 8000 Hz: exp=0x400B, mantissa=0xFA00000000000000
    8000.0: [0x40, 0x0B, 0xFA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    // 22050 Hz: exp=0x400D, mantissa=0xAC44000000000000
    22050.0: [0x40, 0x0D, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    // 96000 Hz: exp=0x400F, mantissa=0xBB80000000000000
    96000.0: [0x40, 0x0F, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  };

  if (known.containsKey(value)) {
    return Uint8List.fromList(known[value]!);
  }

  // Fallback: manually encode the integer value.
  // For a positive integer n, the 80-bit extended representation is:
  //   exponent = 16383 + floor(log2(n))
  //   mantissa = n << (63 - floor(log2(n)))
  final intVal = value.toInt();
  if (intVal <= 0) return bytes.buffer.asUint8List();

  final log2 = intVal.bitLength - 1;
  final exp = 16383 + log2;
  // Shift the value so its MSB is at bit 63
  final mantissa = intVal << (63 - log2);

  bytes.setUint16(0, exp, Endian.big);
  // Write 64-bit mantissa as two 32-bit halves
  bytes.setUint32(2, (mantissa >> 32) & 0xFFFFFFFF, Endian.big);
  bytes.setUint32(6, mantissa & 0xFFFFFFFF, Endian.big);

  return bytes.buffer.asUint8List();
}

/// Build a minimal AIFF (or AIFF-C) byte array suitable for testing.
///
/// [pcmData] contains the raw PCM audio bytes (big-endian for AIFF,
/// little-endian for AIFF-C with `sowt` compression).
Uint8List buildAiff({
  int channels = 1,
  int bitDepth = 16,
  int sampleRate = 44100,
  required Uint8List pcmData,
  bool isAifC = false,
  String compressionType = 'NONE',
}) {
  final numFrames = pcmData.length ~/ (channels * (bitDepth ~/ 8));
  final commChunkDataSize =
      isAifC ? 24 : 18; // 18 standard + 6 for compression info
  final ssndChunkDataSize = 8 + pcmData.length; // offset + blockSize + data
  final formType = isAifC ? 'AIFC' : 'AIFF';
  // Pad COMM if odd
  final commPad = commChunkDataSize.isOdd ? 1 : 0;
  final totalSize =
      12 + (8 + commChunkDataSize + commPad) + (8 + ssndChunkDataSize);

  final bd = ByteData(totalSize);
  var offset = 0;

  // FORM header
  for (final c in 'FORM'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, totalSize - 8, Endian.big);
  offset += 4;
  for (final c in formType.codeUnits) {
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
  // 80-bit extended sample rate
  final extBytes = buildExtended(sampleRate.toDouble());
  for (var i = 0; i < 10; i++) {
    bd.setUint8(offset++, extBytes[i]);
  }

  if (isAifC) {
    for (final c in compressionType.codeUnits) {
      bd.setUint8(offset++, c);
    }
    bd.setUint8(offset++, 0); // pascal string length
    bd.setUint8(offset++, 0); // padding
  }

  // Pad COMM if odd
  if (commChunkDataSize.isOdd) {
    bd.setUint8(offset++, 0);
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
  // PCM data
  for (var i = 0; i < pcmData.length; i++) {
    bd.setUint8(offset++, pcmData[i]);
  }

  return bd.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('AIFF decoder', () {
    // -----------------------------------------------------------------------
    // 16-bit big-endian stereo
    // -----------------------------------------------------------------------

    group('16-bit big-endian stereo', () {
      test('decodes correctly and deinterleaves channels', () {
        // Create 2 frames of stereo 16-bit BE PCM
        // L0=1000, R0=-1000, L1=2000, R1=-2000
        final pcm = ByteData(8);
        pcm.setInt16(0, 1000, Endian.big);
        pcm.setInt16(2, -1000, Endian.big);
        pcm.setInt16(4, 2000, Endian.big);
        pcm.setInt16(6, -2000, Endian.big);

        final aiff = buildAiff(
          channels: 2,
          bitDepth: 16,
          pcmData: pcm.buffer.asUint8List(),
        );
        final result = decodeAiff(aiff);

        expect(result.metadata.channels, equals(2));
        expect(result.metadata.sampleRate, equals(44100));
        expect(result.metadata.bitDepth, equals(16));
        expect(result.samples.length, equals(2));
        expect(result.samples[0].length, equals(2));
        expect(result.samples[1].length, equals(2));
        // Left channel
        expect(result.samples[0][0], closeTo(1000 / 32768.0, 0.001));
        expect(result.samples[0][1], closeTo(2000 / 32768.0, 0.001));
        // Right channel
        expect(result.samples[1][0], closeTo(-1000 / 32768.0, 0.001));
        expect(result.samples[1][1], closeTo(-2000 / 32768.0, 0.001));
      });

      test('decodes silence as zeros', () {
        final pcm = Uint8List(4); // 1 frame of stereo 16-bit silence
        final aiff = buildAiff(channels: 2, bitDepth: 16, pcmData: pcm);
        final result = decodeAiff(aiff);

        for (final ch in result.samples) {
          for (final v in ch) {
            expect(v, closeTo(0.0, 1e-4));
          }
        }
      });
    });

    // -----------------------------------------------------------------------
    // 16-bit big-endian mono
    // -----------------------------------------------------------------------

    group('16-bit big-endian mono', () {
      test('positive peak (32767) normalises to ~1.0', () {
        final pcm = ByteData(2);
        pcm.setInt16(0, 32767, Endian.big);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          pcmData: pcm.buffer.asUint8List(),
        );
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(1.0, 0.0001));
      });

      test('negative peak (-32768) normalises to ~-1.0', () {
        final pcm = ByteData(2);
        pcm.setInt16(0, -32768, Endian.big);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          pcmData: pcm.buffer.asUint8List(),
        );
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(-1.0, 0.0001));
      });
    });

    // -----------------------------------------------------------------------
    // 8-bit signed mono (AIFF uses signed 8-bit, unlike WAV)
    // -----------------------------------------------------------------------

    group('8-bit signed mono', () {
      test('0 normalises to 0.0', () {
        final pcm = Uint8List.fromList([0]);
        final aiff = buildAiff(channels: 1, bitDepth: 8, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(0.0, 0.01));
      });

      test('127 normalises to ~1.0', () {
        final pcm = Uint8List.fromList([127]);
        final aiff = buildAiff(channels: 1, bitDepth: 8, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(127 / 128.0, 0.01));
      });

      test('-128 (0x80) normalises to -1.0', () {
        final pcm = Uint8List.fromList([0x80]);
        final aiff = buildAiff(channels: 1, bitDepth: 8, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(-1.0, 0.01));
      });
    });

    // -----------------------------------------------------------------------
    // 24-bit big-endian mono
    // -----------------------------------------------------------------------

    group('24-bit big-endian mono', () {
      /// Encode a signed 24-bit value as 3 big-endian bytes.
      Uint8List encode24BE(int value) {
        final unsigned = value < 0 ? value + 0x1000000 : value;
        return Uint8List.fromList([
          (unsigned >> 16) & 0xFF,
          (unsigned >> 8) & 0xFF,
          unsigned & 0xFF,
        ]);
      }

      test('zero normalises to 0.0', () {
        final pcm = encode24BE(0);
        final aiff = buildAiff(channels: 1, bitDepth: 24, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(0.0, 1e-6));
      });

      test('max positive (0x7FFFFF) normalises to ~1.0', () {
        final pcm = encode24BE(0x7FFFFF);
        final aiff = buildAiff(channels: 1, bitDepth: 24, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(1.0, 0.0001));
      });

      test('max negative (-8388608) normalises to ~-1.0', () {
        final pcm = encode24BE(-8388608);
        final aiff = buildAiff(channels: 1, bitDepth: 24, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(-1.0, 0.0001));
      });
    });

    // -----------------------------------------------------------------------
    // AIFF-C variants
    // -----------------------------------------------------------------------

    group('AIFF-C', () {
      test('NONE compression type decodes as big-endian', () {
        final pcm = ByteData(2);
        pcm.setInt16(0, 5000, Endian.big);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          pcmData: pcm.buffer.asUint8List(),
          isAifC: true,
          compressionType: 'NONE',
        );
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(5000 / 32768.0, 0.001));
      });

      test('sowt compression type decodes as little-endian', () {
        // Create LE PCM data
        final pcm = ByteData(2);
        pcm.setInt16(0, 10000, Endian.little);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          pcmData: pcm.buffer.asUint8List(),
          isAifC: true,
          compressionType: 'sowt',
        );
        final result = decodeAiff(aiff);
        expect(result.samples[0][0], closeTo(10000 / 32768.0, 0.001));
      });

      test('unsupported compression throws UnsupportedFormatException', () {
        final pcm = Uint8List(2);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          pcmData: pcm,
          isAifC: true,
          compressionType: 'ima4',
        );
        expect(
          () => decodeAiff(aiff),
          throwsA(isA<UnsupportedFormatException>()),
        );
      });
    });

    // -----------------------------------------------------------------------
    // Sample rate parsing
    // -----------------------------------------------------------------------

    group('sample rate parsing', () {
      test('decodes 48000 Hz correctly', () {
        final pcm = Uint8List(2); // 1 frame of 16-bit silence
        final aiff =
            buildAiff(channels: 1, bitDepth: 16, sampleRate: 48000, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.metadata.sampleRate, equals(48000));
      });

      test('decodes 8000 Hz correctly', () {
        final pcm = Uint8List(2);
        final aiff =
            buildAiff(channels: 1, bitDepth: 16, sampleRate: 8000, pcmData: pcm);
        final result = decodeAiff(aiff);
        expect(result.metadata.sampleRate, equals(8000));
      });
    });

    // -----------------------------------------------------------------------
    // Duration calculation
    // -----------------------------------------------------------------------

    group('duration', () {
      test('reports correct duration for 1 second of audio', () {
        // 44100 frames of mono 16-bit = 88200 bytes
        final pcm = Uint8List(44100 * 2);
        final aiff = buildAiff(
          channels: 1,
          bitDepth: 16,
          sampleRate: 44100,
          pcmData: pcm,
        );
        final result = decodeAiff(aiff);
        expect(result.metadata.duration.inSeconds, equals(1));
      });
    });

    // -----------------------------------------------------------------------
    // Error cases
    // -----------------------------------------------------------------------

    group('error cases', () {
      test('missing COMM chunk throws CorruptFileException', () {
        // Build a minimal FORM/AIFF with only an SSND chunk, no COMM
        final ssndData = Uint8List(10); // dummy PCM
        final ssndChunkSize = 8 + ssndData.length;
        final totalSize = 12 + 8 + ssndChunkSize;

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
        for (final c in 'SSND'.codeUnits) {
          bd.setUint8(offset++, c);
        }
        bd.setUint32(offset, ssndChunkSize, Endian.big);
        offset += 4;
        bd.setUint32(offset, 0, Endian.big);
        offset += 4; // data offset
        bd.setUint32(offset, 0, Endian.big);
        offset += 4; // block size

        expect(
          () => decodeAiff(bd.buffer.asUint8List()),
          throwsA(isA<CorruptFileException>()),
        );
      });

      test('missing SSND chunk throws CorruptFileException', () {
        // Build a minimal FORM/AIFF with only a COMM chunk, no SSND
        final commSize = 18;
        final totalSize = 12 + 8 + commSize;

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
        for (final c in 'COMM'.codeUnits) {
          bd.setUint8(offset++, c);
        }
        bd.setUint32(offset, commSize, Endian.big);
        offset += 4;
        bd.setInt16(offset, 1, Endian.big);
        offset += 2; // channels
        bd.setUint32(offset, 100, Endian.big);
        offset += 4; // numFrames
        bd.setInt16(offset, 16, Endian.big);
        offset += 2; // bitDepth
        // 10-byte extended sample rate (44100)
        final extBytes = buildExtended(44100.0);
        for (var i = 0; i < 10; i++) {
          bd.setUint8(offset++, extBytes[i]);
        }

        expect(
          () => decodeAiff(bd.buffer.asUint8List()),
          throwsA(isA<CorruptFileException>()),
        );
      });

      test('invalid magic bytes throws CorruptFileException', () {
        final bytes = Uint8List.fromList(List.filled(32, 0x00));
        expect(
          () => decodeAiff(bytes),
          throwsA(isA<CorruptFileException>()),
        );
      });

      test('empty bytes throws CorruptFileException', () {
        expect(
          () => decodeAiff(Uint8List(0)),
          throwsA(isA<CorruptFileException>()),
        );
      });

      test('chunk size exceeds remaining bytes throws CorruptFileException',
          () {
        // Build a FORM/AIFF header then a COMM chunk claiming to be much larger
        final totalSize = 20; // Just enough for FORM header + partial chunk
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
        // Start a COMM chunk that claims 999 bytes
        for (final c in 'COMM'.codeUnits) {
          bd.setUint8(offset++, c);
        }
        bd.setUint32(offset, 999, Endian.big);
        offset += 4;

        expect(
          () => decodeAiff(bd.buffer.asUint8List()),
          throwsA(isA<CorruptFileException>()),
        );
      });

      test('truncated file (< 12 bytes) throws CorruptFileException', () {
        // Only "FORM" + partial size
        final bytes = Uint8List.fromList([
          0x46, 0x4F, 0x52, 0x4D, // FORM
          0x00, 0x00, 0x00, 0x10, // size
        ]);
        expect(
          () => decodeAiff(bytes),
          throwsA(isA<CorruptFileException>()),
        );
      });
    });
  });
}
