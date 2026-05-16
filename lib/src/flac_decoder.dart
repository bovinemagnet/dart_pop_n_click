/// Pure-Dart FLAC parser and PCM sample reader.
library;

import 'dart:typed_data';

import 'package:dart_flac/dart_flac.dart';

import 'models.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Decode [bytes] as a native FLAC stream and return normalised Float32 samples.
///
/// Decoding is delegated to `package:dart_flac`; this function adapts the
/// result to the same shape as `decodeWav`/`decodeAiff`.
///
/// Returns a [FlacData] record containing:
/// - [FlacData.metadata] — technical header information from the STREAMINFO block.
/// - [FlacData.samples]  — one `Float32List` per channel, values in \[-1.0, 1.0\].
///
/// Only native FLAC streams (those beginning with the `fLaC` marker, optionally
/// preceded by an ID3v2 tag) are supported. Ogg-encapsulated FLAC is not.
///
/// Throws [CorruptFileException] if the data is not a valid FLAC stream or is
/// malformed/truncated.
FlacData decodeFlac(Uint8List bytes) {
  final FlacReader reader;
  try {
    reader = FlacReader.fromBytes(bytes);
  } on FormatException catch (e) {
    throw CorruptFileException('Not a valid FLAC stream: ${e.message}');
  }

  final info = reader.streamInfo;

  final Int32List interleaved;
  try {
    interleaved = reader.decodeInterleavedSamples();
  } on FormatException catch (e) {
    throw CorruptFileException('Failed to decode FLAC audio: ${e.message}');
  } on RangeError catch (e) {
    throw CorruptFileException(
        'Failed to decode FLAC audio: truncated or malformed stream ($e).');
  }

  // ---- Decode samples -------------------------------------------------------
  final channels = info.channels;
  final bitDepth = info.bitsPerSample;
  final totalFrames = channels == 0 ? 0 : interleaved.length ~/ channels;

  // Normalise integer samples to \[-1.0, 1.0\]. A B-bit signed sample spans
  // [-2^(B-1), 2^(B-1) - 1], so dividing by 2^(B-1) maps it into the unit
  // range. dart_flac returns samples interleaved as [ch0, ch1, ch0, ch1, ...].
  final divisor = (1 << (bitDepth - 1)).toDouble();
  final channelSamples =
      List.generate(channels, (_) => Float32List(totalFrames));
  for (int frame = 0; frame < totalFrames; frame++) {
    final base = frame * channels;
    for (int ch = 0; ch < channels; ch++) {
      channelSamples[ch][frame] =
          (interleaved[base + ch] / divisor).clamp(-1.0, 1.0);
    }
  }

  final durationMs =
      info.sampleRate > 0 ? (totalFrames / info.sampleRate * 1000).round() : 0;

  final metadata = AudioMetadata(
    sampleRate: info.sampleRate,
    bitDepth: bitDepth,
    channels: channels,
    duration: Duration(milliseconds: durationMs),
  );

  return FlacData(metadata: metadata, samples: channelSamples);
}

// ---------------------------------------------------------------------------
// FlacData record
// ---------------------------------------------------------------------------

/// Result of decoding a FLAC file: metadata plus per-channel normalised samples.
class FlacData {
  /// Technical metadata extracted from the FLAC STREAMINFO block.
  final AudioMetadata metadata;

  /// One [Float32List] per channel.  Values are in the range \[-1.0, 1.0\].
  final List<Float32List> samples;

  /// Creates a [FlacData] record.
  const FlacData({required this.metadata, required this.samples});
}
