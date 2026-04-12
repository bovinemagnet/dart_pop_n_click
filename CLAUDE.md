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
models → wav_decoder → detector → analyser → CLI (bin/audiodefect.dart)
```

- **`lib/src/models.dart`** — Data models (`DetectorConfig`, `Defect`, `AnalysisResult`, `AudioMetadata`), enums (`Sensitivity`, `DefectType`), and custom exceptions
- **`lib/src/wav_decoder.dart`** — Pure-Dart RIFF/WAV parser supporting PCM 8/16/24/32-bit and IEEE Float 32-bit; normalises samples to `Float32List` in [-1.0, 1.0]
- **`lib/src/detector.dart`** — Core detection algorithm: high-pass differentiator → adaptive MAD threshold over ~10ms window → region merging → classification (click: 1–10 samples, pop: 10–150 samples) → logistic confidence scoring
- **`lib/src/analyser.dart`** — Async top-level API (`analyseFile()`, `analyseBytes()`) that bridges decoder and detector with format auto-detection via magic bytes
- **`bin/audiodefect.dart`** — CLI tool (`audiodefect analyse`) with glob support, text/JSON output, sensitivity/confidence/threshold options, exit codes 0-3

## Key Conventions

- SDK constraint: Dart >=3.5.0 <4.0.0
- Linting: `package:lints/recommended.yaml`
- Tests use synthetic audio generation (silence, sine waves, injected defects) — no fixture files needed
- Public API is exported through `lib/audio_defect_detector.dart`
- British spelling throughout (e.g. `analyser`, `normalise`)
