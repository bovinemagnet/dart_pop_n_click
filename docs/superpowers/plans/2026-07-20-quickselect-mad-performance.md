# Quickselect MAD Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sliding-window MAD hot path faster by replacing its two per-grid-point `.sort()` calls with quickselect, producing **bit-identical** detections, measured first with a benchmark harness.

**Architecture:** Add private quickselect-based median selection to `math_utils.dart` and rewrite `mad()`'s internals to use it (public signature and output unchanged). Prove equivalence with a bit-for-bit unit test against a frozen reference and a detector-level characterisation golden. A benchmark tool measures the win on synthetic buffers and (opt-in) a local FLAC corpus. Two further optimisations — a scratch-buffer detector hot path and a SIMD scan — are conditional and kept only if the benchmark shows they pay.

**Tech Stack:** Pure Dart (`dart:typed_data`, `Float32List`, `Float32x4List`), `dart test`, `dart run`.

## Global Constraints

- SDK constraint: Dart `>=3.5.0 <4.0.0`. Linting: `package:lints/recommended.yaml`.
- **Bit-identical output:** no detection may change versus current `main`. Use `expect(a, equals(b))` (exact `==`), never `closeTo`, for equivalence assertions.
- **No new public API** and **no `AnalysisStrategy` enum.** New selection helpers stay package-internal. `median()`'s public contract is untouched.
- **No in-place mutation of caller-owned buffers** — quickselect only ever reorders internal throwaway/scratch buffers.
- British spelling throughout (e.g. `analyser`, `normalise`, `behaviour`).
- Author: Paul Snow. Version/since (where applicable): `0.0.0`.
- **Commit messages must NOT contain any anthropic/claude email or co-author trailer**, and documentation must not reference tooling assistants.
- Real audio files are **never committed**; benchmark output goes under the git-ignored `tool/harness_results/`.
- Branch: `feature/quickselect-mad-performance` (already created).
- Commands: `dart test`, `dart test test/<file>.dart`, `dart analyze`, `dart run tool/<script>.dart`.

---

### Task 1: Characterisation golden (freeze today's behaviour)

Captures the *current* detector output to a committed golden **before** any production code changes, so later tasks can prove they changed nothing.

**Files:**
- Create: `test/mad_golden_test.dart`
- Create (generated, then committed): `test/fixtures/mad_golden.json`

**Interfaces:**
- Consumes: `detectDefects(List<Float32List>, int, DetectorConfig)` from `package:audio_defect_detector/src/detector.dart`; `Defect.toJson()`, `DetectorConfig`, `Sensitivity` from `src/models.dart`.
- Produces: the committed `test/fixtures/mad_golden.json` oracle used by Tasks 3–5.

- [ ] **Step 1: Write the golden test (self-recording on first run)**

