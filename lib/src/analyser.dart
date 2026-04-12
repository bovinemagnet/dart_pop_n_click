/// Top-level asynchronous API for analysing audio files.
library;

import 'dart:io';
import 'dart:typed_data';
import 'models.dart';
import 'wav_decoder.dart';
import 'detector.dart';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Analyse the audio file at [path] and return an [AnalysisResult].
///
/// The format is auto-detected from the file extension (`.wav`) and validated
/// against the file's magic bytes.  A [config] can be passed to tune
/// sensitivity and filtering.
///
/// Throws:
/// - [IoException] if the file cannot be read.
/// - [UnsupportedFormatException] if the file format is not supported.
/// - [CorruptFileException] if the file is malformed or truncated.
Future<AnalysisResult> analyseFile(
  String path, {
  DetectorConfig config = const DetectorConfig(),
}) async {
  final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (e) {
    throw IoException('Cannot read file "$path"', e);
  }
  return analyseBytes(bytes, path: path, config: config);
}

/// Analyse raw audio [bytes] and return an [AnalysisResult].
///
/// [path] is optional and used only for format detection by extension.
/// If [path] is omitted the bytes themselves are inspected (magic bytes).
///
/// Throws:
/// - [UnsupportedFormatException] if the format is not supported.
/// - [CorruptFileException] if the data is malformed.
Future<AnalysisResult> analyseBytes(
  Uint8List bytes, {
  String? path,
  DetectorConfig config = const DetectorConfig(),
}) async {
  final format = _detectFormat(bytes, path);

  switch (format) {
    case _AudioFormat.wav:
      return _analyseWav(bytes, config);
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

enum _AudioFormat { wav }

_AudioFormat _detectFormat(Uint8List bytes, String? path) {
  // Magic bytes check takes priority
  if (bytes.length >= 12) {
    final isRiff = bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46; // F
    final isWave = bytes[8] == 0x57 && // W
        bytes[9] == 0x41 && // A
        bytes[10] == 0x56 && // V
        bytes[11] == 0x45; // E
    if (isRiff && isWave) return _AudioFormat.wav;
  }

  // Fall back to file extension
  if (path != null) {
    final ext = path.toLowerCase().split('.').last;
    if (ext == 'wav') return _AudioFormat.wav;
  }

  throw UnsupportedFormatException(
    'Cannot detect supported audio format from magic bytes or extension. '
    'Currently only WAV (PCM) is supported.',
  );
}

AnalysisResult _analyseWav(Uint8List bytes, DetectorConfig config) {
  final wavData = decodeWav(bytes);
  final defects = detectDefects(
    wavData.samples,
    wavData.metadata.sampleRate,
    config,
  );
  final aggregate = computeAggregateConfidence(defects);
  return AnalysisResult(
    defects: defects,
    aggregateConfidence: aggregate,
    metadata: wavData.metadata,
  );
}
