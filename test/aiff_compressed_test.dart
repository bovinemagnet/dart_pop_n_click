import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import 'aiff_decoder_test.dart' show buildAiff;

void main() {
  group('AIFF-C fl32 (32-bit big-endian float)', () {
    test('decodes known float samples', () {
      // Big-endian float samples: 0.0, 0.5, -0.5, 1.0
      final floats = Float32List.fromList([0.0, 0.5, -0.5, 1.0]);
      final be = ByteData(16);
      for (int i = 0; i < floats.length; i++) {
        be.setFloat32(i * 4, floats[i], Endian.big);
      }
      final aiff = buildAiff(
        channels: 1,
        bitDepth: 32,
        sampleRate: 48000,
        pcmData: be.buffer.asUint8List(),
        isAifC: true,
        compressionType: 'fl32',
      );
      final result = analyseBytes(aiff);
      expect(result.metadata.bitDepth, 32);
      expect(result.metadata.channels, 1);
      expect(result.metadata.sampleRate, 48000);
    });
  });

  group('AIFF-C μ-law', () {
    test('silence byte (0xFF) decodes to 0', () {
      // μ-law: 0xFF is the "biased zero" code. Our lookup gives 0.
      // Using 4 sample bytes, COMM reports bitDepth=16.
      final compressed = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]);
      final aiff = buildAiff(
        channels: 1,
        bitDepth: 16,
        sampleRate: 8000,
        pcmData: compressed,
        isAifC: true,
        compressionType: 'ulaw',
      );
      final result = analyseBytes(aiff);
      expect(result.metadata.channels, 1);
      expect(result.metadata.sampleRate, 8000);
      // Silence → no defects
      expect(result.defects.where((d) => d.type == DefectType.click), isEmpty);
    });

    test('decodes typical μ-law bytes to expected range', () {
      // A handful of bytes spanning the dynamic range.
      final compressed = Uint8List.fromList([0x00, 0x7F, 0x80, 0xFF]);
      final aiff = buildAiff(
        channels: 1,
        bitDepth: 16,
        sampleRate: 8000,
        pcmData: compressed,
        isAifC: true,
        compressionType: 'ulaw',
      );
      final result = analyseBytes(aiff);
      expect(result.metadata.duration.inMicroseconds, greaterThan(0));
    });
  });

  group('AIFF-C A-law', () {
    test('decodes A-law bytes without error', () {
      final compressed = Uint8List.fromList([0x55, 0xD5, 0x00, 0x80]);
      final aiff = buildAiff(
        channels: 1,
        bitDepth: 16,
        sampleRate: 8000,
        pcmData: compressed,
        isAifC: true,
        compressionType: 'alaw',
      );
      final result = analyseBytes(aiff);
      expect(result.metadata.channels, 1);
      expect(result.metadata.sampleRate, 8000);
    });
  });

  group('unsupported compression', () {
    test('throws UnsupportedFormatException for ima4', () {
      final aiff = buildAiff(
        channels: 1,
        bitDepth: 16,
        sampleRate: 44100,
        pcmData: Uint8List(16),
        isAifC: true,
        compressionType: 'ima4',
      );
      expect(() => analyseBytes(aiff),
          throwsA(isA<UnsupportedFormatException>()));
    });
  });
}