Create `test/mad_golden_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_defect_detector/src/detector.dart';
import 'package:audio_defect_detector/src/models.dart';
import 'package:test/test.dart';

/// One deterministic synthetic detection scenario.
class GoldenCase {
  final String name;
  final int sampleRate;
  final List<Float32List> channels;
  final DetectorConfig config;
  const GoldenCase(this.name, this.sampleRate, this.channels, this.config);
}

List<GoldenCase> buildGoldenSignals() => [
      GoldenCase('silence_44100', 44100, [Float32List(44100)],
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('sine_48000', 48000, _stereoSine(48000, 1.0, 440.0, 0.5),
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('noise_clicks_44100', 44100, [_noiseWithDefects(44100)],
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('sine_pops_96000', 96000, [_sineWithPops(96000)],
          const DetectorConfig(sensitivity: Sensitivity.medium)),
    ];

List<Float32List> _stereoSine(int rate, double secs, double freq, double amp) {
  final n = (rate * secs).round();
  final l = Float32List(n);
  final r = Float32List(n);
  for (int i = 0; i < n; i++) {
    final s = amp * math.sin(2 * math.pi * freq * i / rate);
    l[i] = s;
    r[i] = s;
  }
  return [l, r];
}

Float32List _noiseWithDefects(int rate) {
  final rng = math.Random(42);
  final buf = Float32List(rate);
  for (int i = 0; i < rate; i++) {
    buf[i] = (rng.nextDouble() - 0.5) * 0.02;
  }
  for (final pos in [5000, 12000, 20500, 31000, 40000]) {
    buf[pos] = 0.9;
  }
  for (int i = 25000; i < 25020; i++) {
    buf[i] = 0.6;
  }
  return buf;
}

Float32List _sineWithPops(int rate) {
  final rng = math.Random(7);
  final n = rate ~/ 2;
  final buf = Float32List(n);
  for (int i = 0; i < n; i++) {
    buf[i] = 0.4 * math.sin(2 * math.pi * 220.0 * i / rate);
  }
  for (final pos in [8000, 22000, 35000]) {
    final width = 12 + rng.nextInt(20);
    for (int i = pos; i < pos + width && i < n; i++) {
      buf[i] += 0.5;
    }
  }
  return buf;
}

String encodeGolden() {
  final list = buildGoldenSignals()
      .map((c) => {
            'name': c.name,
            'sample_rate': c.sampleRate,
            'defects':
                detectDefects(c.channels, c.sampleRate, c.config)
                    .map((d) => d.toJson())
                    .toList(),
          })
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

void main() {
  test('detector output matches committed golden', () {
    final goldenFile = File('test/fixtures/mad_golden.json');
    final current = encodeGolden();
    final recording = Platform.environment['RECORD_GOLDEN'] == '1';
    if (recording || !goldenFile.existsSync()) {
      goldenFile.parent.createSync(recursive: true);
      goldenFile.writeAsStringSync('$current\n');
      fail('Golden (re)written to ${goldenFile.path}; commit it and re-run.');
    }
    expect(current, equals(goldenFile.readAsStringSync().trimRight()));
  });
}
```

- [ ] **Step 2: Record the golden**

Run: `RECORD_GOLDEN=1 dart test test/mad_golden_test.dart`
Expected: FAIL with "Golden (re)written to test/fixtures/mad_golden.json; commit it and re-run." and the file now exists.

- [ ] **Step 3: Verify the golden test now passes**

Run: `dart test test/mad_golden_test.dart`
Expected: PASS (the just-recorded golden matches current output).

- [ ] **Step 4: Sanity-check the golden content**

Run: `head -30 test/fixtures/mad_golden.json`
Expected: JSON array of 4 cases; `noise_clicks_44100` and `sine_pops_96000` have non-empty `defects`, `silence_44100` has an empty `defects` list. (If `noise_clicks_44100` is empty, the synthetic thresholds are wrong — stop and revisit before proceeding.)

- [ ] **Step 5: Commit**

```bash
git add test/mad_golden_test.dart test/fixtures/mad_golden.json
git commit -m "Add characterisation golden for detector MAD path"
```

---

### Task 2: Benchmark harness

Measures the current path (baseline) so every later change is measured, not assumed. Carries its own frozen sort-based reference so it can always assert agreement.

**Files:**
- Create: `test/reference_mad.dart`
- Create: `tool/bench_mad.dart`

**Interfaces:**
- Consumes: public `mad`, `analyseFile`, `DetectorConfig`, `Sensitivity` from `package:audio_defect_detector/audio_defect_detector.dart`; `detectDefects` from `src/detector.dart`.
- Produces: `referenceMad(Float32List) -> double` and `referenceMedian(Float32List) -> double` in `test/reference_mad.dart` — the frozen sort-based oracle shared (imported, not duplicated) by the benchmark tool (Task 2) and the equivalence test (Task 3). CLI: `dart run tool/bench_mad.dart [--music <dir>]`.

- [ ] **Step 1: Create the shared frozen reference**

Create `test/reference_mad.dart` (pure — depends only on `dart:typed_data`, so both a test and a tool can import it):

```dart
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
```

- [ ] **Step 2: Write the benchmark tool**

