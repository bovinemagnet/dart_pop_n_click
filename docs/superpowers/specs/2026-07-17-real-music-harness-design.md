# Real-Music Regression Harness — Design

**Date:** 2026-07-17
**Author:** Paul Snow
**Status:** Approved

## Problem

The detector performs well on synthetic fixtures but produces a severe
false-positive rate on real music. On a clean commercial FLAC rip of
transient-dense material (90s eurodance), default settings report 33,861
defects (159,256 at high sensitivity); even at low sensitivity with a 0.95
minimum confidence, ~2 false positives per second remain. Smoother material
is nearly clean, confirming the algorithm's adaptive MAD threshold (~10ms
window) fails to adapt to sustained percussion rather than being broken
outright.

Tuning fixes (configurable adaptive window — issue A; transient
discrimination — issue B) need a measurable baseline. This harness provides
it, and builds a human-labelled ground-truth set to score precision.

## Solution overview

A single committed Dart tool, `tool/real_music_harness.dart`, that uses the
library API directly (no CLI subprocesses). It scans a local music corpus,
reports defect statistics, extracts audio snippets around top detections for
listening, and accumulates human real/false labels used to score precision on
subsequent runs.

All outputs live under a git-ignored `tool/harness_results/` directory. No
music filenames are committed anywhere; the corpus location is a flag with a
local default (`/Volumes/mac_volume_1/music`).

## Commands

```bash
dart run tool/real_music_harness.dart scan [--music-dir=<dir>]
    [--sensitivity=low|medium|high] [--min-confidence=0.0]
    [--limit=N]            # only scan first N files (quick iterations)
    [--max-snippets=10]    # snippet WAVs per file, top-N by confidence
dart run tool/real_music_harness.dart merge-labels <exported-labels.json>
dart run tool/real_music_harness.dart compare <runA-dir> <runB-dir>
```

## Outputs

```
tool/harness_results/
├── labels.json                    # accumulated ground truth (survives runs)
└── runs/<timestamp>/
    ├── run.json                   # per-file counts, defects/sec, type and
    │                              # confidence histograms, detector config
    ├── report.html                # listening/labelling page
    └── snippets/<track>_<offsetMs>_<type>_<conf>.wav
```

## Data flow

For each FLAC file: decode once via `package:audio_defect_detector` → run
detector → for each of the top-N detections by confidence, slice a ±1s
stereo 16-bit WAV snippet centred on the defect. WAV encoding reuses the
`_buildWav` logic from `tool/generate_flac_fixtures.dart`, extracted into a
shared helper.

`scan` finishes by printing a summary table, and — when a previous run with
the same detector config exists — a delta against it.

## Labelling loop

`report.html` is a static page: one row per snippet with an `<audio>` player
(relative path into `snippets/`), track/offset/type/confidence details, and
Real/False buttons. An "Export labels" button downloads a JSON file;
`merge-labels` folds that export into `labels.json`.

On the next `scan`, any detection within ±50ms of a labelled position in the
same file and channel inherits its verdict. `run.json` then reports
**precision over labelled detections** alongside raw counts — the number
detector tuning (issues A and B) is measured against.

### labels.json shape

One entry per labelled detection: file path, channel, sample offset,
defect type, verdict (`real` | `false`), and the date labelled. Merging is
idempotent; a re-imported label for the same position overwrites the old
verdict.

## Testing

- Label-matching (±50ms window) and stats/precision functions are pure
  top-level functions in the harness file, covered by
  `test/harness_logic_test.dart`, written test-first.
- End-to-end verification: `scan --limit=3` against the real corpus,
  inspecting `run.json`, snippets, and the report page.

## Repo changes

- New: `tool/real_music_harness.dart`, `test/harness_logic_test.dart`,
  shared WAV-writing helper extracted from the fixture generator.
- `.gitignore`: add `tool/harness_results/`.

## Related GitHub issues

- Issue A: make the adaptive MAD threshold window configurable
  (`adaptiveWindowMs`, default 10 — current behaviour unchanged; CLI
  `--adaptive-window`).
- Issue B: transient discrimination (cross-channel coherence, post-spike
  energy persistence; opt-in flags, defaults preserve current behaviour;
  frequency-domain work relates to existing issue #14).

## Out of scope

- Changing the detector algorithm itself (issues A and B).
- Waveform visualisations in the report.
- Committing labels or any music filenames to the repository.
