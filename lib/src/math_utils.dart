import 'dart:typed_data';

/// Compute the median of a **sorted** [Float32List].
///
/// Returns 0.0 for empty input. For even-length lists, returns the
/// average of the two middle values.
double median(Float32List sorted) {
  final n = sorted.length;
  if (n == 0) return 0.0;
  if (n.isOdd) return sorted[n ~/ 2].toDouble();
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
}

/// Median Absolute Deviation of [values].
///
/// Measures statistical dispersion — robust to outliers unlike standard
/// deviation. Input values do not need to be sorted.
/// Returns 0.0 for empty input.
double mad(Float32List values) {
  if (values.isEmpty) return 0.0;
  final sorted = Float32List.fromList(values)..sort();
  final med = median(sorted);
  final deviations = Float32List(sorted.length);
  for (int i = 0; i < sorted.length; i++) {
    deviations[i] = (sorted[i] - med).abs();
  }
  deviations.sort();
  return median(deviations);
}