Create `tool/bench_mad.dart`:

```dart
/// Micro-benchmark for the MAD hot path and end-to-end analysis.
///
/// Synthetic mode (default) times the library `mad` against a frozen
/// sort-based reference and times full `detectDefects`, asserting the two
/// MAD paths agree:
///
///   dart run tool/bench_mad.dart
///
/// Real-music mode times end-to-end `analyseFile` over a local corpus
/// (never committed):
///
///   dart run tool/bench_mad.dart --music /Volumes/mac_volume_1/music
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:audio_defect_detector/src/detector.dart';

import '../test/reference_mad.dart';

Future<void> main(List<String> args) async {
  final musicIdx = args.indexOf('--music');
  if (musicIdx >= 0 && musicIdx + 1 < args.length) {
    await _benchMusic(args[musicIdx + 1]);
  } else {
    _benchSynthetic();
  }
}

void _benchSynthetic() {
  final rng = math.Random(2026);
  const windowSize = 441; // ~10 ms at 44.1 kHz
  const numWindows = 2000;
  final windows = List<Float32List>.generate(numWindows, (_) {
    final w = Float32List(windowSize);
    for (int i = 0; i < windowSize; i++) {
      w[i] = (rng.nextDouble() - 0.5) * 2.0;
    }
    return w;
  });

  for (final w in windows) {
    if (mad(w) != referenceMad(w)) {
      stderr.writeln('MISMATCH: mad != referenceMad');
      exitCode = 1;
      return;
    }
  }

  const reps = 200;
  final refMs = _time(() {
    for (final w in windows) {
      referenceMad(w);
    }
  }, reps);
  final fastMs = _time(() {
    for (final w in windows) {
      mad(w);
    }
  }, reps);
  final ops = numWindows * reps;
  stdout.writeln('MAD micro-benchmark ($windowSize-sample windows):');
  stdout.writeln('  reference : ${_nsPerOp(refMs, ops)} ns/op');
  stdout.writeln('  library   : ${_nsPerOp(fastMs, ops)} ns/op');
  stdout.writeln('  speedup   : ${(refMs / fastMs).toStringAsFixed(2)}x');

  final big = _noiseWithDefects(44100 * 30, rng);
  const dReps = 20;
  final dMs = _time(() {
    detectDefects(
        [big], 44100, const DetectorConfig(sensitivity: Sensitivity.high));
  }, dReps);
  stdout.writeln('detectDefects (30 s mono):');
  stdout.writeln('  ${(dMs / dReps).toStringAsFixed(2)} ms/call');
}

Float32List _noiseWithDefects(int n, math.Random rng) {
  final buf = Float32List(n);
  for (int i = 0; i < n; i++) {
    buf[i] = (rng.nextDouble() - 0.5) * 0.02;
  }
  for (int i = 0; i < n; i += 7000) {
    buf[i] = 0.9;
  }
  return buf;
}

/// Total wall-clock milliseconds for [reps] runs of [body] (after warmup).
double _time(void Function() body, int reps) {
  for (int i = 0; i < 3; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (int i = 0; i < reps; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / 1000.0;
}

String _nsPerOp(double totalMs, int ops) =>
    (totalMs * 1e6 / ops).toStringAsFixed(1);

Future<void> _benchMusic(String dir) async {
  final root = Directory(dir);
  if (!root.existsSync()) {
    stderr.writeln('No such directory: $dir');
    exitCode = 2;
    return;
  }
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) =>
          f.path.toLowerCase().endsWith('.flac') ||
          f.path.toLowerCase().endsWith('.wav'))
      .toList();
  if (files.isEmpty) {
    stderr.writeln('No .flac/.wav files under $dir');
    exitCode = 2;
    return;
  }
  stdout.writeln('Analysing ${files.length} files from $dir ...');
  final sw = Stopwatch()..start();
  int analysed = 0;
  int totalDefects = 0;
  for (final f in files) {
    try {
      final r = await analyseFile(f.path,
          config: const DetectorConfig(sensitivity: Sensitivity.high));
      analysed++;
      totalDefects += r.defects.length;
    } catch (_) {
      // Skip unreadable/unsupported files.
    }
  }
  sw.stop();
  final secs = sw.elapsedMilliseconds / 1000.0;
  stdout.writeln('Analysed $analysed files in ${secs.toStringAsFixed(1)} s '
      '(${(analysed / secs).toStringAsFixed(1)} files/s, '
      '$totalDefects defects total)');
}
```

