# Real-Music Regression Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Dart tool that scans a real FLAC music corpus with the defect detector, extracts listenable snippets around top detections, and accumulates human real/false labels to score detector precision across runs.

**Architecture:** A single committed harness (`tool/real_music_harness.dart`) uses the library API directly — decode each FLAC once, analyse, slice snippet WAVs from the decoded samples. Pure logic (label matching, stats, HTML generation) lives as top-level functions in the harness file, tested from `test/harness_logic_test.dart`. All outputs go under git-ignored `tool/harness_results/`.

**Tech Stack:** Dart >=3.5.0, `package:args` (already a dependency), `package:audio_defect_detector` (this repo), `package:test`.

**Spec:** `docs/superpowers/specs/2026-07-17-real-music-harness-design.md`

## Global Constraints

- British spelling in all identifiers, comments, and docs (e.g. `analyse`, `normalise`).
- Linting: `package:lints/recommended.yaml` — code must pass `dart analyze` cleanly.
- No music filenames committed anywhere; the corpus location is only a flag default (`/Volumes/mac_volume_1/music`).
- No new dependencies in `pubspec.yaml`.
- Commit messages: plain imperative sentences, no AI/tool references, no Co-Authored-By lines.
- Run tests with `dart test <file>`; run the full suite with `dart test` before the final task.

---

### Task 1: Shared WAV writer

Extract the WAV-encoding logic from `tool/generate_flac_fixtures.dart` into a shared helper that both the fixture generator and the harness use.

**Files:**
- Create: `tool/wav_writer.dart`
- Modify: `tool/generate_flac_fixtures.dart` (replace private `_buildWav`, lines 78–142)
- Test: `test/wav_writer_test.dart`

**Interfaces:**
- Produces: `Uint8List buildWav({required List<List<double>> channels, required int bitsPerSample, required int sampleRate})` — little-endian PCM WAV bytes; `channels` holds one list per channel, values in [-1.0, 1.0], all the same length; `bitsPerSample` is 16 or 24.

- [ ] **Step 1: Write the failing test**

Create `test/wav_writer_test.dart`:

```dart
import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import '../tool/wav_writer.dart';

void main() {
  test('buildWav output round-trips through decodeWav', () {
    final left = List<double>.generate(100, (i) => (i % 20) / 20 - 0.5);
    final right = List<double>.generate(100, (i) => -((i % 10) / 10 - 0.5));

    final bytes = buildWav(
      channels: [left, right],
      bitsPerSample: 16,
      sampleRate: 44100,
    );
    final wav = decodeWav(bytes);

    expect(wav.metadata.sampleRate, 44100);
    expect(wav.metadata.channels, 2);
    expect(wav.metadata.bitDepth, 16);
    expect(wav.samples[0].length, 100);
    for (var i = 0; i < 100; i++) {
      expect(wav.samples[0][i], closeTo(left[i], 1 / 32767 + 1e-6));
      expect(wav.samples[1][i], closeTo(right[i], 1 / 32767 + 1e-6));
    }
  });

  test('buildWav clamps out-of-range samples instead of wrapping', () {
    final bytes = buildWav(
      channels: [
        [1.5, -1.5, 0.0]
      ],
      bitsPerSample: 16,
      sampleRate: 8000,
    );
    final wav = decodeWav(bytes);
    expect(wav.samples[0][0], closeTo(1.0, 0.001));
    expect(wav.samples[0][1], closeTo(-1.0, 0.001));
    expect(wav.samples[0][2], closeTo(0.0, 0.001));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/wav_writer_test.dart`
Expected: FAIL — cannot resolve import `../tool/wav_writer.dart` (file does not exist).

- [ ] **Step 3: Write the implementation**

Create `tool/wav_writer.dart` (the body is the existing `_buildWav` from `tool/generate_flac_fixtures.dart` with `sampleRate` made a parameter and `List<List<double>>` accepted):

```dart
/// Shared little-endian PCM WAV encoder used by the fixture generator and
/// the real-music harness.
library;

import 'dart:typed_data';

/// Builds a little-endian PCM WAV file from normalised per-channel samples.
///
/// [channels] holds one list per channel, values in [-1.0, 1.0]. All
/// channels must be the same length. [bitsPerSample] may be 16 or 24.
Uint8List buildWav({
  required List<List<double>> channels,
  required int bitsPerSample,
  required int sampleRate,
}) {
  final numChannels = channels.length;
  final numFrames = channels[0].length;
  final bytesPerSample = bitsPerSample ~/ 8;
  final blockAlign = numChannels * bytesPerSample;
  final dataSize = numFrames * blockAlign;
  final byteRate = sampleRate * blockAlign;

  final buf = Uint8List(44 + dataSize);
  final bd = ByteData.sublistView(buf);
  var p = 0;
  void fourCC(String s) {
    for (final c in s.codeUnits) {
      buf[p++] = c;
    }
  }

  void u32(int v) {
    bd.setUint32(p, v, Endian.little);
    p += 4;
  }

  void u16(int v) {
    bd.setUint16(p, v, Endian.little);
    p += 2;
  }

  fourCC('RIFF');
  u32(36 + dataSize);
  fourCC('WAVE');
  fourCC('fmt ');
  u32(16);
  u16(1); // PCM
  u16(numChannels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  fourCC('data');
  u32(dataSize);

  final maxVal = (1 << (bitsPerSample - 1)) - 1;
  final minVal = -(1 << (bitsPerSample - 1));
  for (var f = 0; f < numFrames; f++) {
    for (var ch = 0; ch < numChannels; ch++) {
      var v = (channels[ch][f] * maxVal).round();
      if (v > maxVal) v = maxVal;
      if (v < minVal) v = minVal;
      if (bitsPerSample == 16) {
        bd.setInt16(p, v, Endian.little);
        p += 2;
      } else {
        final u = v & 0xFFFFFF;
        buf[p++] = u & 0xFF;
        buf[p++] = (u >> 8) & 0xFF;
        buf[p++] = (u >> 16) & 0xFF;
      }
    }
  }
  return buf;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/wav_writer_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Refactor the fixture generator to use the shared writer**

In `tool/generate_flac_fixtures.dart`:

1. Add the import below the existing imports:

```dart
import 'wav_writer.dart';
```

2. Replace every `_buildWav(channels: X, bitsPerSample: Y)` call with `buildWav(channels: X, bitsPerSample: Y, sampleRate: sampleRate)`. There are four call sites (in `main()`).
3. Delete the entire private `_buildWav` function (the block starting `/// Builds a little-endian PCM WAV file…` down to its closing `}`), and remove the now-unused `import 'dart:typed_data';` **only if** nothing else in the file uses `Uint8List` — `_writeFixture` takes a `Uint8List` parameter, so the import stays.

