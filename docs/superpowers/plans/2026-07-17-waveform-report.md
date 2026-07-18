# Waveform Visualisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-panel waveform SVG per snippet to the harness labelling report so clicks/pops are visually identifiable.

**Architecture:** A new pure renderer (`tool/waveform_svg.dart`) turns a snippet's samples into one SVG with a full-snippet min/max envelope (fixed ±1.0 scale) and a ±20ms auto-scaled zoom, both with a red defect marker. `runScan` writes the SVG next to each snippet WAV; the report shows it via `<img>` (relative paths, `file://`-safe). `extractSnippet` gains a `startSample` in its return so the defect's snippet-local index is exact.

**Tech Stack:** Dart >=3.5.0, no new dependencies, `package:test`.

**Spec:** `docs/superpowers/specs/2026-07-17-waveform-report-design.md`

## Global Constraints

- British spelling in all identifiers, comments, and docs.
- `dart analyze` clean AND `dart format --output=none --set-exit-if-changed .` clean (CI gate) — run `dart format` on touched files before committing.
- No music filenames committed anywhere; no new dependencies.
- Commit messages: plain imperative sentences, no AI/tool references, no Co-Authored-By lines.

---

### Task 1: The SVG waveform renderer

**Files:**
- Create: `tool/waveform_svg.dart`
- Test: `test/waveform_svg_test.dart`

**Interfaces:**
- Produces: `String waveformSvg({required List<double> samples, required int sampleRate, required int defectIndex})` — a complete `<svg>` document, 800 wide, two 160-high panels each followed by a 20-high caption strip (total height 360).

- [ ] **Step 1: Write the failing tests**

Create `test/waveform_svg_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/waveform_svg.dart';

void main() {
  List<double> silence(int n) => List<double>.filled(n, 0.0);

  test('context marker sits at the defect position', () {
    final svg = waveformSvg(
        samples: silence(1000), sampleRate: 8000, defectIndex: 500);
    // 500/1000 × 800 = 400.0; context marker spans y=0..160.
    expect(svg, contains('x1="400.0" y1="0" x2="400.0" y2="160"'));
  });

  test('envelope draws one column per horizontal pixel', () {
    final svg = waveformSvg(
        samples: silence(16000), sampleRate: 8000, defectIndex: 8000);
    final path = RegExp(r'<path d="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(RegExp('M').allMatches(path).length, 800);
  });

  test('zoom window clamps at the start of the snippet', () {
    // 8000 Hz → ±160 samples; defect at 0 → window 0..160 (160 points).
    final svg = waveformSvg(
        samples: silence(1000), sampleRate: 8000, defectIndex: 0);
    final pts =
        RegExp(r'<polyline points="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(pts.trim().split(' ').length, 160);
  });

  test('zoom window clamps at the end of the snippet', () {
    // defect at 999 → window 839..1000 (161 points).
    final svg = waveformSvg(
        samples: silence(1000), sampleRate: 8000, defectIndex: 999);
    final pts =
        RegExp(r'<polyline points="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(pts.trim().split(' ').length, 161);
  });

  test('zoom panel auto-scales to the window peak and captions the gain', () {
    final samples = silence(1000)..[500] = 0.25;
    final svg =
        waveformSvg(samples: samples, sampleRate: 8000, defectIndex: 500);
    expect(svg, contains('±20 ms ×4.0'));
  });

  test('silent window falls back to unity gain', () {
    final svg = waveformSvg(
        samples: silence(1000), sampleRate: 8000, defectIndex: 500);
    expect(svg, contains('±20 ms ×1.0'));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/waveform_svg_test.dart`
Expected: FAIL — cannot resolve import `../tool/waveform_svg.dart`.

- [ ] **Step 3: Write the implementation**

Create `tool/waveform_svg.dart`:

```dart
/// Pure SVG waveform renderer for the harness labelling report.
///
/// Produces a two-panel image per snippet: a full-snippet min/max envelope
/// at a fixed ±1.0 scale (context), and a ±20 ms window around the defect
/// drawn sample-by-sample and auto-scaled to its own peak (zoom) — the view
/// where a genuine click stands out as an isolated spike.
library;

import 'dart:math' as math;

const int _width = 800;
const int _panelHeight = 160;
const int _captionHeight = 20;

/// Renders a two-panel waveform SVG for one snippet.
///
/// [samples] is the defect's channel, snippet-local; [defectIndex] is the
/// defect position within [samples]. Both panels carry a red marker at the
/// defect position.
String waveformSvg({
  required List<double> samples,
  required int sampleRate,
  required int defectIndex,
}) {
  final n = samples.length;
  final contextPath = _envelopePath(samples);
  final contextMarkerX = n > 0 ? defectIndex / n * _width : 0.0;

  final zoomHalf = (sampleRate * 0.020).round();
  var zStart = defectIndex - zoomHalf;
  var zEnd = defectIndex + zoomHalf;
  if (zStart < 0) zStart = 0;
  if (zEnd > n) zEnd = n;
  final zLen = math.max(1, zEnd - zStart);

  var peak = 0.0;
  for (var i = zStart; i < zEnd; i++) {
    final a = samples[i].abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 1.0 / peak : 1.0;

  const zoomTop = _panelHeight + _captionHeight;
  const zoomMid = zoomTop + _panelHeight / 2;
  final points = StringBuffer();
  for (var i = zStart; i < zEnd; i++) {
    final x = (i - zStart) / zLen * _width;
    final y = zoomMid - samples[i] * gain * (_panelHeight / 2 - 2);
    points
      ..write(x.toStringAsFixed(1))
      ..write(',')
      ..write(y.toStringAsFixed(1))
      ..write(' ');
  }
  final zoomMarkerX = (defectIndex - zStart) / zLen * _width;

  const height = 2 * (_panelHeight + _captionHeight);
  final cx = contextMarkerX.toStringAsFixed(1);
  final zx = zoomMarkerX.toStringAsFixed(1);
  return '''
<svg xmlns="http://www.w3.org/2000/svg" width="$_width" height="$height" viewBox="0 0 $_width $height">
<rect x="0" y="0" width="$_width" height="$_panelHeight" fill="#fafafa"/>
<line x1="0" y1="${_panelHeight ~/ 2}" x2="$_width" y2="${_panelHeight ~/ 2}" stroke="#ddd"/>
<path d="$contextPath" stroke="#1565c0" fill="none"/>
<line x1="$cx" y1="0" x2="$cx" y2="$_panelHeight" stroke="#d32f2f"/>
<text x="4" y="${_panelHeight + 14}" font-family="sans-serif" font-size="12" fill="#555">±1 s</text>
<rect x="0" y="$zoomTop" width="$_width" height="$_panelHeight" fill="#fafafa"/>
<line x1="0" y1="${zoomTop + _panelHeight ~/ 2}" x2="$_width" y2="${zoomTop + _panelHeight ~/ 2}" stroke="#ddd"/>
<polyline points="$points" stroke="#1565c0" fill="none"/>
<line x1="$zx" y1="$zoomTop" x2="$zx" y2="${zoomTop + _panelHeight}" stroke="#d32f2f"/>
<text x="4" y="${zoomTop + _panelHeight + 14}" font-family="sans-serif" font-size="12" fill="#555">±20 ms ×${gain.toStringAsFixed(1)}</text>
</svg>
''';
}

/// One min/max envelope column per horizontal pixel, fixed ±1.0 scale,
/// emitted as an SVG path of vertical strokes ("Mx y1Lx y2 " per column).
String _envelopePath(List<double> samples) {
  final n = samples.length;
  if (n == 0) return '';
  const mid = _panelHeight / 2;
  final buf = StringBuffer();
  for (var x = 0; x < _width; x++) {
    var lo = (x * n / _width).floor();
    var hi = ((x + 1) * n / _width).ceil();
    if (hi <= lo) hi = lo + 1;
    if (hi > n) hi = n;
    if (lo >= n) lo = n - 1;
    var minV = samples[lo], maxV = samples[lo];
    for (var i = lo + 1; i < hi; i++) {
      final v = samples[i];
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final y1 = mid - maxV.clamp(-1.0, 1.0) * (_panelHeight / 2 - 2);
    final y2 = mid - minV.clamp(-1.0, 1.0) * (_panelHeight / 2 - 2);
    buf
      ..write('M')
      ..write(x)
      ..write(' ')
      ..write(y1.toStringAsFixed(1))
      ..write('L')
      ..write(x)
      ..write(' ')
      ..write(y2.toStringAsFixed(1))
      ..write(' ');
  }
  return buf.toString();
}
```