- [ ] **Step 3: Run the synthetic benchmark (baseline)**

Run: `dart run tool/bench_mad.dart`
Expected: prints MAD ns/op for reference and library (speedup ≈ `1.0x` at this point, since `mad` still sorts) and a `detectDefects` ms/call figure, with **no** `MISMATCH`. Record these baseline numbers in the task's commit message.

- [ ] **Step 4: Confirm static analysis and formatting are clean**

Run: `dart analyze --fatal-warnings` then `dart format --output=none --set-exit-if-changed .`
Expected: "No issues found!" and no formatting changes required (CI runs both).

- [ ] **Step 5: Commit**

```bash
git add test/reference_mad.dart tool/bench_mad.dart
git commit -m "Add MAD + end-to-end benchmark harness"
```

---

### Task 3: Quickselect-MAD (Approach A) + bit-for-bit equivalence

Replaces the two `.sort()` calls inside `mad()` with quickselect. This is a **refactor**: the equivalence test passes before *and* after (it must never fail).

**Files:**
- Modify: `lib/src/math_utils.dart`
- Test: `test/math_utils_test.dart`

**Interfaces:**
- Consumes: existing `mad(Float32List) -> double` public signature (unchanged); `referenceMad` from `test/reference_mad.dart` (created in Task 2).
- Produces: private `_swap`, `_selectKth(Float32List, int lo, int hi, int k) -> double`, `_medianViaSelect(Float32List, int n) -> double` in `math_utils.dart`. No public API change.

- [ ] **Step 1: Write the bit-for-bit equivalence test**

At the top of `test/math_utils_test.dart` add these imports (if not already present):

```dart
import 'dart:math' as math;
import 'reference_mad.dart';
```

Then append these groups inside `main()`. They use the shared `referenceMad` from `test/reference_mad.dart` — do **not** redefine it here:

```dart
  group('mad quickselect equivalence', () {
    test('bit-for-bit identical to reference across random windows', () {
      final rng = math.Random(1234);
      for (int trial = 0; trial < 5000; trial++) {
        final n = 1 + rng.nextInt(600);
        final buf = Float32List(n);
        for (int i = 0; i < n; i++) {
          buf[i] = (rng.nextDouble() - 0.5) * 2.0;
        }
        expect(mad(buf), equals(referenceMad(buf)), reason: 'n=$n trial=$trial');
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
  });
```

- [ ] **Step 2: Run the equivalence test against current (sort-based) `mad`**

Run: `dart test test/math_utils_test.dart -n "quickselect equivalence"`
Expected: PASS. (`mad` still sorts, so it trivially equals the reference — this locks the contract before the refactor.)

- [ ] **Step 3: Add quickselect selection to `math_utils.dart`**

Append to `lib/src/math_utils.dart`:

```dart
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
double _selectKth(Float32List buf, int lo, int hi, int k) {
  while (true) {
    if (lo == hi) return buf[lo];
    final mid = lo + ((hi - lo) >> 1);
    if (buf[mid] < buf[lo]) _swap(buf, lo, mid);
    if (buf[hi] < buf[lo]) _swap(buf, lo, hi);
    if (buf[hi] < buf[mid]) _swap(buf, mid, hi);
    final pivot = buf[mid];
    _swap(buf, mid, hi); // park pivot at the end
    var store = lo;
    for (int i = lo; i < hi; i++) {
      if (buf[i] < pivot) {
        _swap(buf, store, i);
        store++;
      }
    }
    _swap(buf, store, hi); // pivot to its final position
    if (k == store) {
      return buf[k];
    } else if (k < store) {
      hi = store - 1;
    } else {
      lo = store + 1;
    }
  }
}

/// Median of the first [n] elements of [buf], reproducing the exact semantics
/// of [median] on a sorted list — including averaging the two middle values
/// for even [n]. Reorders [buf] in place (callers pass a throwaway buffer).
double _medianViaSelect(Float32List buf, int n) {
  if (n == 0) return 0.0;
  final k = n ~/ 2;
  final hi = _selectKth(buf, 0, n - 1, k);
  if (n.isOdd) return hi.toDouble();
  // For even n the lower-middle value is the maximum of the left partition
  // [0, k-1], which quickselect guarantees are all <= buf[k].
  var lo = buf[0];
  for (int i = 1; i < k; i++) {
    if (buf[i] > lo) lo = buf[i];
  }
  return (lo + hi) / 2.0;
}
```

- [ ] **Step 4: Rewrite `mad()` to use quickselect**

Replace the body of `mad` in `lib/src/math_utils.dart` with:

```dart
double mad(Float32List values) {
  final n = values.length;
  if (n == 0) return 0.0;
  final work = Float32List.fromList(values);
  final med = _medianViaSelect(work, n);
  final deviations = Float32List(n);
  for (int i = 0; i < n; i++) {
    deviations[i] = (values[i] - med).abs();
  }
  return _medianViaSelect(deviations, n);
}
```

- [ ] **Step 5: Run the equivalence test against the new (quickselect) `mad`**

Run: `dart test test/math_utils_test.dart`
Expected: PASS — every existing `median`/`mad` test plus both new equivalence tests. This proves `mad` is bit-for-bit unchanged.

- [ ] **Step 6: Run the characterisation golden and full suite**

Run: `dart test`
Expected: PASS across the whole suite, including `test/mad_golden_test.dart` (detector output unchanged).

- [ ] **Step 7: Confirm the measured speedup**

Run: `dart run tool/bench_mad.dart`
Expected: no `MISMATCH`; the MAD `speedup` line now shows the quickselect win (a ratio meaningfully above `1.0x`). Record the number for the commit message.

- [ ] **Step 8: Static analysis**

Run: `dart analyze`
Expected: "No issues found!"

- [ ] **Step 9: Commit**

```bash
git add lib/src/math_utils.dart test/math_utils_test.dart
git commit -m "Compute MAD via quickselect instead of sorting

Replaces the two per-window sorts in mad() with median-of-three quickselect.
Bit-for-bit identical output, verified against a frozen sort-based reference
over 5000 random windows plus edge cases and the detector golden."
```

---

### Task 4 (conditional): Scratch-buffer MAD in the detector hot path (Approach B)

**Decision gate:** Only do this task if the Task 3 benchmark shows per-call allocation is still a meaningful cost — i.e. re-running after this task improves `detectDefects` ms/call by a worthwhile margin. Implement, measure, and **keep only if faster**; otherwise revert with `git checkout`.

**Files:**
- Modify: `lib/src/math_utils.dart` (promote helpers so `detector.dart` can share them)
- Modify: `lib/audio_defect_detector.dart` (keep the public surface identical)
- Modify: `lib/src/detector.dart` (`_buildAdaptiveThreshold`)

**Interfaces:**
- Consumes: `_selectKth` / `_medianViaSelect` from Task 3.
- Produces: package-internal `selectKth`, `medianViaSelect` (renamed, no leading underscore) usable from `detector.dart`.

- [ ] **Step 1: Promote the selection helpers to package-internal**

In `lib/src/math_utils.dart`, rename `_selectKth` → `selectKth` and `_medianViaSelect` → `medianViaSelect` (drop the leading underscore on the declarations and on their uses inside `mad`). Leave `_swap` private. Add a one-line doc note that these are package-internal and not exported.

- [ ] **Step 2: Keep the public API surface identical**

In `lib/audio_defect_detector.dart`, change:

```dart
export 'src/math_utils.dart';
```

