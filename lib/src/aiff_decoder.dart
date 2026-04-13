/// Pure-Dart AIFF/AIFF-C parser and PCM sample reader.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'models.dart';
import 'pcm_decoder.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Decoded AIFF data: metadata and per-channel normalised samples.
typedef AiffData = ({AudioMetadata metadata, List<Float32List> samples});

/// Decode [bytes] as an AIFF or AIFF-C file and return normalised Float32 samples.
///
/// Supports standard AIFF (big-endian PCM) and AIFF-C with compression
/// types `NONE` (big-endian) and `sowt` (little-endian, used by macOS).
/// Throws [CorruptFileException] for malformed data and
/// [UnsupportedFormatException] for unsupported compression types.
AiffData decodeAiff(Uint8List bytes) {
  final reader = _ByteReader(bytes);

  // ---- FORM header ---------------------------------------------------------
  final formTag = reader.readFourCC();
  if (formTag != 'FORM') {
    throw CorruptFileException(
        'Expected FORM tag but found "$formTag". Is this an AIFF file?');
  }
  reader.skip(4); // form size (ignored – we use chunk sizes instead)
  final aiffTag = reader.readFourCC();
  final bool isAifC;
  if (aiffTag == 'AIFF') {
    isAifC = false;
  } else if (aiffTag == 'AIFC') {
    isAifC = true;
  } else {
    throw CorruptFileException(
        'Expected AIFF or AIFC tag but found "$aiffTag".');
  }

  // ---- Sub-chunks ----------------------------------------------------------
  int channels = 0;
  int bitDepth = 0;
  int sampleRate = 0;
  String? compressionType;
  Uint8List? ssndData;

  while (reader.remaining >= 8) {
    final chunkId = reader.readFourCC();
    final chunkSize = reader.readUint32Be();

    if (chunkSize > reader.remaining) {
      throw CorruptFileException(
        'Chunk claims $chunkSize bytes but only ${reader.remaining} remain.',
      );
    }

    switch (chunkId) {
      case 'COMM':
        if (chunkSize < 18) {
          throw CorruptFileException(
              'COMM chunk is too small ($chunkSize bytes).');
        }
        channels = reader.readInt16Be();
        reader.skip(4); // numFrames (derived from SSND data size instead)
        bitDepth = reader.readInt16Be();
        sampleRate = _readExtended(reader.readBytes(10)).round();
        // AIFF-C has additional compression type and name
        if (isAifC && chunkSize >= 22) {
          compressionType = reader.readFourCC();
          // Skip the rest (compression name pascal string, etc.)
          final consumed = 18 + 4; // 18 for standard COMM fields + 4 for type
          if (chunkSize > consumed) reader.skip(chunkSize - consumed);
        } else if (chunkSize > 18) {
          reader.skip(chunkSize - 18);
        }

      case 'SSND':
        if (chunkSize < 8) {
          throw CorruptFileException(
              'SSND chunk is too small ($chunkSize bytes).');
        }
        final dataOffset = reader.readUint32Be();
        reader.skip(4); // blockSize (usually 0)
        final audioBytes = chunkSize - 8;
        final raw = reader.readBytes(audioBytes);
        // If dataOffset is non-zero, skip that many leading bytes
        if (dataOffset > 0 && dataOffset < audioBytes) {
          ssndData = raw.sublist(dataOffset);
        } else {
          ssndData = raw;
        }

      default:
        // Unknown/padding chunk – skip
        reader.skip(chunkSize);
    }
    // IFF chunks are word-aligned (padded to even boundary)
    if (chunkSize.isOdd && reader.remaining > 0) reader.skip(1);
  }

  // ---- Validate ------------------------------------------------------------
  if (channels <= 0 || sampleRate <= 0 || bitDepth <= 0) {
    throw CorruptFileException('AIFF COMM chunk not found or incomplete.');
  }
  if (ssndData == null) {
    throw CorruptFileException('AIFF SSND chunk not found.');
  }
  if (bitDepth != 8 && bitDepth != 16 && bitDepth != 24 && bitDepth != 32) {
    throw UnsupportedFormatException('Unsupported AIFF bit depth: $bitDepth.');
  }

  // ---- Determine endianness ------------------------------------------------
  Endian endian;
  if (!isAifC || compressionType == null || compressionType == 'NONE') {
    endian = Endian.big;
  } else if (compressionType == 'sowt') {
    endian = Endian.little;
  } else {
    throw UnsupportedFormatException(
        'Unsupported AIFF-C compression type: "$compressionType". '
        'Only NONE and sowt are supported.');
  }

  // ---- Decode samples ------------------------------------------------------
  final pcmFormat = PcmFormat(
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channels,
    endian: endian,
    signed8bit: true, // AIFF 8-bit is always signed
  );
  final channelSamples = decodePcmBytes(ssndData, pcmFormat);

  final totalFrames = channelSamples.isEmpty ? 0 : channelSamples[0].length;
  final durationMs = (totalFrames / sampleRate * 1000).round();

  final metadata = AudioMetadata(
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channels,
    duration: Duration(milliseconds: durationMs),
  );

  return (metadata: metadata, samples: channelSamples);
}

