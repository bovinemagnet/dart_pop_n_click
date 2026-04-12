# dart_pop_n_click

Pure Dart library to detect pops and clicks in WAV audio files.

## Features

- Detect clicks (1–10 samples) and pops (10–150 samples) in WAV audio
- Adaptive MAD-based threshold with configurable sensitivity
- Support for PCM 8/16/24/32-bit and IEEE Float 32-bit WAV files
- Raw PCM byte analysis without WAV headers
- Pre-normalised sample analysis for integration with other decoders
- Per-channel or mono-summed analysis
- Confidence scoring with logistic function
- CLI tool with text and JSON output, glob support, and batch processing
- Pure Dart — no native dependencies, works on all platforms

## Installation

```sh
dart pub add audio_defect_detector
```

## Package: `audio_defect_detector`

A pure-Dart, cross-platform library for detecting transient audio defects (pops and clicks) in WAV files, with a companion CLI tool.

---

## Library API

```dart
import 'package:audio_defect_detector/audio_defect_detector.dart';

void main() async {
  final result = await analyseFile(
    'recording.wav',
    config: DetectorConfig(
      sensitivity: Sensitivity.medium,
      minConfidence: 0.5,
    ),
  );

  print('Aggregate confidence: ${result.aggregateConfidence}');
  for (final d in result.defects) {
    print('${d.offset} – ${d.type.name} (confidence: ${d.confidence.toStringAsFixed(3)})');
  }
}
```

### `analyseFile(path, {config})`
Reads the file at `path` and returns a `Future<AnalysisResult>`.

### `analyseBytes(bytes, {path, config})`
Analyses a `Uint8List` of audio bytes and returns a `Future<AnalysisResult>`.

### `DetectorConfig`
| Field | Type | Default | Description |
|---|---|---|---|
| `sensitivity` | `Sensitivity` | `medium` | Controls threshold aggressiveness (`low`, `medium`, `high`). |
| `minConfidence` | `double` | `0.0` | Suppress results below this score. |
| `maxDefects` | `int` | `0` | Limit total results (0 = unlimited). |
| `perChannel` | `bool` | `false` | Analyse channels independently. |

### `AnalysisResult`
| Field | Description |
|---|---|
| `defects` | `List<Defect>` sorted by time offset. |
| `aggregateConfidence` | Overall file-level defect probability (0.0–1.0). |
| `metadata` | `AudioMetadata` (sample rate, bit depth, channels, duration). |

### `Defect`
| Field | Description |
|---|---|
| `offset` | `Duration` from the start of the file. |
| `length` | `Duration` of the defect span. |
| `type` | `DefectType.click` (1–10 samples) or `DefectType.pop` (10–150 samples). |
| `confidence` | Score 0.0–1.0 derived from peak-to-noise ratio via logistic function. |
| `channel` | Zero-based channel index. |
| `sampleIndex` | Sample index of the peak anomaly. |
| `amplitude` | Normalised peak amplitude (–1.0 to 1.0). |

### Exceptions
- `UnsupportedFormatException` — unsupported file format.
- `CorruptFileException` — malformed or truncated file.
- `IoException` — I/O error (file not found, permission denied).

---

## Raw PCM Analysis

For audio that has already been decoded to raw PCM bytes (e.g. from FLAC decoders):

```dart
import 'package:audio_defect_detector/audio_defect_detector.dart';

// Analyse raw 16-bit signed LE stereo PCM bytes
final result = await analysePcm(
  pcmBytes,
  format: PcmFormat(sampleRate: 44100, bitDepth: 16, channels: 2),
);
```

For pre-normalised Float32 samples:

```dart
// samples is List<Float32List> — one per channel, values in [-1.0, 1.0]
final result = await analyseSamples(
  samples,
  sampleRate: 44100,
);
```

---

## CLI: `audiodefect`

Activate globally:
```
dart pub global activate audio_defect_detector
```

### Usage

```
audiodefect analyse <file|glob> [options]
```

#### Options
| Flag | Description |
|---|---|
| `--sensitivity=low\|medium\|high` | Detection sensitivity (default: `medium`). |
| `--min-confidence=0.0–1.0` | Suppress results below this score. |
| `--threshold=0.0–1.0` | Exit code 1 when defects above this score are found. |
| `--output=text\|json` | Output format (default: `text`). |
| `--quiet` | Suppress all output. |
| `--verbose` | Show extra diagnostics. |
| `--raw` | Treat input as raw PCM (no WAV header). |
| `--sample-rate=N` | Sample rate for raw PCM (default: `44100`). |
| `--bit-depth=N` | Bit depth for raw PCM: 8, 16, 24, or 32 (default: `16`). |
| `--channels=N` | Number of channels for raw PCM (default: `2`). |
| `--float` | Treat raw PCM as IEEE float instead of integer. |

#### Exit codes
| Code | Meaning |
|---|---|
| `0` | Clean — no defects above threshold. |
| `1` | Defects found above threshold. |
| `2` | Usage error. |
| `3` | File / decode error. |

#### Example — text output
```
$ audiodefect analyse recording.wav

File : recording.wav
Audio: 2ch  44100 Hz  16-bit  0m03.000s
Score: aggregate confidence = 0.997

2 defect(s) found:

 Offset (ms)    Type    Conf  Channel   Amplitude
────────────────────────────────────────────────────────
        1000   click   1.000        0      0.9900
        2000     pop   1.000        0      0.9000
```

#### Example — JSON output
```
$ audiodefect analyse recording.wav --output=json
{
  "file": "recording.wav",
  "result": {
    "schema_version": "1",
    "aggregate_confidence": 0.997,
    "defect_count": 2,
    "metadata": { "sample_rate": 44100, "bit_depth": 16, "channels": 2, "duration_ms": 3000 },
    "defects": [...]
  }
}
```

#### Example — raw PCM analysis
```
$ audiodefect analyse recording.raw --raw --sample-rate=48000 --bit-depth=24 --channels=1
```

---

## Detection Algorithm

1. **High-pass differentiator**: `d[n] = x[n] - x[n-1]`. Accentuates transients.
2. **Adaptive MAD threshold**: Median Absolute Deviation over a sliding ≈10 ms window provides a local noise estimate. The threshold is `MAD × 1.4826 × thresholdMultiplier`.
3. **Region merging**: Adjacent flagged samples within a gap of 4 are merged into contiguous regions.
4. **Classification**: Regions 1–10 samples wide → `click`; 10–150 samples → `pop`; wider → discarded.
5. **Confidence score**: Logistic function applied to peak-to-noise ratio, yielding a calibrated 0.0–1.0 score.

---

## Supported Formats

| Phase | Format | Status |
|---|---|---|
| 1 | WAV PCM 8/16/24/32-bit, mono/stereo | ✅ Supported |
| 1 | WAV IEEE Float 32-bit | ✅ Supported |
| 2 | FLAC 16/24-bit, mono/stereo | 🔜 Planned |

---

## Running Tests

```
dart pub get
dart test
```

---

## Limitations

- Maximum file size: 2 GB (files are loaded entirely into memory)
- Only WAV format is currently supported (FLAC planned for future release)
- Glob support in CLI is limited to simple `prefix*suffix` patterns

