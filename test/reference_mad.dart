import 'dart:typed_data';

/// Frozen sort-based Median Absolute Deviation — the implementation of `mad`
/// before the quickselect rewrite. Kept as an independent oracle that shares no
/// code with the production path: the quickselect `mad` must stay bit-for-bit
/// identical to this. Imported by the unit equivalence test (Task 3) and the
/// benchmark tool (Task 2).
double referenceMad(Float32List values) {
  if (values.isEmpty) return 0.0;
  final sorted = Float32List.fromList(values)..sort();
  final med = referenceMedian(sorted);
  final dev = Float32List(sorted.length);
  for (int i = 0; i < sorted.length; i++) {
    dev[i] = (sorted[i] - med).abs();
  }
  dev.sort();
  return referenceMedian(dev);
}

/// Median of a **sorted** list, matching the production `median` semantics
/// (average of the two middle values for even length).
double referenceMedian(Float32List sorted) {
  final n = sorted.length;
  if (n == 0) return 0.0;
  if (n.isOdd) return sorted[n ~/ 2].toDouble();
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
}
