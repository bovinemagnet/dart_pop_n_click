import 'package:test/test.dart';
import 'package:audio_defect_detector/src/models.dart';

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
