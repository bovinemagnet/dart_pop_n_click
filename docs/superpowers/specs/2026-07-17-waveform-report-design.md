# Waveform Visualisation in the Harness Labelling Report — Design

**Date:** 2026-07-17
**Author:** Paul Snow
**Status:** Approved

## Problem

The labelling report (`report.html`, produced by `tool/real_music_harness.dart scan`)
offers only audio playback per snippet. In audio editors a click or pop is
visually obvious once zoomed in, so a waveform image would speed up and
improve real/false labelling.

Constraint discovered during design: the report opens via `file://`, where
browsers block JavaScript `fetch()` of local WAVs (CORS), so waveforms cannot
be rendered browser-side. They must be rendered at scan time, when the
harness already holds the decoded samples.

A click is 1–10 samples wide — invisible on a ±1s envelope. Two views are
needed: a context envelope and a zoomed window where individual samples
resolve.

## Solution overview

A pure-Dart SVG renderer generates one two-panel waveform image per snippet
at scan time, written next to the snippet WAV and shown in the report via
`<img>` (relative paths are `file://`-safe). This supersedes the
"waveform visualisations — out of scope" line in
`2026-07-17-real-music-harness-design.md`.

## New unit: `tool/waveform_svg.dart`

Pure renderer, no I/O:

```dart
String waveformSvg({
  required List<double> samples,   // the defect's channel, snippet-local
  required int sampleRate,
  required int defectIndex,        // defect position within `samples`
})
```

Returns one SVG document (800×360) with two stacked panels and small
captions:

- **Context panel** (800×160): min/max envelope of the whole snippet, one
  bucket per horizontal pixel, fixed ±1.0 vertical scale, red vertical
  marker at `defectIndex`. Caption "±1 s".
- **Zoom panel** (800×160): ±20 ms around `defectIndex` drawn as a
  per-sample polyline, auto-scaled to the window's own peak amplitude with
  the scale factor in the caption (e.g. "±20 ms ×8.2"), same red marker.
  The window clamps at snippet edges; a peak of zero falls back to scale
  ×1 to avoid division by zero.

## Harness changes (`tool/real_music_harness.dart`)

- `extractSnippet` return type becomes the record
  `({List<List<double>> channels, int startSample})` so the defect's
  position within the slice is exact (`d.sampleIndex - startSample`).
  Its three existing tests update to match.
- In `runScan`'s snippet loop: after writing the snippet WAV, render
  `waveformSvg` from the defect's channel slice and write
  `snippets/<same base name>.svg`; add a `waveform` key (relative path)
  to the snippet entry.
- `buildReportHtml`: new leading "Waveform" column —
  `<a href="…svg"><img src="…svg" width="400"></a>` (scaled down in the
  table; click opens the SVG full size).

## Unchanged

- run.json schema (waveforms are derivable artefacts, not results).
- labels.json format and the merge/compare commands.
- Scan CLI options. Old runs simply lack SVGs; re-running `scan`
  regenerates the report with them.

## Testing

TDD throughout:

- `waveformSvg`: red-marker x-position maths, envelope bucket count
  (one min/max pair per pixel column), zoom-window clamping at both snippet
  edges, auto-scale caption content, zero-peak fallback.
- `extractSnippet`: updated tests assert both `channels` and `startSample`
  (including clamped cases where `startSample` is 0).
- `buildReportHtml`: existing tests extended to assert the waveform cell
  (`<img` with the entry's `waveform` path).

## Out of scope

- Interactive/zoomable waveforms (would require serving over HTTP).
- Rendering channels other than the defect's channel.
- Embedding SVGs inline in report.html (bloats full-corpus reports).