- [ ] **Step 6: Verify the generator still works and nothing regressed**

Run: `dart analyze`
Expected: No issues found.

Run: `dart run tool/generate_flac_fixtures.dart && git diff --stat test/fixtures/flac/`
Expected: "All fixtures generated." and an **empty diff** (byte-identical fixtures). If the diff is non-empty, stop and investigate — the refactor changed encoding behaviour.

Run: `dart test`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git checkout -- test/fixtures/flac/ 2>/dev/null; git add tool/wav_writer.dart tool/generate_flac_fixtures.dart test/wav_writer_test.dart
git commit -m "Extract shared WAV writer from fixture generator"
```

---

### Task 2: Harness skeleton — label model, merging, and matching

**Files:**
- Create: `tool/real_music_harness.dart`
- Test: `test/harness_logic_test.dart`

**Interfaces:**
- Produces:
  - `class LabelEntry { final String file; final int channel; final int sampleIndex; final String type; final String verdict; final String labelledOn; }` with `LabelEntry.fromJson(Map<String, dynamic>)`, `Map<String, dynamic> toJson()` (snake_case keys: `file`, `channel`, `sample_index`, `type`, `verdict`, `labelled_on`), and `String get positionKey`.
  - `List<LabelEntry> mergeLabels(List<LabelEntry> existing, List<LabelEntry> incoming)` — idempotent union; incoming overwrites at the same file/channel/sampleIndex.
  - `String? matchVerdict(List<LabelEntry> labels, {required String file, required int channel, required int sampleIndex, required int sampleRate, double toleranceMs = 50})` — verdict of a label within ±toleranceMs, or null.

- [ ] **Step 1: Write the failing tests**

Create `test/harness_logic_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/real_music_harness.dart';

LabelEntry label(String file, int ch, int idx, String verdict) => LabelEntry(
      file: file,
      channel: ch,
      sampleIndex: idx,
      type: 'click',
      verdict: verdict,
      labelledOn: '2026-07-17',
    );

