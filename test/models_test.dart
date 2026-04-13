import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

void main() {
  group('DetectorConfig', () {
    test('default values', () {
      const c = DetectorConfig();
      expect(c.sensitivity, equals(Sensitivity.medium));
      expect(c.minConfidence, equals(0.0));
      expect(c.maxDefects, equals(0));
      expect(c.perChannel, isFalse);
    });

    test('thresholdMultiplier decreases with higher sensitivity', () {
      const low = DetectorConfig(sensitivity: Sensitivity.low);
      const med = DetectorConfig(sensitivity: Sensitivity.medium);
      const high = DetectorConfig(sensitivity: Sensitivity.high);
      expect(low.thresholdMultiplier, greaterThan(med.thresholdMultiplier));
      expect(med.thresholdMultiplier, greaterThan(high.thresholdMultiplier));
    });
  });

  group('AudioMetadata', () {
    test('toString includes key fields', () {
      final m = AudioMetadata(
        sampleRate: 44100,
        bitDepth: 16,
        channels: 2,
        duration: const Duration(seconds: 5),
      );
      expect(m.toString(), contains('44100'));
      expect(m.toString(), contains('16'));
      expect(m.toString(), contains('2'));
    });
  });

  group('AnalysisResult.toJson', () {
    test('contains schema_version field', () {
      final result = AnalysisResult(
        defects: [],
        aggregateConfidence: 0.0,
        metadata: AudioMetadata(
          sampleRate: 44100,
          bitDepth: 16,
          channels: 1,
          duration: const Duration(seconds: 1),
        ),
      );
      final json = result.toJson();
      expect(json['schema_version'], equals('1'));
      expect(json['defect_count'], equals(0));
      expect(json.containsKey('metadata'), isTrue);
      expect(json.containsKey('defects'), isTrue);
    });
  });

  group('Defect', () {
    test('toString contains type and offset', () {
      final defect = Defect(
        type: DefectType.click,
        offset: const Duration(milliseconds: 150),
        length: const Duration(milliseconds: 2),
        confidence: 0.85,
        amplitude: 0.92,
        sampleIndex: 6615,
        channel: 0,
      );
      final str = defect.toString();
      expect(str, contains('click'));
      expect(str, contains('150'));
      expect(str, contains('0.850'));
    });

    test('toString with pop type contains pop', () {
      final defect = Defect(
        type: DefectType.pop,
        offset: const Duration(milliseconds: 500),
        length: const Duration(milliseconds: 10),
        confidence: 0.7,
        amplitude: 0.5,
        sampleIndex: 22050,
        channel: 1,
      );
      final str = defect.toString();
      expect(str, contains('pop'));
      expect(str, contains('500'));
    });
  });

  group('PcmFormat', () {
    test('bytesPerSample is bitDepth ~/ 8', () {
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 8, channels: 1).bytesPerSample,
          equals(1));
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 1)
              .bytesPerSample,
          equals(2));
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 24, channels: 1)
              .bytesPerSample,
          equals(3));
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 32, channels: 1)
              .bytesPerSample,
          equals(4));
    });

    test('bytesPerFrame is bytesPerSample * channels', () {
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 1).bytesPerFrame,
          equals(2));
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 2).bytesPerFrame,
          equals(4));
      expect(
          PcmFormat(sampleRate: 44100, bitDepth: 24, channels: 6).bytesPerFrame,
          equals(18));
    });

    test('signed8bit defaults to false', () {
      final fmt = PcmFormat(sampleRate: 44100, bitDepth: 8, channels: 1);
      expect(fmt.signed8bit, isFalse);
    });

    test('signed8bit can be set to true', () {
      final fmt = PcmFormat(
          sampleRate: 44100, bitDepth: 8, channels: 1, signed8bit: true);
      expect(fmt.signed8bit, isTrue);
    });
  });

  group('Exceptions', () {
    test('UnsupportedFormatException has readable toString', () {
      const e = UnsupportedFormatException('test message');
      expect(e.toString(), contains('test message'));
    });

    test('CorruptFileException has readable toString', () {
      const e = CorruptFileException('bad file');
      expect(e.toString(), contains('bad file'));
    });

    test('IoException with cause has readable toString', () {
      const e = IoException('io error', 'some cause');
      expect(e.toString(), contains('io error'));
      expect(e.toString(), contains('some cause'));
    });
  });
}
