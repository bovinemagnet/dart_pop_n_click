import 'dart:typed_data';
import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers for building raw PCM byte buffers
// ---------------------------------------------------------------------------

/// Encode a list of signed 16-bit values as little-endian bytes.
Uint8List int16Bytes(List<int> values, [Endian endian = Endian.little]) {
  final bd = ByteData(values.length * 2);
  for (var i = 0; i < values.length; i++) {
    bd.setInt16(i * 2, values[i], endian);
  }
  return bd.buffer.asUint8List();
}

/// Encode a list of signed 24-bit values as little-endian bytes.
Uint8List int24Bytes(List<int> signedValues) {
  final bb = BytesBuilder();
  for (final v in signedValues) {
    final unsigned = v < 0 ? v + 0x1000000 : v;
    bb.addByte(unsigned & 0xFF);
    bb.addByte((unsigned >> 8) & 0xFF);
    bb.addByte((unsigned >> 16) & 0xFF);
  }
  return bb.toBytes();
}

/// Encode a list of signed 32-bit values as little-endian bytes.
Uint8List int32Bytes(List<int> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setInt32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

/// Encode a list of IEEE float 32-bit values as little-endian bytes.
Uint8List float32Bytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('decodePcmBytes', () {
    // -------------------------------------------------------------------
    // 16-bit signed LE mono
    // -------------------------------------------------------------------
    group('16-bit signed LE mono', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 16,
        channels: 1,
      );

      test('silence (0) normalises to 0.0', () {
        final bytes = int16Bytes([0]);
        final result = decodePcmBytes(bytes, format);
        expect(result.length, equals(1));
        expect(result[0][0], closeTo(0.0, 1e-6));
      });

      test('max positive (32767) normalises to ~1.0', () {
        final bytes = int16Bytes([32767]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 0.0001));
      });

      test('max negative (-32768) normalises to -1.0', () {
        final bytes = int16Bytes([-32768]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(-1.0, 0.0001));
      });

      test('multiple frames decode in order', () {
        final bytes = int16Bytes([0, 16384, -16384, 32767]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0].length, equals(4));
        expect(result[0][0], closeTo(0.0, 1e-6));
        expect(result[0][1], closeTo(0.5, 0.001));
        expect(result[0][2], closeTo(-0.5, 0.001));
        expect(result[0][3], closeTo(1.0, 0.0001));
      });
    });

    // -------------------------------------------------------------------
    // 16-bit signed LE stereo
    // -------------------------------------------------------------------
    group('16-bit signed LE stereo', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 16,
        channels: 2,
      );

      test('channels are deinterleaved correctly', () {
        // Interleaved: [L0, R0, L1, R1]
        final bytes = int16Bytes([1000, 2000, 3000, 4000]);
        final result = decodePcmBytes(bytes, format);
        expect(result.length, equals(2));
        // Channel 0 (left): L0=1000, L1=3000
        expect(result[0].length, equals(2));
        expect(result[0][0], closeTo(1000 / 32768.0, 1e-4));
        expect(result[0][1], closeTo(3000 / 32768.0, 1e-4));
        // Channel 1 (right): R0=2000, R1=4000
        expect(result[1].length, equals(2));
        expect(result[1][0], closeTo(2000 / 32768.0, 1e-4));
        expect(result[1][1], closeTo(4000 / 32768.0, 1e-4));
      });
    });

    // -------------------------------------------------------------------
    // 8-bit unsigned mono
    // -------------------------------------------------------------------
    group('8-bit unsigned mono', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 8,
        channels: 1,
      );

      test('128 normalises to ~0.0', () {
        final bytes = Uint8List.fromList([128]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(0.0, 1e-4));
      });

      test('0 normalises to -1.0', () {
        final bytes = Uint8List.fromList([0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(-1.0, 0.01));
      });

      test('255 normalises to ~1.0', () {
        final bytes = Uint8List.fromList([255]);
        final result = decodePcmBytes(bytes, format);
        // (255 - 128) / 128.0 = 0.9921875
        expect(result[0][0], closeTo(1.0, 0.01));
      });
    });

    // -------------------------------------------------------------------
    // 24-bit signed LE mono
    // -------------------------------------------------------------------
    group('24-bit signed LE mono', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 24,
        channels: 1,
      );

      test('zero normalises to 0.0', () {
        final bytes = int24Bytes([0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(0.0, 1e-6));
      });

      test('max positive (0x7FFFFF) normalises to ~1.0', () {
        final bytes = int24Bytes([0x7FFFFF]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 0.0001));
      });

      test('max negative sign-extends correctly', () {
        // -8388608 is the most negative 24-bit value
        final bytes = int24Bytes([-8388608]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(-1.0, 0.0001));
      });
    });

    // -------------------------------------------------------------------
    // 32-bit signed LE mono
    // -------------------------------------------------------------------
    group('32-bit signed LE mono', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 32,
        channels: 1,
      );

      test('zero normalises to 0.0', () {
        final bytes = int32Bytes([0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(0.0, 1e-6));
      });

      test('max positive normalises to ~1.0', () {
        final bytes = int32Bytes([0x7FFFFFFF]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 0.001));
      });

      test('max negative normalises to -1.0', () {
        final bytes = int32Bytes([-2147483648]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(-1.0, 0.0001));
      });
    });

    // -------------------------------------------------------------------
    // 32-bit IEEE float
    // -------------------------------------------------------------------
    group('32-bit IEEE float', () {
      final format = PcmFormat(
        sampleRate: 44100,
        bitDepth: 32,
        channels: 1,
        isFloat: true,
      );

      test('1.0 passes through', () {
        final bytes = float32Bytes([1.0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 1e-6));
      });

      test('-1.0 passes through', () {
        final bytes = float32Bytes([-1.0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(-1.0, 1e-6));
      });

      test('0.0 passes through', () {
        final bytes = float32Bytes([0.0]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(0.0, 1e-6));
      });

      test('values beyond +/-1.0 are clamped', () {
        final bytes = float32Bytes([1.5, -1.5]);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 1e-6));
        expect(result[0][1], closeTo(-1.0, 1e-6));
      });
    });

    // -------------------------------------------------------------------
    // Big-endian 16-bit
    // -------------------------------------------------------------------
    group('big-endian 16-bit', () {
      test('decodes correctly with Endian.big', () {
        final format = PcmFormat(
          sampleRate: 44100,
          bitDepth: 16,
          channels: 1,
          endian: Endian.big,
        );
        // Write bytes in big-endian order
        final bytes = int16Bytes([32767, -32768], Endian.big);
        final result = decodePcmBytes(bytes, format);
        expect(result[0][0], closeTo(1.0, 0.0001));
        expect(result[0][1], closeTo(-1.0, 0.0001));
      });
    });

    // -------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------
    group('edge cases', () {
      test('empty bytes returns empty channel lists', () {
        final format = PcmFormat(
          sampleRate: 44100,
          bitDepth: 16,
          channels: 2,
        );
        final result = decodePcmBytes(Uint8List(0), format);
        expect(result.length, equals(2));
        expect(result[0].length, equals(0));
        expect(result[1].length, equals(0));
      });

      test('misaligned byte length throws CorruptFileException', () {
        final format = PcmFormat(
          sampleRate: 44100,
          bitDepth: 16,
          channels: 1,
        );
        // 3 bytes is not a multiple of 2 (frame size for 16-bit mono)
        final bytes = Uint8List(3);
        expect(
          () => decodePcmBytes(bytes, format),
          throwsA(isA<CorruptFileException>()),
        );
      });
    });
  });
}
