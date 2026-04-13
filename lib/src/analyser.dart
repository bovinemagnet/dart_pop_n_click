/// Top-level API for analysing audio files.
library;

import 'dart:io';
import 'dart:typed_data';
import 'models.dart';
import 'aiff_decoder.dart';
import 'wav_decoder.dart';
import 'pcm_decoder.dart';
import 'detector.dart';

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Analyse the audio file at [path] and return an [AnalysisResult].
///
/// The format is auto-detected from the file extension (`.wav`, `.aiff`, `.aif`, `.aifc`) and validated
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
AnalysisResult analyseBytes(
  Uint8List bytes, {
  String? path,
  DetectorConfig config = const DetectorConfig(),
}) {
  final format = _detectFormat(bytes, path);

  switch (format) {
    case _AudioFormat.wav:
      return _analyseWav(bytes, config);
    case _AudioFormat.aiff:
      return _analyseAiff(bytes, config);
  }
}

/// Analyse raw PCM [bytes] described by [format] and return an [AnalysisResult].
///
/// This is useful when the caller has headerless PCM data (e.g. from a
/// microphone stream or a raw `.pcm` / `.raw` file) and knows the sample
/// format up-front.
///
/// Throws [CorruptFileException] if byte length is mis-aligned.
AnalysisResult analysePcm(
  Uint8List bytes, {
  required PcmFormat format,
  DetectorConfig config = const DetectorConfig(),
}) {
  final channels = decodePcmBytes(bytes, format);
  return _analyseSamples(channels, format.sampleRate, format, config);
}

/// Analyse pre-normalised [channelSamples] (values in \[-1.0, 1.0\]).
///
/// The caller must provide a [sampleRate] so that defect offsets can be
/// expressed in wall-clock time.
AnalysisResult analyseSamples(
  List<Float32List> channelSamples, {
  required int sampleRate,
  int bitDepth = 16,
  DetectorConfig config = const DetectorConfig(),
}) {
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

  return _buildResult(channelSamples, sampleRate, metadata, config);
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

  return _buildResult(channels, sampleRate, metadata, config);
}

/// Shared analysis pipeline: run the pop/click detector plus any additional
/// enabled detectors (clipping, dropouts, DC offset) and assemble the
/// combined [AnalysisResult].
AnalysisResult _buildResult(
  List<Float32List> channels,
  int sampleRate,
  AudioMetadata metadata,
  DetectorConfig config,
) {
  final List<Defect> allDefects = [
    ...detectDefects(channels, sampleRate, config),
  ];

  if (config.detectClipping) {
    allDefects.addAll(detectClipping(
      channels,
      sampleRate,
      threshold: config.clippingThreshold,
      minRun: config.clippingMinRun,
    ));
  }
  if (config.detectDropouts) {
    allDefects.addAll(detectDropouts(
      channels,
      sampleRate,
      silenceThreshold: config.dropoutSilenceThreshold,
      minMs: config.dropoutMinMs,
      maxMs: config.dropoutMaxMs,
    ));
  }

  allDefects.sort((a, b) => a.offset.compareTo(b.offset));

  List<double> dcOffsets = const [];
  if (config.detectDcOffset) {
    final raw = computeDcOffsets(channels);
    dcOffsets = raw
        .map((v) => v.abs() >= config.dcOffsetThreshold ? v : 0.0)
        .toList(growable: false);
  }

  final aggregate = computeAggregateConfidence(allDefects);
  return AnalysisResult(
    defects: allDefects,
    aggregateConfidence: aggregate,
    metadata: metadata,
    dcOffsetPerChannel: dcOffsets,
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

enum _AudioFormat { wav, aiff }

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

    // AIFF: "FORM" at 0-3, "AIFF" or "AIFC" at 8-11
    if (bytes[0] == 0x46 && bytes[1] == 0x4F && bytes[2] == 0x52 && bytes[3] == 0x4D) {
      if ((bytes[8] == 0x41 && bytes[9] == 0x49 && bytes[10] == 0x46 && bytes[11] == 0x46) ||
          (bytes[8] == 0x41 && bytes[9] == 0x49 && bytes[10] == 0x46 && bytes[11] == 0x43)) {
        return _AudioFormat.aiff;
      }
    }
  }

  // Fall back to file extension
  if (path != null) {
    final ext = path.toLowerCase().split('.').last;
    switch (ext) {
      case 'wav':
        return _AudioFormat.wav;
      case 'aiff' || 'aif' || 'aifc':
        return _AudioFormat.aiff;
    }
  }

  throw UnsupportedFormatException(
    'Cannot detect supported audio format from magic bytes or extension. '
    'Currently only WAV (PCM) and AIFF/AIFC are supported.',
  );
}

AnalysisResult _analyseAiff(Uint8List bytes, DetectorConfig config) {
  final aiffData = decodeAiff(bytes);
  return _buildResult(
    aiffData.samples,
    aiffData.metadata.sampleRate,
    aiffData.metadata,
    config,
  );
}

AnalysisResult _analyseWav(Uint8List bytes, DetectorConfig config) {
  final wavData = decodeWav(bytes);
  return _buildResult(
    wavData.samples,
    wavData.metadata.sampleRate,
    wavData.metadata,
    config,
  );
}
