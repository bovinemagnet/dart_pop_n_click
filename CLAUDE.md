# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
dart pub get              # Install dependencies
dart test                 # Run all tests
dart test test/detector_test.dart  # Run a single test file
dart test -n "test name"  # Run a single test by name
dart analyze              # Run static analysis/linter
dart bin/audiodefect.dart analyse <file>  # Run CLI from source
```

## Architecture

This is a pure Dart library (`audio_defect_detector`) for detecting pops and clicks in audio files. The codebase follows a layered architecture:

```
models → pcm_decoder → wav/aiff/flac decoders → detector → analyser → CLI (bin/audiodefect.dart)
                ↑                                    ↑
           math_utils ───────────────────────────────┘
```

- **`lib/src/models.dart`** — Data models (`DetectorConfig`, `Defect`, `AnalysisResult`, `AudioMetadata`), enums (`Sensitivity`, `DefectType`), and custom exceptions
- **`lib/src/wav_decoder.dart`** — Pure-Dart RIFF/WAV parser supporting PCM 8/16/24/32-bit and IEEE Float 32-bit; normalises samples to `Float32List` in [-1.0, 1.0]
- **`lib/src/aiff_decoder.dart`** — Pure-Dart AIFF/AIFF-C parser supporting big-endian PCM 8/16/24/32-bit and `sowt` little-endian variant; follows the same pattern as wav_decoder and delegates to pcm_decoder
- **`lib/src/flac_decoder.dart`** — FLAC parser; `decodeFlac()` wraps the pure-Dart `dart_flac` package and adapts its output to the same `FlacData` (metadata + per-channel `Float32List`) shape as wav_decoder/aiff_decoder. Native FLAC streams only (no Ogg-FLAC).
- **`lib/src/detector.dart`** — Core detection algorithm: high-pass differentiator → adaptive MAD threshold over ~10ms window → region merging → classification (click: 1–10 samples, pop: 11–150 samples) → logistic confidence scoring. Also detects clipping (runs of consecutive samples at ±1.0), dropouts (brief unexpected digital silence mid-audio), and reports per-channel DC offset via `AnalysisResult.dcOffsetPerChannel`.
- **`lib/src/pcm_decoder.dart`** — Raw PCM byte normalisation, used by wav_decoder and available directly via `decodePcmBytes()`
- **`lib/src/math_utils.dart`** — Public statistical utilities (`median`, `mad`) used by the detector and available to consumers
- **`lib/src/analyser.dart`** — Async top-level API (`analyseFile()`, `analyseBytes()`, `analysePcm()`, `analyseSamples()`) that bridges decoder and detector with format auto-detection via magic bytes
- **`bin/audiodefect.dart`** — CLI tool (`audiodefect analyse`) with glob support, text/JSON output, sensitivity/confidence/threshold options, raw PCM mode, exit codes 0-3

## Key Conventions

- SDK constraint: Dart >=3.5.0 <4.0.0
- Linting: `package:lints/recommended.yaml`
- Tests use synthetic audio generation (silence, sine waves, injected defects); the fixture files are the FLAC samples under `test/fixtures/flac/` (regenerable via `dart run tool/generate_flac_fixtures.dart`) and the detector MAD characterisation golden `test/fixtures/mad_golden.json` (regenerable via `RECORD_GOLDEN=1 dart test test/mad_golden_test.dart`)
- Public API is exported through `lib/audio_defect_detector.dart`
- British spelling throughout (e.g. `analyser`, `normalise`)
