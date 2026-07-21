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
  final n = values.length;
  if (n == 0) return 0.0;
  final work = Float32List.fromList(values);
  final med = medianViaSelect(work, n);
  final deviations = Float32List(n);
  for (int i = 0; i < n; i++) {
    deviations[i] = (values[i] - med).abs();
  }
  return medianViaSelect(deviations, n);
}

/// Swap two elements of [b].
void _swap(Float32List b, int i, int j) {
  final t = b[i];
  b[i] = b[j];
  b[j] = t;
}

/// Reorder [buf] within `[lo, hi]` (inclusive) so that `buf[k]` holds the value
/// it would have if that range were sorted, with every element left of `k`
/// less than or equal to `buf[k]` and every element right of it greater than or
/// equal. Returns `buf[k]`. Uses a median-of-three pivot and iterates rather
/// than recursing so degenerate inputs cannot exhaust the stack.
///
/// Partitioning is three-way (Dutch national flag: `< pivot`, `== pivot`,
/// `> pivot`) so that runs of equal values — e.g. the all-zero `|diff|`
/// windows produced by digital silence — resolve in a single pass instead of
/// degrading to O(n²) as a strict less-than partition would.
///
/// Package-internal: not exported from the public library.
double selectKth(Float32List buf, int lo, int hi, int k) {
  while (true) {
    if (lo == hi) return buf[lo];
    final mid = lo + ((hi - lo) >> 1);
    if (buf[mid] < buf[lo]) _swap(buf, lo, mid);
    if (buf[hi] < buf[lo]) _swap(buf, lo, hi);
    if (buf[hi] < buf[mid]) _swap(buf, mid, hi);
    final pivot = buf[mid];
    // Three-way partition of [lo, hi]:
    //   [lo, lt) < pivot,  [lt, gt] == pivot,  (gt, hi] > pivot.
    var lt = lo;
    var gt = hi;
    var i = lo;
    while (i <= gt) {
      final v = buf[i];
      if (v < pivot) {
        _swap(buf, lt, i);
        lt++;
        i++;
      } else if (v > pivot) {
        _swap(buf, i, gt);
        gt--;
      } else {
        i++;
      }
    }
    if (k < lt) {
      hi = lt - 1;
    } else if (k > gt) {
      lo = gt + 1;
    } else {
      return buf[k]; // k lies in the equal-to-pivot band.
    }
  }
}

/// Median of the first [n] elements of [buf], reproducing the exact semantics
/// of [median] on a sorted list — including averaging the two middle values
/// for even [n]. Reorders [buf] in place (callers pass a throwaway buffer).
///
/// Package-internal: not exported from the public library.
double medianViaSelect(Float32List buf, int n) {
  if (n == 0) return 0.0;
  final k = n ~/ 2;
  final hi = selectKth(buf, 0, n - 1, k);
  if (n.isOdd) return hi.toDouble();
  // For even n the lower-middle value is the maximum of the left partition
  // [0, k-1], which quickselect guarantees are all <= buf[k].
  var lo = buf[0];
  for (int i = 1; i < k; i++) {
    if (buf[i] > lo) lo = buf[i];
  }
  return (lo + hi) / 2.0;
}
