# Quickselect MAD performance — design

- **Date:** 2026-07-20
- **Author:** Paul Snow
- **Version:** 0.0.0
- **Status:** Approved (design)

## Goal

Speed up the pop/click detector so it can rip through large FLAC archives
faster, **without changing a single detection**. The faster path must produce
**bit-identical** results to the current implementation. No accuracy is traded
for speed.

## Background: what the code actually does today

The detector's adaptive threshold is a **sliding-window Median Absolute
Deviation (MAD)**, and it has *already* been optimised once. `_buildAdaptiveThreshold`
(`lib/src/detector.dart`) does not recompute a windowed MAD for every sample.
It evaluates the windowed MAD only on a **coarse grid** (spaced `windowSize / 8`
samples apart) and **linearly interpolates** between grid points. That reduces
the cost from O(n·w·log w) to O(n·log w).

The remaining hot cost is inside `mad()` (`lib/src/math_utils.dart`), which is
called once per grid point and performs **two full `.sort()` calls**:

```dart
double mad(Float32List values) {
  if (values.isEmpty) return 0.0;
  final sorted = Float32List.fromList(values)..sort(); // sort 1
  final med = median(sorted);
  final deviations = Float32List(sorted.length);
  for (int i = 0; i < sorted.length; i++) {
    deviations[i] = (sorted[i] - med).abs();
  }
  deviations.sort();                                    // sort 2
  return median(deviations);
}
```

On a 3-minute stereo track at 44.1 kHz there are roughly 144k grid points per
channel, each sorting a window of up to ~441 elements twice. That is the target.

### Why the "compute MAD once per block" idea is out of scope

An earlier proposal suggested computing MAD **once per block** instead of over a
sliding window. That is **not a faster version of this algorithm** — it removes
the local adaptivity of the threshold and therefore **changes which defects are
detected**. It is an accuracy trade-off, not a free speedup, and is explicitly
excluded by the bit-identical contract.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Accuracy contract | **Bit-identical** to current output | No detection may change |
| Strategy enum (`AnalysisStrategy`) | **Not introduced** | With exact equivalence the fast path simply *becomes* the default; a two-mode API would add surface, tests, and docs for no behavioural benefit (YAGNI) |
| Primary technique | **Quickselect** replacing the two sorts in the MAD hot path | Targets the actual bottleneck; can be made exactly equivalent |
| SIMD (diff filter + scan) | **Conditional**, measured, kept only if it wins | The diff and scan loops are O(n) and memory-bandwidth-bound; the per-sample threshold array means the scan is a lane-vs-lane compare, not the scalar-threshold compare originally sketched |
| In-place mutation of caller buffers | **Rejected** | `analyseSamples()` takes caller-owned `Float32List`; quickselect only ever reorders internal throwaway/scratch buffers |
| Benchmark + correctness corpus | **Both** — committed synthetic (CI) + opt-in real local library | Reproducible in CI *and* realistic timing on real 3-minute tracks |

## Approach: start minimal, earn the rest through measurement

Three implementation levels for the MAD speedup; we commit only to the first and
promote the others only if the benchmark justifies them.

- **A — Swap sorts for quickselect inside `mad()`.** Minimal diff, every caller
  benefits, bit-identical. Keeps the per-call allocation (a copy + a deviations
  buffer per grid point).
- **B — Scratch-reusing MAD helper in the detector hot path.** `_buildAdaptiveThreshold`
  gets reusable scratch buffers so each grid MAD allocates nothing and uses
  quickselect. Removes sort cost *and* GC churn — likely the larger real win —
  but more code, and diverges from the public `mad()`.
- **C — A first, measure, add B only if allocation shows up. (Chosen.)**

SIMD is a further conditional phase after C.

## Detailed design

### 1. Quickselect selection (private, `lib/src/math_utils.dart`)

Add private helpers; **no new public API**:

- `_selectKth(Float32List buf, int left, int right, int k)` — Hoare/Lomuto
  partition with a middle or median-of-three pivot, written iteratively (tail-call
  eliminated) so worst-case pivot choices cannot blow the stack. Reorders `buf`
  in place and returns the k-th smallest.