to:

```dart
export 'src/math_utils.dart' show median, mad;
```

This keeps exactly `median` and `mad` public (as today) while hiding the newly-named `selectKth` / `medianViaSelect`.

- [ ] **Step 3: Confirm the public API test still passes**

Run: `dart test test/public_api_test.dart`
Expected: PASS (no public symbols added or removed).

- [ ] **Step 4: Rewrite `_buildAdaptiveThreshold` to reuse scratch buffers**

In `lib/src/detector.dart`, add `import 'math_utils.dart';` is already present. Inside `_buildAdaptiveThreshold`, before `madThresholdAt` is defined, add reusable scratch buffers and replace `madThresholdAt`'s body:

```dart
  // Scratch buffers reused across every grid point (a window is at most
  // `windowSize` samples wide), eliminating per-point allocation.
  final windowBuf = Float32List(windowSize);
  final devBuf = Float32List(windowSize);

  double madThresholdAt(int i) {
    final start = math.max(0, i - half);
    final end = math.min(n, i + half);
    final len = end - start;
    if (len == 0) return _kThresholdFloor;
    for (int j = start; j < end; j++) {
      windowBuf[j - start] = diff[j].abs();
    }
    final med = medianViaSelect(windowBuf, len);
    for (int k = 0; k < len; k++) {
      devBuf[k] = (windowBuf[k] - med).abs();
    }
    final t = medianViaSelect(devBuf, len) * _kMadScaleFactor * multiplier;
    return t < _kThresholdFloor ? _kThresholdFloor : t;
  }
```

(This is bit-identical: reordering `windowBuf` in place does not change the multiset of deviations, and the median is order-independent.)

- [ ] **Step 5: Prove behaviour is unchanged**

Run: `dart test`
Expected: PASS across the suite, especially `test/mad_golden_test.dart` and `test/detector_test.dart`.

- [ ] **Step 6: Measure and decide**

Run: `dart run tool/bench_mad.dart`
Compare `detectDefects` ms/call to the Task 3 figure.
- If **improved by a worthwhile margin** → keep; go to Step 7.
- If **not improved** → revert everything in this task: `git checkout lib/src/math_utils.dart lib/audio_defect_detector.dart lib/src/detector.dart`, note the finding, and skip to Task 5.

- [ ] **Step 7: Static analysis + commit (only if kept)**

```bash
dart analyze
git add lib/src/math_utils.dart lib/audio_defect_detector.dart lib/src/detector.dart
git commit -m "Reuse scratch buffers for windowed MAD to cut GC churn

Shares quickselect median selection between mad() and the detector hot path,
computing each grid-point MAD with zero per-point allocation. Output unchanged
(golden + detector tests pass)."
```

---

### Task 5 (conditional): SIMD threshold scan

**Decision gate:** The scan is O(n) and memory-bandwidth-bound, so the expected win is small. Implement, measure, and **keep only if faster**; otherwise revert. Do not add the SIMD diff filter unless the scan itself shows a clear win.

**Files:**
- Modify: `lib/src/detector.dart` (the flag loop in `_detectOnChannel`)

**Interfaces:**
- Consumes: `diff` and `threshold` `Float32List`s already built in `_detectOnChannel`.
- Produces: no API change.

- [ ] **Step 1: Replace the scalar flag loop with a SIMD scan**

In `lib/src/detector.dart`, replace:

```dart
  // Step 3: flag samples
  final flagged = List<bool>.filled(samples.length, false);
  for (int i = 0; i < samples.length; i++) {
    flagged[i] = diff[i].abs() > threshold[i];
  }
```

with:

