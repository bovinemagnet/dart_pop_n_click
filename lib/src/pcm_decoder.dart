/// Decoder for raw interleaved PCM byte data into normalised Float32 samples.
library;

import 'dart:typed_data';
import 'models.dart';

/// Decode raw interleaved PCM [bytes] into normalised Float32 samples per channel.
///
/// Returns one [Float32List] per channel, values in [-1.0, 1.0].
/// Throws [CorruptFileException] if byte length is not aligned to frame size.
List<Float32List> decodePcmBytes(Uint8List bytes, PcmFormat format) {
  final frameSize = format.bytesPerFrame;
  if (bytes.isEmpty) {
    return List.generate(format.channels, (_) => Float32List(0));
  }
  if (bytes.length % frameSize != 0) {
    throw CorruptFileException(
      'PCM data length (${bytes.length}) is not aligned to frame size ($frameSize).',
    );
  }

  final totalFrames = bytes.length ~/ frameSize;
  final out = List.generate(format.channels, (_) => Float32List(totalFrames));
  final byteData = ByteData.sublistView(bytes);

  if (format.isFloat) {
    _decodeFloat(byteData, out, format);
  } else {
    _decodeInteger(byteData, out, format);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Integer PCM decoder
// ---------------------------------------------------------------------------

void _decodeInteger(
  ByteData byteData,
  List<Float32List> out,
  PcmFormat format,
) {
  final channels = format.channels;
  final bytesPerSample = format.bytesPerSample;
  final totalFrames = out[0].length;
  final endian = format.endian;
  int byteOffset = 0;

  for (int frame = 0; frame < totalFrames; frame++) {
    for (int ch = 0; ch < channels; ch++) {
      final double normalised;
      switch (format.bitDepth) {
        case 8:
          // 8-bit PCM is unsigned
          final v = byteData.getUint8(byteOffset);
          normalised = (v - 128) / 128.0;
        case 16:
          final v = byteData.getInt16(byteOffset, endian);
          normalised = v / 32768.0;
        case 24:
          // 3-byte signed, respecting endian
          final int b0, b1, b2;
          if (endian == Endian.little) {
            b0 = byteData.getUint8(byteOffset);
            b1 = byteData.getUint8(byteOffset + 1);
            b2 = byteData.getUint8(byteOffset + 2);
          } else {
            b2 = byteData.getUint8(byteOffset);
            b1 = byteData.getUint8(byteOffset + 1);
            b0 = byteData.getUint8(byteOffset + 2);
          }
          int raw = b0 | (b1 << 8) | (b2 << 16);
          if (raw & 0x800000 != 0) raw = raw - 0x1000000; // sign extend
          normalised = raw / 8388608.0;
        case 32:
          final v = byteData.getInt32(byteOffset, endian);
          normalised = v / 2147483648.0;
        default:
          throw UnsupportedFormatException(
              'Unsupported PCM bit depth: ${format.bitDepth}');
      }
      out[ch][frame] = normalised.clamp(-1.0, 1.0);
      byteOffset += bytesPerSample;
    }
  }
}

// ---------------------------------------------------------------------------
// IEEE float decoder
// ---------------------------------------------------------------------------

void _decodeFloat(
  ByteData byteData,
  List<Float32List> out,
  PcmFormat format,
) {
  final channels = format.channels;
  final totalFrames = out[0].length;
  final endian = format.endian;
  int byteOffset = 0;

  for (int frame = 0; frame < totalFrames; frame++) {
    for (int ch = 0; ch < channels; ch++) {
      out[ch][frame] =
          byteData.getFloat32(byteOffset, endian).clamp(-1.0, 1.0);
      byteOffset += 4;
    }
  }
}