- `_medianViaSelect(Float32List buf, int n)` — reproduces the **exact** semantics
  of the current `median()`:
  - **odd `n`:** select `k = n ~/ 2` → that element.
  - **even `n`:** select `k = n ~/ 2` → `hi`; the lower middle `sorted[k-1]` is the
    **maximum of the left partition `[0, k-1]`** (quickselect guarantees every
    element left of `k` is ≤ `buf[k]`), found with one linear scan → `lo`. Return
    `(lo + hi) / 2.0` — the identical arithmetic to today, hence bit-identical.

### 2. `mad()` internals rewritten; signature and output unchanged

Replace the two `.sort()` calls with two `_medianViaSelect` calls over the copy
and the deviations buffer. The public `median(Float32List sorted)` function is
**untouched** — its "input already sorted" contract and its tests stay exactly
as they are. `mad()` keeps its exact numeric output.

### 3. Correctness guards (the bit-identical proof)

- **Unit equivalence** (`test/math_utils_test.dart`, extended): keep a
  `_referenceMad()` — today's sort-based implementation — inside the test and
  assert `mad(x) == referenceMad(x)` **bit-for-bit** (`expect(a, equals(b))`, not
  `closeTo`) across thousands of fixed-seed random windows plus every edge case
  (empty, 1, 2, constant, duplicates, even, odd, outliers, negatives).
- **Integration characterisation golden** (`test/mad_golden_test.dart`, new):
  captured **before any production code changes**. Generate synthetic signals
  with a fixed seed (noise, sine, silence, injected clicks/pops) at 44.1/48/96 kHz,
  run the *current* `detectDefects` / `analyseSamples`, and snapshot the defect
  list to a committed golden JSON under `test/fixtures/`. Assert equality after
  each change. This is the safety net that catches any drift introduced by
  Approach B or SIMD.

### 4. Benchmark harness (`tool/bench_mad.dart`, new)

- **Default (synthetic) mode:** builds representative buffers (white noise, sine,
  silence) at 44.1/48/96 kHz, times reference-vs-fast for both the isolated MAD
  stage and the full `detectDefects`, prints ns/op and throughput, and asserts the
  two paths agree.
- **`--music <dir>` mode:** reuses the FLAC-scanning approach from
  `tool/real_music_harness.dart` to time full-file analysis and diff defect lists
  on the local real-music library. **Audio files are never committed;** all output
  goes under the git-ignored `tool/harness_results/`.
- Uses `Stopwatch` for timing.

### 5. SIMD — conditional Phase 3, measure-gated

Only after quickselect lands and is proven equivalent:

- `Float32x4` diff filter — per-lane subtraction `x[n] - x[n-1]`, bit-identical
  (no floating-point reassociation).
- `Float32x4` scan — compare `|diff|` lanes against `threshold[i]` lanes loaded
  from the per-sample threshold array; exact compares, drop to scalar only inside
  a 4-lane chunk that trips.

**Kept only if the benchmark shows a worthwhile, bit-identical win. Otherwise the
SIMD code is removed and the finding (memory-bound, not worth it) is documented.**
The "modifies underlying buffers in-place" contract from the original sketch is
**not** adopted — it would corrupt caller-owned buffers.

## Build order

1. **Characterisation golden test** — captures today's exact behaviour first.
2. **Benchmark harness** (synthetic + `--music`) — so every later change is measured.
3. **Quickselect-MAD (Approach A)** + unit bit-for-bit equivalence test.
4. **Measure.** If per-call allocation is significant → **Approach B**; re-run golden + benchmark.
5. **Measure SIMD (Phase 3).** Keep only if it wins and stays bit-identical; else remove and document.
6. **Document results** (CHANGELOG, and the measured speedup).

## Success criteria

- All existing tests pass unchanged.
- `mad()` is bit-for-bit identical to the reference across the randomised suite.
- The characterisation golden is unchanged before and after every step.
- The benchmark reports a measured MAD-stage speedup (target: meaningful, not a
  specific promised multiple).
- Public API and the `AnalysisStrategy` surface are unchanged (nothing new exported).

## Out of scope

- `AnalysisStrategy` / `standard` vs `highPerformance` modes.
- Block/downsampled/approximate MAD.
- In-place mutation of caller-owned sample buffers.
- Any change to `median()`'s public contract.