Note: if `const zoomMid = …` / `const height = …` trip the analyzer (non-const double arithmetic), change those two to `final`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/waveform_svg_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Gate and commit**

Run: `dart format tool/waveform_svg.dart test/waveform_svg_test.dart && dart analyze`
Expected: clean.

```bash
git add tool/waveform_svg.dart test/waveform_svg_test.dart
git commit -m "Add pure SVG waveform renderer for harness snippets"
```

---

### Task 2: extractSnippet returns its start sample

**Files:**
- Modify: `tool/real_music_harness.dart:155-170` (extractSnippet) and `:448-466` (its call site in `runScan`)
- Test: `test/harness_logic_test.dart:173-192` (extractSnippet group)

**Interfaces:**
- Consumes: current `List<List<double>> extractSnippet(List<Float32List> channels, int sampleIndex, int sampleRate, {double halfWindowSeconds = 1.0})`.
- Produces: `({List<List<double>> channels, int startSample}) extractSnippet(...)` — same clamping behaviour, plus the slice's first sample index in the source audio.

- [ ] **Step 1: Update the tests to the new return shape (failing)**

Replace the whole `group('extractSnippet', …)` in `test/harness_logic_test.dart` with:

```dart
  group('extractSnippet', () {
    test('extracts a window of 2 × halfWindowSeconds around the index', () {
      final channels = [Float32List(48000), Float32List(48000)];
      final slice = extractSnippet(channels, 24000, 8000);
      expect(slice.channels, hasLength(2));
      expect(slice.channels[0].length, 16000); // ±1s at 8000 Hz
      expect(slice.startSample, 16000); // 24000 − 8000
    });

    test('clamps at the start of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 1000, 8000);
      expect(slice.channels[0].length, 9000); // 0..1000+8000
      expect(slice.startSample, 0);
    });

    test('clamps at the end of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 47000, 8000);
      expect(slice.channels[0].length, 9000); // 47000-8000..48000
      expect(slice.startSample, 39000);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/harness_logic_test.dart`
Expected: FAIL — compile error: the getters `channels`/`startSample` aren't defined for `List<List<double>>`.

- [ ] **Step 3: Change the implementation and its call site**

In `tool/real_music_harness.dart`, replace `extractSnippet`:

```dart
/// Slices ±[halfWindowSeconds] of audio around [sampleIndex] from every
/// channel, clamped to the sample bounds. Returns the per-channel slices
/// and the slice's first sample index within the source audio.
({List<List<double>> channels, int startSample}) extractSnippet(
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
  return (
    channels: [for (final ch in channels) ch.sublist(start, end)],
    startSample: start,
  );
}
```

And in `runScan`'s snippet loop, change the `buildWav` call's channels argument from `slice` to `slice.channels`:

```dart
      File('${snippetsDir.path}/$name').writeAsBytesSync(buildWav(
        channels: slice.channels,
        bitsPerSample: 16,
        sampleRate: flac.metadata.sampleRate,
      ));
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/harness_logic_test.dart`
Expected: PASS.

- [ ] **Step 5: Gate and commit**

Run: `dart format tool/real_music_harness.dart test/harness_logic_test.dart && dart analyze`
Expected: clean.

```bash
git add tool/real_music_harness.dart test/harness_logic_test.dart
git commit -m "Return the start sample from extractSnippet"
```

---

### Task 3: Wire waveforms into scan and the report

**Files:**
- Modify: `tool/real_music_harness.dart` — import block, `runScan` snippet loop (~:448-466), `buildReportHtml` (~:231-302)
- Test: `test/harness_logic_test.dart:266-289` (buildReportHtml group)

**Interfaces:**
- Consumes: `waveformSvg(...)` from Task 1, `extractSnippet(...).startSample` from Task 2.
- Produces: snippet entries carry a `waveform` key (relative SVG path); report has a leading "Waveform" column.

- [ ] **Step 1: Extend the buildReportHtml tests (failing)**

In `test/harness_logic_test.dart`, in the `group('buildReportHtml', …)`, add a `'waveform'` key to the existing entry map:

