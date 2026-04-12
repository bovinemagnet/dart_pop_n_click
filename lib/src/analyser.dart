/// Top-level asynchronous API for analysing audio files.
library;

import 'dart:io';
import 'dart:typed_data';
import 'models.dart';
import 'wav_decoder.dart';
import 'pcm_decoder.dart';
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

  // Guard against excessively large files (>2 GB).
  if (bytes.length > 2 * 1024 * 1024 * 1024) {
    throw UnsupportedFormatException('File too large (max 2 GB).');
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

/// Analyse raw PCM [bytes] described by [format] and return an [AnalysisResult].
///
/// This is useful when the caller has headerless PCM data (e.g. from a
/// microphone stream or a raw `.pcm` / `.raw` file) and knows the sample
/// format up-front.
///
/// Throws [CorruptFileException] if byte length is mis-aligned.
Future<AnalysisResult> analysePcm(
  Uint8List bytes, {
  required PcmFormat format,
  DetectorConfig config = const DetectorConfig(),
}) async {
  final channels = decodePcmBytes(bytes, format);
  return _analyseSamples(channels, format.sampleRate, format, config);
}

/// Analyse pre-normalised [channelSamples] (values in [-1.0, 1.0]).
///
/// The caller must provide a [sampleRate] so that defect offsets can be
/// expressed in wall-clock time.
Future<AnalysisResult> analyseSamples(
  List<Float32List> channelSamples, {
  required int sampleRate,
  int bitDepth = 16,
  DetectorConfig config = const DetectorConfig(),
}) async {
  final totalFrames =
      channelSamples.isEmpty ? 0 : channelSamples[0].length;
  final durationMs =
      sampleRate > 0 ? (totalFrames / sampleRate * 1000).round() : 0;
  final metadata = AudioMetadata(
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channelSamples.length,
    duration: Duration(milliseconds: durationMs),
  );

  final defects = detectDefects(channelSamples, sampleRate, config);
  final aggregate = computeAggregateConfidence(defects);
  return AnalysisResult(
    defects: defects,
    aggregateConfidence: aggregate,
    metadata: metadata,
  );
}

AnalysisResult _analyseSamples(
  List<Float32List> channels,
  int sampleRate,
  PcmFormat format,
  DetectorConfig config,
) {
  final totalFrames = channels.isEmpty ? 0 : channels[0].length;
  final durationMs =
      sampleRate > 0 ? (totalFrames / sampleRate * 1000).round() : 0;
  final metadata = AudioMetadata(
    sampleRate: sampleRate,
    bitDepth: format.bitDepth,
    channels: format.channels,
    duration: Duration(milliseconds: durationMs),
  );

  final defects = detectDefects(channels, sampleRate, config);
  final aggregate = computeAggregateConfidence(defects);
  return AnalysisResult(
    defects: defects,
    aggregateConfidence: aggregate,
    metadata: metadata,
  );
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