void main() {
  group('LabelEntry JSON', () {
    test('round-trips through toJson/fromJson', () {
      final original = label('/music/a.flac', 1, 44100, 'real');
      final copy = LabelEntry.fromJson(original.toJson());
      expect(copy.file, original.file);
      expect(copy.channel, original.channel);
      expect(copy.sampleIndex, original.sampleIndex);
      expect(copy.type, original.type);
      expect(copy.verdict, original.verdict);
      expect(copy.labelledOn, original.labelledOn);
    });
  });

  group('mergeLabels', () {
    test('unions labels at different positions', () {
      final merged = mergeLabels(
        [label('/music/a.flac', 0, 100, 'real')],
        [label('/music/a.flac', 0, 200, 'false')],
      );
      expect(merged, hasLength(2));
    });

    test('incoming verdict overwrites existing at the same position', () {
      final merged = mergeLabels(
        [label('/music/a.flac', 0, 100, 'real')],
        [label('/music/a.flac', 0, 100, 'false')],
      );
      expect(merged, hasLength(1));
      expect(merged.single.verdict, 'false');
    });

    test('is idempotent', () {
      final incoming = [label('/music/a.flac', 0, 100, 'real')];
      final once = mergeLabels([], incoming);
      final twice = mergeLabels(once, incoming);
      expect(twice, hasLength(1));
    });
  });

  group('matchVerdict', () {
    final labels = [label('/music/a.flac', 0, 44100, 'false')];

    test('matches a detection within the tolerance window', () {
      // ±50ms at 44100 Hz = ±2205 samples.
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 0,
          sampleIndex: 44100 + 2000,
          sampleRate: 44100);
      expect(verdict, 'false');
    });

    test('does not match outside the tolerance window', () {
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 0,
          sampleIndex: 44100 + 3000,
          sampleRate: 44100);
      expect(verdict, isNull);
    });

    test('requires the same channel', () {
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 1,
          sampleIndex: 44100,
          sampleRate: 44100);
      expect(verdict, isNull);
    });

    test('requires the same file', () {
      final verdict = matchVerdict(labels,
          file: '/music/b.flac',
          channel: 0,
          sampleIndex: 44100,
          sampleRate: 44100);
      expect(verdict, isNull);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/harness_logic_test.dart`
Expected: FAIL — cannot resolve import `../tool/real_music_harness.dart`.

- [ ] **Step 3: Write the implementation**

Create `tool/real_music_harness.dart`:

```dart
/// Real-music regression harness for the audio defect detector.
///
/// Scans a local FLAC corpus, reports defect statistics, extracts audio
/// snippets around the highest-confidence detections for listening, and
/// accumulates human real/false labels used to score precision on
/// subsequent runs.
///
/// All outputs are written under the git-ignored `tool/harness_results/`
/// directory. Design: docs/superpowers/specs/2026-07-17-real-music-harness-design.md
///
/// Usage:
///   dart run tool/real_music_harness.dart scan [--music-dir=<dir>] [options]
///   dart run tool/real_music_harness.dart merge-labels <exported-labels.json>
///   dart run tool/real_music_harness.dart compare <runA-dir> <runB-dir>
library;

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

/// A human verdict on one detection: was it a real defect or musical
/// content misdetected?
class LabelEntry {
  /// Absolute path of the source audio file.
  final String file;

  /// Zero-based channel index of the detection.
  final int channel;

  /// Sample index of the detection peak within the file.
  final int sampleIndex;

  /// Defect type name at labelling time (e.g. 'click', 'pop').
  final String type;

  /// Either 'real' or 'false'.
  final String verdict;

  /// ISO-8601 date the label was recorded.
  final String labelledOn;

  const LabelEntry({
    required this.file,
    required this.channel,
    required this.sampleIndex,
    required this.type,
    required this.verdict,
    required this.labelledOn,
  });

  factory LabelEntry.fromJson(Map<String, dynamic> json) => LabelEntry(
        file: json['file'] as String,
        channel: json['channel'] as int,
        sampleIndex: json['sample_index'] as int,
        type: json['type'] as String,
        verdict: json['verdict'] as String,
        labelledOn: json['labelled_on'] as String,
      );

  Map<String, dynamic> toJson() => {
        'file': file,
        'channel': channel,
        'sample_index': sampleIndex,
        'type': type,
        'verdict': verdict,
        'labelled_on': labelledOn,
      };

  /// Identity of the labelled position (verdict excluded).
  String get positionKey => '$file|$channel|$sampleIndex';
}

/// Merges [incoming] labels into [existing]. Idempotent: an incoming label
/// at the same file/channel/sample position overwrites the existing verdict.
List<LabelEntry> mergeLabels(
    List<LabelEntry> existing, List<LabelEntry> incoming) {
  final byKey = {for (final l in existing) l.positionKey: l};
  for (final l in incoming) {
    byKey[l.positionKey] = l;
  }
  return byKey.values.toList()
    ..sort((a, b) => a.positionKey.compareTo(b.positionKey));
}

/// Returns the verdict of the label matching a detection at [sampleIndex]
/// on [channel] of [file], or null when no label lies within [toleranceMs]
/// of the detection.
String? matchVerdict(
  List<LabelEntry> labels, {
  required String file,
  required int channel,
  required int sampleIndex,
  required int sampleRate,
  double toleranceMs = 50,
}) {
  final toleranceSamples = (sampleRate * toleranceMs / 1000).round();
  for (final l in labels) {
    if (l.file == file &&
        l.channel == channel &&
        (l.sampleIndex - sampleIndex).abs() <= toleranceSamples) {
      return l.verdict;
    }
  }
  return null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/harness_logic_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add tool/real_music_harness.dart test/harness_logic_test.dart
git commit -m "Add harness label model with merge and tolerance matching"
```

---

### Task 3: Snippet selection and extraction helpers

**Files:**
- Modify: `tool/real_music_harness.dart` (append functions)
- Modify: `test/harness_logic_test.dart` (append groups)

**Interfaces:**
- Consumes: `Defect` (fields `offset`, `type`, `confidence`, `channel`, `sampleIndex`) and `DefectType` from `package:audio_defect_detector`.
- Produces:
  - `List<Defect> topDefects(List<Defect> defects, int n)` — highest confidence first, ties broken by earlier offset.
  - `List<int> confidenceHistogram(List<Defect> defects)` — ten bins, bin 0 = [0.0, 0.1), bin 9 = [0.9, 1.0].
  - `String slugify(String audioPath)` — file-name-safe slug of the base name without extension.
  - `String snippetName(String audioPath, Defect d)` — deterministic unique snippet file name.
  - `List<List<double>> extractSnippet(List<Float32List> channels, int sampleIndex, int sampleRate, {double halfWindowSeconds = 1.0})` — per-channel slice around the defect, clamped to bounds.

- [ ] **Step 1: Write the failing tests**

Append to `test/harness_logic_test.dart`. Add these imports at the top of the file:

```dart
import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
```

Add this helper below the existing `label` helper:

```dart
Defect defect({
  int ms = 0,
  double confidence = 0.5,
  int sampleIndex = 0,
  int channel = 0,
  DefectType type = DefectType.click,
}) =>
    Defect(
      offset: Duration(milliseconds: ms),
      length: const Duration(milliseconds: 1),
      type: type,
      confidence: confidence,
      channel: channel,
      sampleIndex: sampleIndex,
      amplitude: 0.5,
    );
```

Append these groups inside `main()`:

```dart
  group('topDefects', () {
    test('returns the n highest-confidence defects, highest first', () {
      final defects = [
        defect(ms: 10, confidence: 0.3),
        defect(ms: 20, confidence: 0.9),
        defect(ms: 30, confidence: 0.6),
      ];
      final top = topDefects(defects, 2);
      expect(top.map((d) => d.confidence), [0.9, 0.6]);
    });

    test('breaks confidence ties by earlier offset', () {
      final defects = [
        defect(ms: 200, confidence: 0.5),
        defect(ms: 100, confidence: 0.5),
      ];
      final top = topDefects(defects, 2);
      expect(top.map((d) => d.offset.inMilliseconds), [100, 200]);
    });

    test('handles n larger than the list', () {
      expect(topDefects([defect()], 10), hasLength(1));
    });
  });

  group('confidenceHistogram', () {
    test('bins confidences into ten buckets', () {
      final bins = confidenceHistogram([
        defect(confidence: 0.05),
        defect(confidence: 0.15),
        defect(confidence: 0.95),
        defect(confidence: 1.0), // top edge belongs to bin 9
      ]);
      expect(bins[0], 1);
      expect(bins[1], 1);
      expect(bins[9], 2);
      expect(bins.reduce((a, b) => a + b), 4);
    });
  });

  group('slugify and snippetName', () {
    test('slugify strips directories, extension, and unsafe characters', () {
      expect(
        slugify("/music/Test Artist/03. Test Artist - Sample Track.flac"),
        '03._Test_Artist_-_Sample_Track',
      );
    });

    test('snippetName is deterministic and embeds position details', () {
      final d = defect(
          ms: 1234, confidence: 0.87, sampleIndex: 54432, channel: 1);
      expect(
        snippetName('/music/a track.flac', d),
        'a_track_1234ms_click_c87_ch1_s54432.wav',
      );
    });
  });

  group('extractSnippet', () {
    test('extracts a window of 2 × halfWindowSeconds around the index', () {
      final channels = [Float32List(48000), Float32List(48000)];
      final slice = extractSnippet(channels, 24000, 8000);
      expect(slice, hasLength(2));
      expect(slice[0].length, 16000); // ±1s at 8000 Hz
    });

    test('clamps at the start of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 1000, 8000);
      expect(slice[0].length, 9000); // 0..1000+8000
    });

    test('clamps at the end of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 47000, 8000);
      expect(slice[0].length, 9000); // 47000-8000..48000
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/harness_logic_test.dart`
Expected: FAIL — `topDefects`, `confidenceHistogram`, `slugify`, `snippetName`, `extractSnippet` not defined.

- [ ] **Step 3: Write the implementation**

Append to `tool/real_music_harness.dart`. Add these imports at the top (below `library;`):

```dart
import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
```

Append the functions:

```dart
// ---------------------------------------------------------------------------
// Snippet selection and extraction
// ---------------------------------------------------------------------------

/// The [n] highest-confidence defects, ties broken by earlier offset.
List<Defect> topDefects(List<Defect> defects, int n) {
  final sorted = [...defects]..sort((a, b) {
      final c = b.confidence.compareTo(a.confidence);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });
  return sorted.take(n).toList();
}

/// Ten-bin histogram of defect confidences
/// (bin 0 = [0.0, 0.1) … bin 9 = [0.9, 1.0]).
List<int> confidenceHistogram(List<Defect> defects) {
  final bins = List<int>.filled(10, 0);
  for (final d in defects) {
    var bin = (d.confidence * 10).floor();
    if (bin > 9) bin = 9;
    if (bin < 0) bin = 0;
    bins[bin]++;
  }
  return bins;
}

/// A file-name-safe slug of an audio file path's base name (no extension).
String slugify(String audioPath) {
  var base = audioPath.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
}

/// Deterministic unique snippet file name for a defect within [audioPath].
String snippetName(String audioPath, Defect d) =>
    '${slugify(audioPath)}_${d.offset.inMilliseconds}ms_${d.type.name}'
    '_c${(d.confidence * 100).round()}_ch${d.channel}_s${d.sampleIndex}.wav';

/// Slices ±[halfWindowSeconds] of audio around [sampleIndex] from every
/// channel, clamped to the sample bounds.
List<List<double>> extractSnippet(
  List<Float32List> channels,
  int sampleIndex,
  int sampleRate, {
  double halfWindowSeconds = 1.0,
}) {
  final half = (sampleRate * halfWindowSeconds).round();
  final len = channels[0].length;
  var start = sampleIndex - half;
  var end = sampleIndex + half;
  if (start < 0) start = 0;
  if (end > len) end = len;
  return [for (final ch in channels) ch.sublist(start, end)];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/harness_logic_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add tool/real_music_harness.dart test/harness_logic_test.dart
git commit -m "Add harness snippet selection and extraction helpers"
```

---

### Task 4: Run summaries and the labelling report page

**Files:**
- Modify: `tool/real_music_harness.dart` (append functions)
- Modify: `test/harness_logic_test.dart` (append groups)

**Interfaces:**
- Consumes: `AnalysisResult` (fields `defects`, `metadata`), `confidenceHistogram` from Task 3.
- Produces:
  - `Map<String, dynamic> summariseFile({required String path, required AnalysisResult result, required List<String?> verdicts})` — run.json file entry with keys `path`, `duration_ms`, `defect_count`, `defects_per_second`, `by_type`, `confidence_histogram`, `labelled` (`{'real': n, 'false': n}`). `verdicts` is parallel to `result.defects` ('real', 'false', or null).
  - `Map<String, dynamic> summariseTotals(List<Map<String, dynamic>> files)` — keys `file_count`, `defect_count`, `duration_ms`, `defects_per_second`, `labelled_count`, `precision` (null when nothing labelled).
  - `String buildReportHtml(List<Map<String, dynamic>> snippetEntries)` — static labelling page; each entry holds `snippet` (relative wav path), `file`, `channel`, `sample_index`, `type` (String), `confidence` (double), `offset_ms` (int).

- [ ] **Step 1: Write the failing tests**

Append these groups inside `main()` of `test/harness_logic_test.dart`:

```dart
  group('summariseFile', () {
    AnalysisResult result() => AnalysisResult(
          defects: [
            defect(ms: 100, confidence: 0.95, type: DefectType.click),
            defect(ms: 200, confidence: 0.55, type: DefectType.click),
            defect(ms: 300, confidence: 0.35, type: DefectType.pop),
          ],
          aggregateConfidence: 1.0,
          metadata: const AudioMetadata(
            sampleRate: 44100,
            bitDepth: 16,
            channels: 2,
            duration: Duration(seconds: 10),
          ),
        );

    test('reports counts, rate, and type breakdown', () {
      final summary = summariseFile(
        path: '/music/a.flac',
        result: result(),
        verdicts: [null, null, null],
      );
      expect(summary['path'], '/music/a.flac');
      expect(summary['defect_count'], 3);
      expect(summary['defects_per_second'], closeTo(0.3, 1e-9));
      expect(summary['by_type'], {'click': 2, 'pop': 1});
      expect(summary['labelled'], {'real': 0, 'false': 0});
    });

    test('counts labelled verdicts', () {
      final summary = summariseFile(
        path: '/music/a.flac',
        result: result(),
        verdicts: ['real', 'false', 'false'],
      );
      expect(summary['labelled'], {'real': 1, 'false': 2});
    });
  });

  group('summariseTotals', () {
    test('aggregates counts and computes precision', () {
      final totals = summariseTotals([
        {
          'defect_count': 10,
          'duration_ms': 10000,
          'labelled': {'real': 2, 'false': 6},
        },
        {
          'defect_count': 20,
          'duration_ms': 10000,
          'labelled': {'real': 2, 'false': 0},
        },
      ]);
      expect(totals['file_count'], 2);
      expect(totals['defect_count'], 30);
      expect(totals['defects_per_second'], closeTo(1.5, 1e-9));
      expect(totals['labelled_count'], 10);
      expect(totals['precision'], closeTo(0.4, 1e-9));
    });

    test('precision is null when nothing is labelled', () {
      final totals = summariseTotals([
        {
          'defect_count': 5,
          'duration_ms': 1000,
          'labelled': {'real': 0, 'false': 0},
        },
      ]);
      expect(totals['precision'], isNull);
    });
  });

  group('buildReportHtml', () {
    final html = buildReportHtml([
      {
        'snippet': 'snippets/a_100ms_click_c95_ch0_s4410.wav',
        'file': '/music/a.flac',
        'channel': 0,
        'sample_index': 4410,
        'type': 'click',
        'confidence': 0.95,
        'offset_ms': 100,
      },
    ]);

    test('embeds the snippet entries as JSON', () {
      expect(html, contains('snippets/a_100ms_click_c95_ch0_s4410.wav'));
      expect(html, contains('"sample_index": 4410'));
    });

    test('renders an audio player and export button', () {
      expect(html, contains('<audio'));
      expect(html, contains('Export labels'));
      expect(html, contains('merge-labels'));
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/harness_logic_test.dart`
Expected: FAIL — `summariseFile`, `summariseTotals`, `buildReportHtml` not defined.

- [ ] **Step 3: Write the implementation**

Add this import to `tool/real_music_harness.dart` (top of file, first import):

```dart
import 'dart:convert';
```

Append the functions:

```dart
// ---------------------------------------------------------------------------
// Run summaries
// ---------------------------------------------------------------------------

/// Builds the run.json entry for one scanned file. [verdicts] is parallel
/// to [result.defects]; entries are 'real', 'false', or null (unlabelled).
Map<String, dynamic> summariseFile({
  required String path,
  required AnalysisResult result,
  required List<String?> verdicts,
}) {
  final byType = <String, int>{};
  for (final d in result.defects) {
    byType[d.type.name] = (byType[d.type.name] ?? 0) + 1;
  }
  final seconds = result.metadata.duration.inMilliseconds / 1000;
  return {
    'path': path,
    'duration_ms': result.metadata.duration.inMilliseconds,
    'defect_count': result.defects.length,
    'defects_per_second': seconds > 0 ? result.defects.length / seconds : 0.0,
    'by_type': byType,
    'confidence_histogram': confidenceHistogram(result.defects),
    'labelled': {
      'real': verdicts.where((v) => v == 'real').length,
      'false': verdicts.where((v) => v == 'false').length,
    },
  };
}

/// Totals across per-file summaries, including precision over labelled
/// detections (null when nothing is labelled).
Map<String, dynamic> summariseTotals(List<Map<String, dynamic>> files) {
  var defects = 0, real = 0, falseCount = 0, durationMs = 0;
  for (final f in files) {
    defects += f['defect_count'] as int;
    durationMs += f['duration_ms'] as int;
    final l = f['labelled'] as Map;
    real += l['real'] as int;
    falseCount += l['false'] as int;
  }
  final labelled = real + falseCount;
  return {
    'file_count': files.length,
    'defect_count': defects,
    'duration_ms': durationMs,
    'defects_per_second':
        durationMs > 0 ? defects / (durationMs / 1000) : 0.0,
    'labelled_count': labelled,
    'precision': labelled > 0 ? real / labelled : null,
  };
}

// ---------------------------------------------------------------------------
// Labelling report page
// ---------------------------------------------------------------------------

/// Builds the static listening/labelling page. Each entry in
/// [snippetEntries] holds: snippet (relative wav path), file, channel,
/// sample_index, type, confidence, offset_ms.
String buildReportHtml(List<Map<String, dynamic>> snippetEntries) {
  final data = const JsonEncoder.withIndent('  ').convert(snippetEntries);
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Real-music harness — labelling</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 0.4rem 0.6rem; text-align: left; }
  tr.real { background: #e6ffe6; }
  tr.false { background: #ffe6e6; }
  button { margin-right: 0.3rem; }
  #export { margin-top: 1rem; padding: 0.5rem 1rem; }
</style>
</head>
<body>
<h1>Real-music harness — snippet labelling</h1>
<p>Listen to each snippet and mark it <strong>Real</strong> (a genuine
defect) or <strong>False</strong> (musical content misdetected). Then use
<em>Export labels</em> and merge the download with:
<code>dart run tool/real_music_harness.dart merge-labels &lt;download&gt;</code></p>
<table id="rows">
  <tr><th>Snippet</th><th>Track</th><th>Type</th><th>Conf</th>
      <th>Offset</th><th>Ch</th><th>Verdict</th></tr>
</table>
<button id="export">Export labels</button>
<script>
const entries = $data;
const verdicts = {};
const table = document.getElementById('rows');
entries.forEach((e, i) => {
  const tr = document.createElement('tr');
  tr.innerHTML =
    '<td><audio controls preload="none" src="' + e.snippet + '"></audio></td>' +
    '<td>' + e.file.split('/').pop() + '</td>' +
    '<td>' + e.type + '</td>' +
    '<td>' + e.confidence.toFixed(3) + '</td>' +
    '<td>' + e.offset_ms + ' ms</td>' +
    '<td>' + e.channel + '</td>' +
    '<td><button data-i="' + i + '" data-v="real">Real</button>' +
    '<button data-i="' + i + '" data-v="false">False</button></td>';
  table.appendChild(tr);
});
table.addEventListener('click', (ev) => {
  const b = ev.target.closest('button');
  if (!b) return;
  const i = Number(b.dataset.i);
  verdicts[i] = b.dataset.v;
  b.closest('tr').className = b.dataset.v;
});
document.getElementById('export').addEventListener('click', () => {
  const labels = Object.entries(verdicts).map(([i, v]) => {
    const e = entries[Number(i)];
    return { file: e.file, channel: e.channel, sample_index: e.sample_index,
             type: e.type, verdict: v,
             labelled_on: new Date().toISOString().slice(0, 10) };
  });
  const blob = new Blob([JSON.stringify(labels, null, 2)],
                        { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'labels-export.json';
  a.click();
});
</script>
</body>
</html>
''';
}
```

Note: the embedded JavaScript deliberately uses string concatenation (never
JS template literals) so nothing clashes with Dart's `$` interpolation —
the only interpolation in the template is `$data`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/harness_logic_test.dart`
Expected: PASS (all groups).

- [ ] **Step 5: Commit**

```bash
git add tool/real_music_harness.dart test/harness_logic_test.dart
git commit -m "Add harness run summaries and labelling report page"
```

---

### Task 5: The scan command

**Files:**
- Modify: `tool/real_music_harness.dart` (append `main` and scan helpers)
- Modify: `.gitignore` (add harness results directory)

**Interfaces:**
- Consumes: everything from Tasks 1–4, `decodeFlac`/`FlacData`, `analyseSamples`, `DetectorConfig`, `Sensitivity` from `package:audio_defect_detector`; `buildWav` from `tool/wav_writer.dart`.
- Produces: `Future<void> main(List<String> argv)` with the `scan` command; `List<LabelEntry> loadLabels()` reading `tool/harness_results/labels.json` (used again in Task 6).

- [ ] **Step 1: Add the imports**

At the top of `tool/real_music_harness.dart` the import block becomes:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

import 'wav_writer.dart';
```

- [ ] **Step 2: Append the CLI entry point and scan implementation**

```dart
// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Root of all harness output (git-ignored).
const String resultsDir = 'tool/harness_results';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addCommand(
      'scan',
      ArgParser()
        ..addOption('music-dir',
            help: 'Root directory of the FLAC corpus.',
            defaultsTo: '/Volumes/mac_volume_1/music')
        ..addOption('sensitivity',
            allowed: ['low', 'medium', 'high'], defaultsTo: 'medium')
        ..addOption('min-confidence',
            help: 'Suppress detections below this confidence.',
            defaultsTo: '0.0')
        ..addOption('limit',
            help: 'Only scan the first N files (0 = all).', defaultsTo: '0')
        ..addOption('max-snippets',
            help: 'Snippet WAVs per file, top-N by confidence.',
            defaultsTo: '10'),
    )
    ..addCommand('merge-labels', ArgParser())
    ..addCommand('compare', ArgParser());

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }

  switch (args.command?.name) {
    case 'scan':
      await runScan(args.command!);
    case 'merge-labels':
      runMergeLabels(args.command!.rest);
    case 'compare':
      runCompare(args.command!.rest);
    default:
      stderr.writeln('Usage: dart run tool/real_music_harness.dart '
          '<scan|merge-labels|compare> [options]');
      exitCode = 64;
  }
}

/// Loads the accumulated ground-truth labels (empty when none exist yet).
List<LabelEntry> loadLabels() {
  final f = File('$resultsDir/labels.json');
  if (!f.existsSync()) return [];
  final decoded = jsonDecode(f.readAsStringSync()) as List<dynamic>;
  return [
    for (final e in decoded) LabelEntry.fromJson(e as Map<String, dynamic>)
  ];
}

/// Scans the corpus: analyse every FLAC, write run.json, snippets, and the
/// labelling report, then print a summary and delta against the previous
/// run with the same config.
Future<void> runScan(ArgResults args) async {
  final musicDir = args['music-dir'] as String;
  final sensitivity =
      Sensitivity.values.byName(args['sensitivity'] as String);
  final minConfidence = double.parse(args['min-confidence'] as String);
  final limit = int.parse(args['limit'] as String);
  final maxSnippets = int.parse(args['max-snippets'] as String);

  final dir = Directory(musicDir);
  if (!dir.existsSync()) {
    stderr.writeln('Music directory not found: $musicDir (volume mounted?)');
    exitCode = 66;
    return;
  }

  var files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.flac'))
      .map((f) => f.path)
      .toList()
    ..sort();
  if (limit > 0 && files.length > limit) files = files.sublist(0, limit);
  if (files.isEmpty) {
    stderr.writeln('No FLAC files found under $musicDir');
    exitCode = 66;
    return;
  }

  final config = DetectorConfig(
    sensitivity: sensitivity,
    minConfidence: minConfidence,
  );
  final configJson = {
    'sensitivity': sensitivity.name,
    'min_confidence': minConfidence,
  };

  final labels = loadLabels();

  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
  final runDir = Directory('$resultsDir/runs/$stamp');
  final snippetsDir = Directory('${runDir.path}/snippets')
    ..createSync(recursive: true);

  final fileSummaries = <Map<String, dynamic>>[];
  final snippetEntries = <Map<String, dynamic>>[];

  for (var i = 0; i < files.length; i++) {
    final path = files[i];
    stdout.write('${i + 1}/${files.length}  ${path.split('/').last} … ');

    final FlacData flac;
    try {
      flac = decodeFlac(File(path).readAsBytesSync());
    } catch (e) {
      stdout.writeln('SKIP ($e)');
      continue;
    }

    final result = analyseSamples(
      flac.samples,
      sampleRate: flac.metadata.sampleRate,
      bitDepth: flac.metadata.bitDepth,
      config: config,
    );

    final verdicts = [
      for (final d in result.defects)
        matchVerdict(labels,
            file: path,
            channel: d.channel,
            sampleIndex: d.sampleIndex,
            sampleRate: flac.metadata.sampleRate),
    ];
    fileSummaries
        .add(summariseFile(path: path, result: result, verdicts: verdicts));

    for (final d in topDefects(result.defects, maxSnippets)) {
      final name = snippetName(path, d);
      final slice =
          extractSnippet(flac.samples, d.sampleIndex, flac.metadata.sampleRate);
      File('${snippetsDir.path}/$name').writeAsBytesSync(buildWav(
        channels: slice,
        bitsPerSample: 16,
        sampleRate: flac.metadata.sampleRate,
      ));
      snippetEntries.add({
        'snippet': 'snippets/$name',
        'file': path,
        'channel': d.channel,
        'sample_index': d.sampleIndex,
        'type': d.type.name,
        'confidence': d.confidence,
        'offset_ms': d.offset.inMilliseconds,
      });
    }
    stdout.writeln('${result.defects.length} defects');
  }

  final run = {
    'schema_version': '1',
    'timestamp': stamp,
    'config': configJson,
    'files': fileSummaries,
    'totals': summariseTotals(fileSummaries),
  };
  File('${runDir.path}/run.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(run));
  File('${runDir.path}/report.html')
      .writeAsStringSync(buildReportHtml(snippetEntries));

  printSummary(run);
  printDeltaAgainstPrevious(run, runDir.path);
  stdout.writeln('\nRun written to ${runDir.path}');
  stdout.writeln('Open ${runDir.path}/report.html to label snippets.');
}

/// Prints the per-file table and totals for a completed run.
void printSummary(Map<String, dynamic> run) {
  final files = (run['files'] as List).cast<Map<String, dynamic>>();
  stdout.writeln('\n${'Defects'.padLeft(8)}  ${'Rate/s'.padLeft(7)}  Track');
  for (final f in files) {
    final rate = (f['defects_per_second'] as num).toStringAsFixed(2);
    stdout.writeln('${f['defect_count'].toString().padLeft(8)}  '
        '${rate.padLeft(7)}  ${(f['path'] as String).split('/').last}');
  }
  final t = run['totals'] as Map<String, dynamic>;
  stdout.writeln('Totals: ${t['defect_count']} defects across '
      '${t['file_count']} files '
      '(${(t['defects_per_second'] as num).toStringAsFixed(2)}/s).');
  final p = t['precision'];
  if (p != null) {
    stdout.writeln('Precision over ${t['labelled_count']} labelled '
        'detections: ${((p as num) * 100).toStringAsFixed(1)}%');
  } else {
    stdout.writeln('No labelled detections yet — open report.html to label.');
  }
}

/// Prints the total-defect delta against the most recent earlier run that
/// used the same detector config. Silent when no comparable run exists.
void printDeltaAgainstPrevious(Map<String, dynamic> run, String currentDir) {
  final runsRoot = Directory('$resultsDir/runs');
  if (!runsRoot.existsSync()) return;
  final dirs = runsRoot.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  Map<String, dynamic>? previous;
  for (final d in dirs) {
    if (d.path == currentDir) continue;
    final f = File('${d.path}/run.json');
    if (!f.existsSync()) continue;
    final candidate =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    if (jsonEncode(candidate['config']) == jsonEncode(run['config'])) {
      previous = candidate; // dirs sorted ascending → last match wins
    }
  }
  if (previous == null) return;
  final cur = run['totals'] as Map<String, dynamic>;
  final prev = previous['totals'] as Map<String, dynamic>;
  final delta = (cur['defect_count'] as int) - (prev['defect_count'] as int);
  stdout.writeln('Delta vs run ${previous['timestamp']} (same config): '
      '${delta >= 0 ? '+' : ''}$delta defects '
      '(${prev['defect_count']} → ${cur['defect_count']}).');
}
```

`main` references `runMergeLabels` and `runCompare`, which Task 6
implements. To keep the file compiling and `dart analyze` green at the end
of this task, also append these two temporary definitions (Task 6 replaces
them entirely):

```dart
/// Implemented in the merge/compare task.
void runMergeLabels(List<String> rest) {
  stderr.writeln('merge-labels: not yet implemented');
  exitCode = 70;
}

/// Implemented in the merge/compare task.
void runCompare(List<String> rest) {
  stderr.writeln('compare: not yet implemented');
  exitCode = 70;
}
```

These are replaced (not kept) by Task 6.

- [ ] **Step 3: Add the results directory to .gitignore**

Append to `.gitignore`:

```
# Local real-music harness output (never committed)
tool/harness_results/
```

- [ ] **Step 4: Verify with a limited scan**

Run: `dart analyze`
Expected: No issues found.

Run: `dart run tool/real_music_harness.dart scan --limit=2 --max-snippets=3`
Expected: two progress lines ending in defect counts, a summary table,
"No labelled detections yet…", and the run/report paths. Then:

Run: `ls tool/harness_results/runs/*/snippets/ | head` and `python3 -c "import json;print(json.load(open(sorted(__import__('glob').glob('tool/harness_results/runs/*/run.json'))[-1]))['totals'])"`
Expected: up to 6 snippet WAVs; totals map with `defect_count`, `precision: None`.

Run: `git status --short`
Expected: `tool/harness_results/` does NOT appear (ignored).

- [ ] **Step 5: Run the full test suite**

Run: `dart test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tool/real_music_harness.dart .gitignore
git commit -m "Add harness scan command with snippets and run reports"
```

---

### Task 6: merge-labels and compare commands

**Files:**
- Modify: `tool/real_music_harness.dart` (replace the two stub functions)

**Interfaces:**
- Consumes: `mergeLabels`, `loadLabels`, `LabelEntry`, `resultsDir` from earlier tasks.
- Produces: `void runMergeLabels(List<String> rest)`, `void runCompare(List<String> rest)`.

- [ ] **Step 1: Replace the stubs with the implementations**

Delete the two "not yet implemented" stubs and add:

```dart
/// Merges a labels file exported from report.html into the accumulated
/// ground truth at tool/harness_results/labels.json.
void runMergeLabels(List<String> rest) {
  if (rest.length != 1) {
    stderr.writeln('Usage: dart run tool/real_music_harness.dart '
        'merge-labels <exported-labels.json>');
    exitCode = 64;
    return;
  }
  final incomingFile = File(rest.single);
  if (!incomingFile.existsSync()) {
    stderr.writeln('File not found: ${rest.single}');
    exitCode = 66;
    return;
  }
  final incoming = [
    for (final e in jsonDecode(incomingFile.readAsStringSync()) as List)
      LabelEntry.fromJson(e as Map<String, dynamic>)
  ];
  final merged = mergeLabels(loadLabels(), incoming);
  final out = File('$resultsDir/labels.json')..createSync(recursive: true);
  out.writeAsStringSync(const JsonEncoder.withIndent('  ')
      .convert([for (final l in merged) l.toJson()]));
  stdout.writeln('Merged ${incoming.length} labels; '
      '${merged.length} total in $resultsDir/labels.json');
}

/// Prints per-file and total defect-count deltas between two run
/// directories (each containing a run.json).
void runCompare(List<String> rest) {
  if (rest.length != 2) {
    stderr.writeln('Usage: dart run tool/real_music_harness.dart '
        'compare <runA-dir> <runB-dir>');
    exitCode = 64;
    return;
  }
  final runs = <Map<String, dynamic>>[];
  for (final dir in rest) {
    final f = File('$dir/run.json');
    if (!f.existsSync()) {
      stderr.writeln('No run.json in $dir');
      exitCode = 66;
      return;
    }
    runs.add(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  }
  final a = runs[0], b = runs[1];
  stdout.writeln('Comparing ${a['timestamp']} → ${b['timestamp']}');
  if (jsonEncode(a['config']) != jsonEncode(b['config'])) {
    stdout.writeln('NOTE: configs differ: ${a['config']} vs ${b['config']}');
  }
  final byPathA = {
    for (final f in (a['files'] as List).cast<Map<String, dynamic>>())
      f['path'] as String: f
  };
  for (final fb in (b['files'] as List).cast<Map<String, dynamic>>()) {
    final fa = byPathA[fb['path']];
    if (fa == null) continue;
    final delta = (fb['defect_count'] as int) - (fa['defect_count'] as int);
    stdout.writeln('${'${delta >= 0 ? '+' : ''}$delta'.padLeft(7)}  '
        '${(fb['path'] as String).split('/').last}');
  }
  final ta = a['totals'] as Map<String, dynamic>;
  final tb = b['totals'] as Map<String, dynamic>;
  stdout.writeln(
      "Totals: ${ta['defect_count']} → ${tb['defect_count']} defects");
}
```

- [ ] **Step 2: Verify merge-labels end-to-end with a synthetic export**

Create a fake export in the scratchpad and merge it twice (idempotence):

```bash
cat > /tmp/harness-test-labels.json <<'EOF'
[
  {"file": "/music/test.flac", "channel": 0, "sample_index": 1000,
   "type": "click", "verdict": "false", "labelled_on": "2026-07-17"}
]
EOF
dart run tool/real_music_harness.dart merge-labels /tmp/harness-test-labels.json
dart run tool/real_music_harness.dart merge-labels /tmp/harness-test-labels.json
python3 -c "import json;print(len(json.load(open('tool/harness_results/labels.json'))))"
```

Expected: "Merged 1 labels; 1 total …" twice, then `1`.

Remove the synthetic label so it never pollutes real ground truth:

```bash
rm tool/harness_results/labels.json /tmp/harness-test-labels.json
```

- [ ] **Step 3: Verify compare between two runs**

Run a second limited scan, then compare the two run directories:

```bash
dart run tool/real_music_harness.dart scan --limit=2 --max-snippets=3
RUNS=$(ls -d tool/harness_results/runs/* | tail -2)
dart run tool/real_music_harness.dart compare $RUNS
```

Expected: "Comparing <stampA> → <stampB>", per-file `+0` lines (same
config, same files), totals line. The second scan should also have printed
"Delta vs run <stampA> (same config): +0 defects".

- [ ] **Step 4: Analyse and full test suite**

Run: `dart analyze && dart test`
Expected: no issues; all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tool/real_music_harness.dart
git commit -m "Add harness merge-labels and compare commands"
```

---

### Task 7: End-to-end verification and baseline run

**Files:**
- No source changes expected (fix anything found, then re-run the relevant task's tests).

- [ ] **Step 1: Full-quality gate**

Run: `dart analyze && dart test`
Expected: no issues; all tests PASS.

- [ ] **Step 2: Real labelling round-trip**

1. Run: `dart run tool/real_music_harness.dart scan --limit=3`
2. Open the newest `tool/harness_results/runs/<stamp>/report.html` in a browser.
3. Play at least two snippets; click Real/False on each; click Export labels.
4. Run: `dart run tool/real_music_harness.dart merge-labels ~/Downloads/labels-export.json`
5. Re-run: `dart run tool/real_music_harness.dart scan --limit=3`

Expected: the second scan prints "Precision over N labelled detections: …"
with N ≥ 2, and per-file `labelled` counts in run.json are non-zero.

This step needs a human ear — hand it to the user rather than automating it.

- [ ] **Step 3: Full-corpus baseline run**

Run: `dart run tool/real_music_harness.dart scan`
Expected: all ~160 files scanned (a few minutes), run written. This run's
run.json is the baseline that issues #39 (adaptive window) and #40
(transient discrimination) will be measured against.

- [ ] **Step 4: Commit any fixes made during verification**

```bash
git status --short   # confirm only intended files changed
git add -A -- tool/ test/ .gitignore
git commit -m "Polish harness after end-to-end verification"  # only if there are changes
```

---

## Self-Review Notes

- **Spec coverage:** scan/merge-labels/compare commands (Tasks 5–6), snippets + report.html labelling loop (Tasks 3–5), labels.json shape + idempotent merge (Task 2), precision scoring via ±50ms matching (Tasks 2, 4, 5), shared WAV writer extraction (Task 1), .gitignore (Task 5), TDD for pure logic (Tasks 1–4), end-to-end `--limit=3` verification (Task 7). No gaps found.
- **Type consistency:** `LabelEntry` field/JSON names, `resultsDir`, `loadLabels`, and the run.json keys are used identically across Tasks 2, 4, 5, 6. `buildWav(channels: List<List<double>>, …)` accepts both `Float64List` lists (generator) and `extractSnippet`'s `List<List<double>>`.
- **Known simplification:** `matchVerdict` is O(labels) per detection; fine at this corpus size.