```dart
      {
        'snippet': 'snippets/a_100ms_click_c95_ch0_s4410.wav',
        'waveform': 'snippets/a_100ms_click_c95_ch0_s4410.svg',
        'file': '/music/a.flac',
        'channel': 0,
        'sample_index': 4410,
        'type': 'click',
        'confidence': 0.95,
        'offset_ms': 100,
      },
```

and add this test to the group:

```dart
    test('renders a waveform column linking the snippet SVG', () {
      expect(html, contains('<th>Waveform</th>'));
      expect(html, contains('<img src='));
      expect(html,
          contains('"waveform": "snippets/a_100ms_click_c95_ch0_s4410.svg"'));
    });
```

- [ ] **Step 2: Run tests to verify the new test fails**

Run: `dart test test/harness_logic_test.dart`
Expected: FAIL — `renders a waveform column linking the snippet SVG` (no `<th>Waveform</th>` yet). All other tests pass.

- [ ] **Step 3: Implement**

In `tool/real_music_harness.dart`:

1. Add to the import block (with the other relative imports):

```dart
import 'waveform_svg.dart';
```

2. In `buildReportHtml`'s HTML template, change the header row to:

```html
  <tr><th>Waveform</th><th>Snippet</th><th>Track</th><th>Type</th>
      <th>Conf</th><th>Offset</th><th>Ch</th><th>Verdict</th></tr>
```

3. In the template's JS row builder, prepend a waveform cell (string concatenation, no JS template literals):

```js
  tr.innerHTML =
    '<td><a href="' + e.waveform + '"><img src="' + e.waveform +
    '" width="400"></a></td>' +
    '<td><audio controls preload="none" src="' + e.snippet + '"></audio></td>' +
```

(the remaining cells are unchanged).

4. In `runScan`'s snippet loop, after the `buildWav` write and before `snippetEntries.add`, generate the SVG:

```dart
      final svgName = name.replaceAll(RegExp(r'\.wav$'), '.svg');
      File('${snippetsDir.path}/$svgName').writeAsStringSync(waveformSvg(
        samples: slice.channels[d.channel],
        sampleRate: flac.metadata.sampleRate,
        defectIndex: d.sampleIndex - slice.startSample,
      ));
```

5. Add the key to the entry map:

```dart
      snippetEntries.add({
        'snippet': 'snippets/$name',
        'waveform': 'snippets/$svgName',
        'file': path,
        'channel': d.channel,
        'sample_index': d.sampleIndex,
        'type': d.type.name,
        'confidence': d.confidence,
        'offset_ms': d.offset.inMilliseconds,
      });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/harness_logic_test.dart test/waveform_svg_test.dart`
Expected: PASS.

- [ ] **Step 5: End-to-end verification against the corpus**

Run: `dart run tool/real_music_harness.dart scan --limit=2 --max-snippets=3`
(needs `/Volumes/mac_volume_1/music` mounted; ~10-30s)

Then:

```bash
ls tool/harness_results/runs/*/snippets/*.svg | wc -l   # expect 6 (latest run)
head -c 200 "$(ls tool/harness_results/runs/*/snippets/*.svg | tail -1)"
git status --short   # expect: no harness_results output listed
```

Expected: 6 SVGs in the newest run; the sampled file starts with `<svg xmlns=`; git status clean of harness output.

- [ ] **Step 6: Full gate and commit**

Run: `dart format --output=none --set-exit-if-changed . && dart analyze && dart test`
Expected: 0 changed; no issues; all tests pass.

```bash
git add tool/real_music_harness.dart test/harness_logic_test.dart
git commit -m "Add waveform images to the harness labelling report"
```

---

## Self-Review Notes

- **Spec coverage:** renderer with both panels, captions, markers, auto-scale and zero-peak fallback (Task 1); `extractSnippet` record with updated tests including clamped `startSample` (Task 2); SVG written next to WAV, `waveform` entry key, report column, report tests, end-to-end scan check (Task 3). run.json/labels/CLI untouched, matching the spec's "unchanged" section. No gaps.
- **Type consistency:** `waveformSvg` named parameters match across Tasks 1 and 3; `slice.channels`/`slice.startSample` match the record defined in Task 2; the `waveform` key spelling matches between `runScan`, `buildReportHtml` JS, and the tests.
- **Point counts in Task 1 zoom tests** were hand-derived from the clamping arithmetic (start-clamp: 0..160 → 160; end-clamp: 839..1000 → 161).
