## Unreleased

### Performance

- Windowed MAD detection now uses median-of-three quickselect instead of two full sorts, giving a measured 7.4× speedup on the MAD micro-benchmark (~76,400 → ~10,400 ns per call) with bit-identical detections
- Detector's windowed-MAD hot path reuses scratch buffers (no per-window allocation) and shares quickselect selection, yielding a further ~17.5% reduction in end-to-end `detectDefects` time
- Combined, `detectDefects` on a 30-second mono buffer dropped from ~1,709 ms per call to ~217 ms per call (~7.9×) on the synthetic benchmark
- `Float32x4` SIMD threshold scan variant was evaluated and not adopted — the scan is memory-bandwidth-bound and showed no measurable end-to-end gain
- No public API change

## 0.4.0 (2026-07-14)

- WAVE_FORMAT_EXTENSIBLE (0xFFFE) WAV support — PCM and IEEE float resolved via the SubFormat GUID; oversized fmt extensions (cbSize > 22) are now skipped correctly
- `decodeWav()` and `WavData` are now exported from the public library entry point, matching `decodeAiff()` and `decodeFlac()`
- **Fix:** `analyseSamples()` with an empty channel list returns a clean result instead of throwing `RangeError`
- **Fix:** `decodePcmBytes()` rejects a `PcmFormat` with zero channels or a bit depth below 8 with a descriptive `ArgumentError` instead of a bare division-by-zero error
- **Fix:** the CLI flushes stdout before exiting so large JSON output is not truncated
- **Fix:** A-law decode polarity was inverted (whole waveform flipped) in AIFF-C `alaw` files
- **Fix:** float WAV files with a sample size other than 32-bit are now rejected instead of silently mis-decoded
- **Fix:** `minConfidence` and `maxDefects` now apply to clipping and dropout defects, not just clicks and pops
- **Fix:** WAV bit depths other than 8/16/24/32 are rejected up front instead of crashing the PCM decoder
- **Fix:** malformed glob patterns (e.g. an unmatched `[`) no longer crash the CLI; a literal file with that name is still found
- **Fix:** the CLI `--format` override is now honoured instead of always auto-detecting
- **Fix:** I/O errors in CLI `--raw` mode exit cleanly with code 3 instead of an unhandled exception
- Windows glob patterns using `\` separators now match (converted for `package:glob`)
- Dropout detection honours `DetectorConfig.perChannel` — each channel is scanned independently and defects carry their channel index, catching dropouts masked by the mono sum
- New CLI options: `--per-channel`, `--max-defects`, `--no-clipping`, `--no-dropouts`, `--no-dc-offset`; verbose text output now includes per-channel DC offset
- Adaptive MAD threshold evaluated on an interpolated grid — large-file analysis is dramatically faster with an effectively unchanged threshold
- `analyseFile()` checks the file size before loading, so over-limit files fail fast without exhausting memory
- Dependencies: `dart_flac` ^0.0.6, `lints` ^6.1.0

## 0.3.0 (2026-05-17)

- FLAC support — native FLAC streams can now be analysed via `analyseFile()` / `analyseBytes()`, and decoded directly with the new `decodeFlac()` function returning `FlacData`
- New `flac_decoder.dart` module wraps the pure-Dart `dart_flac` package; FLAC remains a no-native-dependency format
- Format auto-detection now recognises the `fLaC` magic bytes and the `.flac` extension
- Ogg-encapsulated audio is now explicitly rejected with `UnsupportedFormatException`
- CLI `analyse` command and `--format` option accept `flac`

## 0.2.0 (2026-04-15)

- AIFF-C compression support extended: `fl32` (32-bit big-endian float), `ulaw` (ITU-T G.711 μ-law) and `alaw` (ITU-T G.711 A-law)
- CLI `analyse` command now accepts full glob syntax (`*`, `**`, `?`, `[abc]`, `{a,b}`) via the `glob` package
- New `packageVersion` constant exported from the library; CLI `--version` now derives from a single source

## 0.1.0 (2026-04-13)

- Clipping detection (`DefectType.clipping`) — flags runs of consecutive samples at ±1.0
- Dropout detection (`DefectType.dropout`) — flags unexpected digital silence mid-audio
- DC offset reporting — per-channel mean bias now included in `AnalysisResult.dcOffsetPerChannel`
- New `DetectorConfig` thresholds: `clippingThreshold`, `clippingMinRun`, `dropoutSilenceThreshold`, `dropoutMinMs`, `dropoutMaxMs`, `dcOffsetThreshold`, and `detectClipping`/`detectDropouts`/`detectDcOffset` toggles
- Closes #5, #6, #7

## 0.0.3 (2026-04-13)

- **Licence change:** relicensed from GPL-3.0 to Apache-2.0 (permissive, allows use in proprietary projects)

## 0.0.2 (2026-04-13)

- **Breaking:** `analyseBytes()`, `analysePcm()`, and `analyseSamples()` are now synchronous — they return `AnalysisResult` directly instead of `Future<AnalysisResult>`. Only `analyseFile()` remains async (file I/O).
- AIFF and AIFF-C format support (big-endian PCM and `sowt` little-endian variant)
- Signed 8-bit PCM support (used by AIFF)
- Auto-detection of AIFF files via magic bytes and `.aiff`/`.aif`/`.aifc` extensions
- Expanded test suite to 192 tests

## 0.0.1 (2026-04-12)

- Initial release
- WAV PCM (8/16/24/32-bit) and IEEE Float 32-bit support
- Pop and click detection with adaptive MAD threshold
- CLI tool `audiodefect` with text and JSON output
- Configurable sensitivity (low/medium/high)
- Per-channel or mono-summed analysis
- Raw PCM byte analysis via `analysePcm()` with `PcmFormat` descriptor
- Pre-normalised sample analysis via `analyseSamples()`
- Public `median()` and `mad()` statistical utilities
- `decodePcmBytes()` for manual PCM-to-float conversion
- CLI `--raw` mode with `--sample-rate`, `--bit-depth`, `--channels`, `--float` options
- Comprehensive test suite (153 tests)
- Security hardening: file size limits, WAV chunk validation, block alignment checks
- AIFF and AIFF-C format support (standard big-endian and `sowt` little-endian variant)
- Signed 8-bit PCM support (used by AIFF)
- Auto-detection of AIFF files via magic bytes and `.aiff`/`.aif`/`.aifc` extensions
