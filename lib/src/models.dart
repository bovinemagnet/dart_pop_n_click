/// Data models, configuration, and typed exceptions for audio_defect_detector.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

/// The type of transient defect found in the audio.
enum DefectType {
  /// A very short transient spike (1–10 samples).
  click,

  /// A slightly wider transient burst (10–150 samples).
  pop,

  /// A run of consecutive samples saturated at or near full scale.
  clipping,

  /// A region of unexpected digital silence surrounded by audio content.
  dropout,
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

  /// Absolute sample magnitude considered clipping (default 0.99).
  final double clippingThreshold;

  /// Minimum consecutive clipped samples to flag as a defect (default 3).
  final int clippingMinRun;

  /// Absolute sample magnitude considered digital silence for dropout detection (default 1e-4).
  final double dropoutSilenceThreshold;

  /// Minimum dropout duration in milliseconds (default 1.0).
  final double dropoutMinMs;

  /// Maximum dropout duration in milliseconds; above this it is treated as intentional silence (default 50.0).
  final double dropoutMaxMs;

  /// Absolute mean value at which DC offset is reported (default 0.01).
  final double dcOffsetThreshold;

  /// Enable clipping detection (default true).
  final bool detectClipping;

  /// Enable dropout detection (default true).
  final bool detectDropouts;

  /// Enable DC offset detection (default true).
  final bool detectDcOffset;

  const DetectorConfig({
    this.sensitivity = Sensitivity.medium,
    this.minConfidence = 0.0,
    this.maxDefects = 0,
    this.perChannel = false,
    this.clippingThreshold = 0.99,
    this.clippingMinRun = 3,
    this.dropoutSilenceThreshold = 1e-4,
    this.dropoutMinMs = 1.0,
    this.dropoutMaxMs = 50.0,
    this.dcOffsetThreshold = 0.01,
    this.detectClipping = true,
    this.detectDropouts = true,
    this.detectDcOffset = true,
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
  /// Sample rate in Hertz (e.g. 44100, 48000).
  final int sampleRate;

  /// Sample bit depth (8, 16, 24, or 32).
  final int bitDepth;

  /// Number of audio channels (1 = mono, 2 = stereo, …).
  final int channels;

  /// Total playback duration of the audio.
  final Duration duration;

  /// Creates an [AudioMetadata] record.
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

  /// Creates a [Defect] record.
  const Defect({
    required this.offset,
    required this.length,
    required this.type,
    required this.confidence,
    required this.channel,
    required this.sampleIndex,
    required this.amplitude,
  });

  /// Serialise this defect to a JSON-compatible map.
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

  /// Per-channel DC offset (mean sample value). Values near zero indicate
  /// no DC bias; one entry per input channel. Empty if DC offset detection
  /// was disabled.
  final List<double> dcOffsetPerChannel;

  /// Creates an [AnalysisResult] record.
  const AnalysisResult({
    required this.defects,
    required this.aggregateConfidence,
    required this.metadata,
    this.dcOffsetPerChannel = const [],
  });

  /// Serialise the full analysis result (including all defects and
  /// metadata) to a JSON-compatible map with a schema version.
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
        'dc_offset_per_channel': dcOffsetPerChannel,
      };
}

// ---------------------------------------------------------------------------
// Raw PCM format descriptor
// ---------------------------------------------------------------------------

/// Describes the layout of raw PCM audio data.
class PcmFormat {
  /// Sample rate in Hertz (e.g. 44100, 48000).
  final int sampleRate;

  /// Sample bit depth (8, 16, 24, or 32).
  final int bitDepth;

  /// Number of interleaved channels (1 = mono, 2 = stereo, …).
  final int channels;

  /// True if samples are IEEE 754 floats (only valid for 32-bit).
  final bool isFloat;

  /// Byte order of multi-byte samples. Defaults to [Endian.little].
  final Endian endian;

  /// Whether 8-bit samples are signed (AIFF) or unsigned (WAV).
  /// Only relevant when bitDepth == 8. Defaults to false (unsigned).
  final bool signed8bit;

  /// Creates a [PcmFormat] descriptor.
  const PcmFormat({
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    this.isFloat = false,
    this.endian = Endian.little,
    this.signed8bit = false,
  });

  /// Bytes per single sample (one channel, one frame).
  int get bytesPerSample => bitDepth ~/ 8;

  /// Bytes per interleaved frame (all channels).
  int get bytesPerFrame => bytesPerSample * channels;
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
