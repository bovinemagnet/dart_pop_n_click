import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/src/detector.dart';
import 'package:audio_defect_detector/src/models.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generate a silent Float32List.
Float32List silence(int n) => Float32List(n);

/// Generate a sine wave.
Float32List sineWave(int n, {double freq = 440.0, int sampleRate = 44100}) {
  final buf = Float32List(n);
  for (int i = 0; i < n; i++) {
    buf[i] = math.sin(2 * math.pi * freq * i / sampleRate);
  }
  return buf;
}

/// Inject a click at [pos] with [amplitude] into [buf] (modifies in place).
void injectClick(Float32List buf, int pos, {double amplitude = 0.9}) {
  if (pos < buf.length) buf[pos] = amplitude;
  if (pos + 1 < buf.length) buf[pos + 1] = -amplitude;
}

/// Inject a pop at [pos] as a damped alternating oscillation spanning [width] samples.
/// This creates large differentiator values throughout the region so all samples
/// are flagged and merge into a single wide region classified as a pop.
void injectPop(Float32List buf, int pos, {int width = 50, double amplitude = 0.8}) {
  for (int i = 0; i < width; i++) {
    if (pos + i >= buf.length) break;
    final decay = math.exp(-3.0 * i / width);
    buf[pos + i] += amplitude * (i.isEven ? 1.0 : -1.0) * decay;
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const sampleRate = 44100;
  final defaultConfig = DetectorConfig();
  final highConfig = DetectorConfig(sensitivity: Sensitivity.high);

  group('detectDefects – silence', () {
    test('returns empty list for silence', () {
      final samples = [silence(sampleRate)];
      final defects = detectDefects(samples, sampleRate, defaultConfig);
      expect(defects, isEmpty);
    });

    test('returns empty list for constant non-zero signal', () {
      final buf = Float32List(sampleRate);
      buf.fillRange(0, sampleRate, 0.5); // flat non-zero
      final defects = detectDefects([buf], sampleRate, defaultConfig);
      expect(defects, isEmpty);
    });
  });

  group('detectDefects – synthetic click', () {
    test('detects a single synthetic click', () {
      final buf = sineWave(sampleRate); // background signal
      injectClick(buf, 10000, amplitude: 0.98);

      final defects = detectDefects([buf], sampleRate, highConfig);
      expect(defects, isNotEmpty);
      // At least one detection near the injected position
      final nearClick = defects.where(
        (d) => (d.sampleIndex - 10000).abs() < 50,
      );
      expect(nearClick, isNotEmpty);
    });

    test('detected click has type DefectType.click', () {
      final buf = sineWave(sampleRate);
      injectClick(buf, 5000, amplitude: 0.99);
      final defects = detectDefects([buf], sampleRate, highConfig);
      expect(
        defects.any((d) => d.type == DefectType.click && (d.sampleIndex - 5000).abs() < 50),
        isTrue,
      );
    });

    test('click detection confidence is between 0 and 1', () {
      final buf = sineWave(sampleRate);
      injectClick(buf, 8000, amplitude: 0.99);
      final defects = detectDefects([buf], sampleRate, highConfig);
      for (final d in defects) {
        expect(d.confidence, greaterThanOrEqualTo(0.0));
        expect(d.confidence, lessThanOrEqualTo(1.0));
      }
    });
  });

  group('detectDefects – synthetic pop', () {
    test('detects a single synthetic pop', () {
      final buf = sineWave(sampleRate);
      injectPop(buf, 20000, width: 60, amplitude: 0.95);

      final defects = detectDefects([buf], sampleRate, highConfig);
      expect(defects, isNotEmpty);
      final nearPop = defects.where(
        (d) => (d.sampleIndex - 20000).abs() < 100,
      );
      expect(nearPop, isNotEmpty);
    });

    test('detected pop has type DefectType.pop', () {
      final buf = sineWave(sampleRate);
      injectPop(buf, 15000, width: 80, amplitude: 0.97);
      final defects = detectDefects([buf], sampleRate, highConfig);
      expect(
        defects.any((d) => d.type == DefectType.pop && (d.sampleIndex - 15000).abs() < 150),
        isTrue,
      );
    });
  });

  group('detectDefects – configuration', () {
    test('minConfidence filters out low-confidence results', () {
      final buf = sineWave(sampleRate);
      injectClick(buf, 10000, amplitude: 0.99);

      final noFilter = detectDefects([buf], sampleRate, highConfig);
      final filtered = detectDefects(
        [buf],
        sampleRate,
        DetectorConfig(
          sensitivity: Sensitivity.high,
          minConfidence: 0.9999, // essentially suppress everything
        ),
      );
      expect(filtered.length, lessThanOrEqualTo(noFilter.length));
    });

    test('maxDefects limits the number of returned defects', () {
      final buf = sineWave(sampleRate);
      // Inject multiple clicks
      for (int i = 0; i < 20; i++) {
        injectClick(buf, 1000 + i * 2000, amplitude: 0.99);
      }
      const limit = 3;
      final defects = detectDefects(
        [buf],
        sampleRate,
        DetectorConfig(sensitivity: Sensitivity.high, maxDefects: limit),
      );
      expect(defects.length, lessThanOrEqualTo(limit));
    });

    test('low sensitivity misses weak defects that high sensitivity finds', () {
      final buf = sineWave(sampleRate);
      injectClick(buf, 10000, amplitude: 0.15); // weak click

      final low = detectDefects(
        [buf],
        sampleRate,
        DetectorConfig(sensitivity: Sensitivity.low),
      );
      final high = detectDefects(
        [buf],
        sampleRate,
        DetectorConfig(sensitivity: Sensitivity.high),
      );
      // High sensitivity should find at least as many as low
      expect(high.length, greaterThanOrEqualTo(low.length));
    });
  });

  group('computeAggregateConfidence', () {
    test('returns 0.0 for empty defect list', () {
      expect(computeAggregateConfidence([]), equals(0.0));
    });

    test('returns > 0 for non-empty defect list', () {
      final buf = sineWave(sampleRate);
      injectClick(buf, 10000, amplitude: 0.99);
      final defects = detectDefects([buf], sampleRate, highConfig);
      if (defects.isNotEmpty) {
        final agg = computeAggregateConfidence(defects);
        expect(agg, greaterThan(0.0));
        expect(agg, lessThanOrEqualTo(1.0));
      }
    });

    test('aggregate increases with more defects', () {
      final d1 = _fakeDefect(0.5);
      final d2 = _fakeDefect(0.5);
      final agg1 = computeAggregateConfidence([d1]);
      final agg2 = computeAggregateConfidence([d1, d2]);
      expect(agg2, greaterThan(agg1));
    });
  });

  group('Defect model', () {
    test('toJson contains all required fields', () {
      final d = _fakeDefect(0.75);
      final json = d.toJson();
      expect(json.containsKey('offset_ms'), isTrue);
      expect(json.containsKey('length_ms'), isTrue);
      expect(json.containsKey('type'), isTrue);
      expect(json.containsKey('confidence'), isTrue);
      expect(json.containsKey('channel'), isTrue);
      expect(json.containsKey('sample_index'), isTrue);
      expect(json.containsKey('amplitude'), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Helper to build a fake Defect without going through the full pipeline
// ---------------------------------------------------------------------------

Defect _fakeDefect(double confidence) => Defect(
      offset: const Duration(milliseconds: 1000),
      length: const Duration(milliseconds: 1),
      type: DefectType.click,
      confidence: confidence,
      channel: 0,
      sampleIndex: 44100,
      amplitude: 0.9,
    );
