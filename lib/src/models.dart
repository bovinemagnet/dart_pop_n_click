/// Data models, configuration, and typed exceptions for audio_defect_detector.
library;

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

/// The type of transient defect found in the audio.
enum DefectType {
  /// A very short transient spike (1–10 samples).
  click,

  /// A slightly wider transient burst (10–150 samples).
  pop,
}

/// Sensitivity preset controlling how aggressively the detector flags anomalies.
enum Sensitivity {
  low,
  medium,
  high,
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration passed to the analyser.
class DetectorConfig {
  /// How aggressively anomalies are flagged.
  final Sensitivity sensitivity;

  /// Detections with a confidence score below this value are suppressed.
  final double minConfidence;

  /// Maximum number of defects to return (0 = unlimited).
  final int maxDefects;

  /// When true the algorithm analyses each channel independently and annotates
  /// results with a channel index.  When false samples are summed to mono
  /// before analysis.
  final bool perChannel;

  const DetectorConfig({
    this.sensitivity = Sensitivity.medium,
    this.minConfidence = 0.0,
    this.maxDefects = 0,
    this.perChannel = false,
  });

  /// Returns the adaptive-threshold multiplier for the chosen sensitivity.
  ///
  /// A lower multiplier produces more detections (higher sensitivity).
  double get thresholdMultiplier => switch (sensitivity) {
        Sensitivity.low => 12.0,
        Sensitivity.medium => 8.0,
        Sensitivity.high => 5.0,
      };
}

// ---------------------------------------------------------------------------
// Audio metadata
// ---------------------------------------------------------------------------

/// Technical metadata about the decoded audio stream.
class AudioMetadata {
  final int sampleRate;
  final int bitDepth;
  final int channels;
  final Duration duration;

  const AudioMetadata({
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    required this.duration,
  });

  @override
  String toString() =>
      'AudioMetadata(sampleRate: $sampleRate, bitDepth: $bitDepth, '
      'channels: $channels, duration: $duration)';
}

// ---------------------------------------------------------------------------
// Defect
// ---------------------------------------------------------------------------

/// A single detected transient defect in the audio.
class Defect {
  /// Time offset from the start of the file.
  final Duration offset;

  /// Approximate duration of the defect.
  final Duration length;

  /// Whether this is a [DefectType.click] (short) or [DefectType.pop] (wider).
  final DefectType type;

  /// Confidence score in the range \[0.0, 1.0\].
  final double confidence;

  /// Zero-based channel index (0 = left/mono, 1 = right, …).
  final int channel;

  /// The sample index of the peak anomaly within the file.
  final int sampleIndex;

  /// Normalised peak amplitude (–1.0 to 1.0) of the anomaly.
  final double amplitude;

  const Defect({
    required this.offset,
    required this.length,
    required this.type,
    required this.confidence,
    required this.channel,
    required this.sampleIndex,
    required this.amplitude,
  });

  Map<String, dynamic> toJson() => {
        'offset_ms': offset.inMilliseconds,
        'length_ms': length.inMilliseconds,
        'type': type.name,
        'confidence': confidence,
        'channel': channel,
        'sample_index': sampleIndex,
        'amplitude': amplitude,
      };

  @override
  String toString() =>
      'Defect(offset: ${offset.inMilliseconds}ms, type: ${type.name}, '
      'confidence: ${confidence.toStringAsFixed(3)}, channel: $channel)';
}

// ---------------------------------------------------------------------------
// AnalysisResult
// ---------------------------------------------------------------------------

/// The result of analysing an audio file.
class AnalysisResult {
  /// All detected defects that passed the configured [DetectorConfig.minConfidence]
  /// threshold, sorted by [Defect.offset].
  final List<Defect> defects;

  /// Overall likelihood (0.0–1.0) that the file contains real defects,
  /// derived from the defect count and their individual confidence scores.
  final double aggregateConfidence;

  /// Technical metadata about the source audio.
  final AudioMetadata metadata;

  const AnalysisResult({
    required this.defects,
    required this.aggregateConfidence,
    required this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'schema_version': '1',
        'aggregate_confidence': aggregateConfidence,
        'defect_count': defects.length,
        'metadata': {
          'sample_rate': metadata.sampleRate,
          'bit_depth': metadata.bitDepth,
          'channels': metadata.channels,
          'duration_ms': metadata.duration.inMilliseconds,
        },
        'defects': defects.map((d) => d.toJson()).toList(),
      };
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown when the input file format is not supported (e.g. MP3).
class UnsupportedFormatException implements Exception {
  final String message;
  const UnsupportedFormatException(this.message);

  @override
  String toString() => 'UnsupportedFormatException: $message';
}

/// Thrown when the file header or data is malformed / truncated.
class CorruptFileException implements Exception {
  final String message;
  const CorruptFileException(this.message);

  @override
  String toString() => 'CorruptFileException: $message';
}

/// Thrown on I/O errors (file not found, permission denied, etc.).
class IoException implements Exception {
  final String message;
  final Object? cause;
  const IoException(this.message, [this.cause]);

  @override
  String toString() =>
      cause == null ? 'IoException: $message' : 'IoException: $message ($cause)';
}
