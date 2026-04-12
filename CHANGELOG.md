## 0.1.0 (2026-04-12)

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
