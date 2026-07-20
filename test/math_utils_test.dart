import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import 'reference_mad.dart';

void main() {
  group('median', () {
    test('empty list returns 0.0', () {
      expect(median(Float32List(0)), equals(0.0));
    });

    test('single value returns that value', () {
      final sorted = Float32List.fromList([3.5]);
      expect(median(sorted), equals(3.5));
    });

    test('odd-length list returns middle value', () {
      final sorted = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0]);
      expect(median(sorted), equals(3.0));
    });

    test('even-length list returns average of two middle values', () {
      final sorted = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      expect(median(sorted), closeTo(2.5, 0.001));
    });

    test('even-length list with two elements', () {
      final sorted = Float32List.fromList([10.0, 20.0]);
      expect(median(sorted), closeTo(15.0, 0.001));
    });

    test('list with duplicate values', () {
      final sorted = Float32List.fromList([1.0, 1.0, 1.0, 1.0, 1.0]);
      expect(median(sorted), equals(1.0));
    });

    test('list with negative values', () {
      final sorted = Float32List.fromList([-5.0, -2.0, 0.0, 3.0, 7.0]);
      expect(median(sorted), equals(0.0));
    });

    test('large even-length list', () {
      // 128 elements (matches typical window size in detector)
      final sorted = Float32List(128);
      for (int i = 0; i < 128; i++) {
        sorted[i] = i.toDouble();
      }
      // Median of 0..127 = (63 + 64) / 2 = 63.5
      expect(median(sorted), closeTo(63.5, 0.001));
    });
  });

  group('mad', () {
    test('empty list returns 0.0', () {
      expect(mad(Float32List(0)), equals(0.0));
    });

    test('single value returns 0.0', () {
      final values = Float32List.fromList([5.0]);
      expect(mad(values), equals(0.0));
    });

    test('constant values returns 0.0', () {
      final values = Float32List.fromList([3.0, 3.0, 3.0, 3.0]);
      expect(mad(values), equals(0.0));
    });

    test('symmetric distribution', () {
      // Values: [1, 2, 3, 4, 5], median = 3
      // Deviations: [2, 1, 0, 1, 2], sorted: [0, 1, 1, 2, 2], median = 1
      final values = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0]);
      expect(mad(values), closeTo(1.0, 0.001));
    });

    test('unsorted input is handled correctly', () {
      final values = Float32List.fromList([5.0, 1.0, 3.0, 4.0, 2.0]);
      expect(mad(values), closeTo(1.0, 0.001));
    });

    test('values with outlier', () {
      // Values: [1, 2, 3, 4, 100], median = 3
      // Deviations: [2, 1, 0, 1, 97], sorted: [0, 1, 1, 2, 97], median = 1
      final values = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 100.0]);
      expect(mad(values), closeTo(1.0, 0.001));
    });

    test('even-length list', () {
      // Values: [1, 2, 3, 4], median = 2.5
      // Deviations: [1.5, 0.5, 0.5, 1.5], sorted: [0.5, 0.5, 1.5, 1.5], median = 1.0
      final values = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      expect(mad(values), closeTo(1.0, 0.001));
    });

    test('two elements', () {
      // Values: [0, 10], median = 5
      // Deviations: [5, 5], sorted: [5, 5], median = 5
      final values = Float32List.fromList([0.0, 10.0]);
      expect(mad(values), closeTo(5.0, 0.001));
    });

    test('negative values', () {
      // Values: [-3, -1, 0, 1, 3], median = 0
      // Deviations: [3, 1, 0, 1, 3], sorted: [0, 1, 1, 3, 3], median = 1
      final values = Float32List.fromList([-3.0, -1.0, 0.0, 1.0, 3.0]);
      expect(mad(values), closeTo(1.0, 0.001));
    });
  });

  group('mad quickselect equivalence', () {
    test('bit-for-bit identical to reference across random windows', () {
      final rng = math.Random(1234);
      for (int trial = 0; trial < 5000; trial++) {
        final n = 1 + rng.nextInt(600);
        final buf = Float32List(n);
        for (int i = 0; i < n; i++) {
          buf[i] = (rng.nextDouble() - 0.5) * 2.0;
        }
        expect(mad(buf), equals(referenceMad(buf)),
            reason: 'n=$n trial=$trial');
      }
    });

    test('edge cases identical to reference', () {
      const cases = <List<double>>[
        <double>[],
        [5.0],
        [3.0, 3.0],
        [1.0, 2.0],
        [2.0, 1.0],
        [1.0, 2.0, 3.0, 4.0],
        [1.0, 2.0, 3.0, 4.0, 5.0],
        [1.0, 1.0, 1.0, 1.0, 1.0],
        [-3.0, -1.0, 0.0, 1.0, 3.0],
        [1.0, 2.0, 3.0, 4.0, 100.0],
        [0.0, 10.0],
      ];
      for (final c in cases) {
        final buf = Float32List.fromList(c);
        expect(mad(buf), equals(referenceMad(buf)), reason: '$c');
      }
    });

    test('duplicate-heavy inputs identical to reference', () {
      final rng = math.Random(99);
      for (int trial = 0; trial < 200; trial++) {
        final n = 20 + rng.nextInt(80); // 20..99 elements
        final distinct = 1 + rng.nextInt(5); // few distinct values -> many ties
        final buf = Float32List(n);
        for (int i = 0; i < n; i++) {
          buf[i] = rng.nextInt(distinct).toDouble();
        }
        expect(mad(buf), equals(referenceMad(buf)),
            reason: 'n=$n distinct=$distinct trial=$trial');
      }
    });
  });
}