// ---------------------------------------------------------------------------
// 80-bit IEEE 754 extended precision float
// ---------------------------------------------------------------------------

/// Convert an 80-bit IEEE 754 extended precision float to a Dart double.
///
/// The 80-bit extended format has a 15-bit exponent (bias 16383) and a
/// 64-bit mantissa with an explicit integer bit at position 63.
double _readExtended(Uint8List data) {
  final exponent = ((data[0] & 0x7F) << 8) | data[1];
  final sign = (data[0] >> 7) & 1;

  // Read the 64-bit mantissa as two unsigned 32-bit halves to avoid
  // signed overflow in Dart's 64-bit integers.
  final hi = ((data[2] & 0xFF) << 24) |
      ((data[3] & 0xFF) << 16) |
      ((data[4] & 0xFF) << 8) |
      (data[5] & 0xFF);
  final lo = ((data[6] & 0xFF) << 24) |
      ((data[7] & 0xFF) << 16) |
      ((data[8] & 0xFF) << 8) |
      (data[9] & 0xFF);

  if (exponent == 0 && hi == 0 && lo == 0) return 0.0;

  // Reconstruct as a double: hi * 2^32 + lo, then divide by 2^63.
  // This avoids signed 64-bit integer issues entirely.
  final mantissaDouble = (hi & 0xFFFFFFFF).toDouble() * 4294967296.0 +
      (lo & 0xFFFFFFFF).toDouble();
  // 2^63 as a double literal
  const twoTo63 = 9223372036854775808.0;
  final f = mantissaDouble / twoTo63 * math.pow(2, exponent - 16383);
  return sign == 1 ? -f : f;
}

// ---------------------------------------------------------------------------
// Minimal byte reader helper (big-endian by default)
// ---------------------------------------------------------------------------

class _ByteReader {
  final Uint8List _buf;
  int _pos = 0;

  _ByteReader(this._buf);

  int get remaining => _buf.length - _pos;

  String readFourCC() {
    _check(4);
    final s = String.fromCharCodes(_buf.sublist(_pos, _pos + 4));
    _pos += 4;
    return s;
  }

  int readInt16Be() {
    _check(2);
    final v = (_buf[_pos] << 8) | _buf[_pos + 1];
    _pos += 2;
    // Sign extend
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  int readUint32Be() {
    _check(4);
    final v = (_buf[_pos] << 24) |
        (_buf[_pos + 1] << 16) |
        (_buf[_pos + 2] << 8) |
        _buf[_pos + 3];
    _pos += 4;
    return v;
  }

  Uint8List readBytes(int n) {
    _check(n);
    final out = _buf.sublist(_pos, _pos + n);
    _pos += n;
    return out;
  }

  void skip(int n) {
    _pos += n;
    if (_pos > _buf.length) _pos = _buf.length;
  }

  void _check(int n) {
    if (_pos + n > _buf.length) {
      throw CorruptFileException(
          'Unexpected end of file while reading AIFF (offset $_pos, need $n bytes).');
    }
  }
}
