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
