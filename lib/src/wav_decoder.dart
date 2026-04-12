/// Pure-Dart RIFF/WAV parser and PCM sample reader.
library;

import 'dart:typed_data';
import 'models.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Decode [bytes] as a WAV file and return normalised Float32 samples.
///
/// Returns a [WavData] record containing:
/// - [WavData.metadata] — technical header information.
/// - [WavData.samples]  — one `Float32List` per channel, values in \[-1.0, 1.0\].
WavData decodeWav(Uint8List bytes) {
  final reader = _ByteReader(bytes);

  // ---- RIFF header ----------------------------------------------------------
  final riffTag = reader.readFourCC();
  if (riffTag != 'RIFF') {
    throw CorruptFileException(
        'Expected RIFF tag but found "$riffTag". Is this a WAV file?');
  }
  reader.skip(4); // chunk size (ignored – we use the data chunk size instead)
  final waveTag = reader.readFourCC();
  if (waveTag != 'WAVE') {
    throw CorruptFileException(
        'Expected WAVE tag but found "$waveTag".');
  }

  // ---- Sub-chunks -----------------------------------------------------------
  int sampleRate = 0;
  int bitDepth = 0;
  int channels = 0;
  int audioFormat = 0;
  int blockAlign = 0;
  Uint8List? pcmData;

  while (reader.remaining >= 8) {
    final chunkId = reader.readFourCC();
    final chunkSize = reader.readUint32Le();

    if (chunkSize > reader.remaining) {
      throw CorruptFileException(
        'Chunk claims $chunkSize bytes but only ${reader.remaining} remain.',
      );
    }

    switch (chunkId) {
      case 'fmt ':
        if (chunkSize < 16) {
          throw CorruptFileException('fmt chunk is too small ($chunkSize bytes).');
        }
        audioFormat = reader.readUint16Le();
        channels = reader.readUint16Le();
        sampleRate = reader.readUint32Le();
        reader.skip(4); // byte rate
        blockAlign = reader.readUint16Le();
        bitDepth = reader.readUint16Le();
        // Skip any extension bytes
        if (chunkSize > 16) reader.skip(chunkSize - 16);

      case 'data':
        pcmData = reader.readBytes(chunkSize);

      default:
        // Unknown/padding chunk – skip
        reader.skip(chunkSize);
    }
    // Chunks are word-aligned
    if (chunkSize.isOdd && reader.remaining > 0) reader.skip(1);
  }

  // ---- Validate -------------------------------------------------------------
  if (sampleRate == 0 || bitDepth == 0 || channels == 0) {
    throw CorruptFileException('WAV fmt chunk not found or incomplete.');
  }
  if (pcmData == null) {
    throw CorruptFileException('WAV data chunk not found.');
  }
  // PCM (1) or IEEE float (3) are supported; compressed formats are not.
  if (audioFormat != 1 && audioFormat != 3) {
    throw UnsupportedFormatException(
        'Only PCM (format 1) and IEEE float (format 3) WAV files are '
        'supported. Found audio format $audioFormat.');
  }

  // ---- Decode samples -------------------------------------------------------
  if (pcmData.length % blockAlign != 0) {
    throw CorruptFileException(
      'PCM data length not aligned to block size.',
    );
  }
  final totalFrames = pcmData.length ~/ blockAlign;
  final List<Float32List> channelSamples =
      List.generate(channels, (_) => Float32List(totalFrames));

  if (audioFormat == 3 && bitDepth == 32) {
    _decodeFloat32(pcmData, channels, totalFrames, channelSamples);
  } else {
    _decodePcm(pcmData, channels, bitDepth, totalFrames, channelSamples);
  }

  final durationMs = (totalFrames / sampleRate * 1000).round();

  final metadata = AudioMetadata(
    sampleRate: sampleRate,
    bitDepth: bitDepth,
    channels: channels,
    duration: Duration(milliseconds: durationMs),
  );

  return WavData(metadata: metadata, samples: channelSamples);
}

// ---------------------------------------------------------------------------
// WavData record
// ---------------------------------------------------------------------------

class WavData {
  final AudioMetadata metadata;

  /// One [Float32List] per channel.  Values are in the range \[-1.0, 1.0\].
  final List<Float32List> samples;

  const WavData({required this.metadata, required this.samples});
}

// ---------------------------------------------------------------------------
// PCM decoders
// ---------------------------------------------------------------------------

void _decodePcm(
  Uint8List data,
  int channels,
  int bitDepth,
  int totalFrames,
  List<Float32List> out,
) {
  final bytesPerSample = bitDepth ~/ 8;
  final byteData = ByteData.sublistView(data);
  int byteOffset = 0;

  for (int frame = 0; frame < totalFrames; frame++) {
    for (int ch = 0; ch < channels; ch++) {
      final double normalized;
      switch (bitDepth) {
        case 8:
          // 8-bit PCM is unsigned
          final v = byteData.getUint8(byteOffset);
          normalized = (v - 128) / 128.0;
        case 16:
          final v = byteData.getInt16(byteOffset, Endian.little);
          normalized = v / 32768.0;
        case 24:
          // 3-byte little-endian signed
          final b0 = byteData.getUint8(byteOffset);
          final b1 = byteData.getUint8(byteOffset + 1);
          final b2 = byteData.getUint8(byteOffset + 2);
          int raw = b0 | (b1 << 8) | (b2 << 16);
          if (raw & 0x800000 != 0) raw = raw - 0x1000000; // sign extend
          normalized = raw / 8388608.0;
        case 32:
          final v = byteData.getInt32(byteOffset, Endian.little);
          normalized = v / 2147483648.0;
        default:
          throw UnsupportedFormatException(
              'Unsupported PCM bit depth: $bitDepth');
      }
      out[ch][frame] = normalized.clamp(-1.0, 1.0);
      byteOffset += bytesPerSample;
    }
  }
}

void _decodeFloat32(
  Uint8List data,
  int channels,
  int totalFrames,
  List<Float32List> out,
) {
  final byteData = ByteData.sublistView(data);
  int byteOffset = 0;
  for (int frame = 0; frame < totalFrames; frame++) {
    for (int ch = 0; ch < channels; ch++) {
      out[ch][frame] =
          byteData.getFloat32(byteOffset, Endian.little).clamp(-1.0, 1.0);
      byteOffset += 4;
    }
  }
}

// ---------------------------------------------------------------------------
// Minimal byte reader helper
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

  int readUint16Le() {
    _check(2);
    final v = _buf[_pos] | (_buf[_pos + 1] << 8);
    _pos += 2;
    return v;
  }

  int readUint32Le() {
    _check(4);
    final v = _buf[_pos] |
        (_buf[_pos + 1] << 8) |
        (_buf[_pos + 2] << 16) |
        (_buf[_pos + 3] << 24);
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
          'Unexpected end of file while reading WAV (offset $_pos, need $n bytes).');
    }
  }
}