```dart
  // Step 3: flag samples. Compare four lanes of |diff| against the per-sample
  // threshold at once; only descend to scalar within a 4-lane chunk that trips.
  final flagged = List<bool>.filled(samples.length, false);
  final scanN = samples.length;
  final vecCount = scanN ~/ 4;
  final simdDiff =
      Float32x4List.view(diff.buffer, diff.offsetInBytes, vecCount);
  final simdThr =
      Float32x4List.view(threshold.buffer, threshold.offsetInBytes, vecCount);
  for (int b = 0; b < vecCount; b++) {
    final sm = simdDiff[b].abs().greaterThan(simdThr[b]).signMask;
    if (sm != 0) {
      final base = b << 2;
      if ((sm & 1) != 0) flagged[base] = true;
      if ((sm & 2) != 0) flagged[base + 1] = true;
      if ((sm & 4) != 0) flagged[base + 2] = true;
      if ((sm & 8) != 0) flagged[base + 3] = true;
    }
  }
  for (int i = vecCount << 2; i < scanN; i++) {
    flagged[i] = diff[i].abs() > threshold[i];
  }
```

(Bit-identical: `greaterThan` is a strict `>` on the exact float32 lane values, matching the scalar comparison; the tail loop handles a non-multiple-of-4 length.)

- [ ] **Step 2: Prove behaviour is unchanged**

Run: `dart test`
Expected: PASS, especially `test/mad_golden_test.dart` and `test/detector_test.dart`.

- [ ] **Step 3: Measure and decide**

Run: `dart run tool/bench_mad.dart`
Compare `detectDefects` ms/call to the previous figure.
- If **improved by a worthwhile margin** → keep; go to Step 4.
- If **not improved** → revert: `git checkout lib/src/detector.dart`, and record in Task 6 that the SIMD scan was memory-bound and not worth it.

- [ ] **Step 4: Static analysis + commit (only if kept)**

```bash
dart analyze
git add lib/src/detector.dart
git commit -m "Scan the threshold with Float32x4 lanes

Compares four samples of |diff| against the per-sample threshold per
instruction, dropping to scalar only inside a chunk that trips. Output
unchanged (golden + detector tests pass)."
```

---

### Task 6: Document the measured result

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Add a changelog entry**

Prepend a new entry under the top of `CHANGELOG.md` (match the file's existing heading style), stating the change and the **measured** MAD-stage speedup, plus which conditional optimisations (Approach B, SIMD scan) were kept or dropped and why. Do not promise a specific multiple that was not measured; use the benchmark's actual figure. Example wording:

```markdown
### Performance
- Windowed MAD now uses median-of-three quickselect instead of full sorts,
  giving a measured <N>x speedup on the MAD micro-benchmark with bit-identical
  detections. [Scratch-buffer hot path: kept/dropped]. [SIMD threshold scan:
  kept/dropped — memory-bound].
```

- [ ] **Step 2: Final full verification**

Run: `dart test && dart analyze`
Expected: all tests PASS, "No issues found!".

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "Document quickselect MAD performance work"
```

---

## Self-Review

**Spec coverage:**
- Bit-identical contract → Tasks 1 (golden) + 3 (bit-for-bit unit test); every conditional task re-runs both. ✓
- No enum / no new public API → Global Constraints; Task 4 Step 2 keeps `export ... show median, mad`; `public_api_test` gate. ✓
- Quickselect for MAD with exact even-length median → Task 3 `_medianViaSelect`. ✓
- Measure first (both corpora) → Task 2 (synthetic + `--music`), gates on Tasks 4/5. ✓
- Scratch-buffer Approach B, conditional → Task 4 with keep/revert gate. ✓
- SIMD conditional, in-place-mutation rejected → Task 5 (scan only, revert if not faster); no caller buffers mutated. ✓
- Document results → Task 6. ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every code step shows complete code; the only intentionally-open value is the *measured* speedup number in Task 6, which by design cannot be pre-filled.

**Type consistency:** `mad(Float32List) -> double`, `selectKth(Float32List,int,int,int) -> double`, `medianViaSelect(Float32List,int) -> double`, `referenceMad`/`refMedian` — names used identically across Tasks 2–4. Task 4 renames `_selectKth`→`selectKth` / `_medianViaSelect`→`medianViaSelect` consistently in declarations, `mad`'s uses, and `detector.dart`.

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task with review between tasks and fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.
