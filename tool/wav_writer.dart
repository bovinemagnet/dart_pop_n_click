/// Shared little-endian PCM WAV encoder used by the fixture generator and
/// the real-music harness.
library;

import 'dart:typed_data';

/// Builds a little-endian PCM WAV file from normalised per-channel samples.
///
/// [channels] holds one list per channel, values in [-1.0, 1.0]. All
/// channels must be the same length. [bitsPerSample] may be 16 or 24.
Uint8List buildWav({
  required List<List<double>> channels,
  required int bitsPerSample,
  required int sampleRate,
}) {
  final numChannels = channels.length;
  final numFrames = channels[0].length;
  final bytesPerSample = bitsPerSample ~/ 8;
  final blockAlign = numChannels * bytesPerSample;
  final dataSize = numFrames * blockAlign;
  final byteRate = sampleRate * blockAlign;

  final buf = Uint8List(44 + dataSize);
  final bd = ByteData.sublistView(buf);
  var p = 0;
  void fourCC(String s) {
    for (final c in s.codeUnits) {
      buf[p++] = c;
    }
  }

  void u32(int v) {
    bd.setUint32(p, v, Endian.little);
    p += 4;
  }

  void u16(int v) {
    bd.setUint16(p, v, Endian.little);
    p += 2;
  }

  fourCC('RIFF');
  u32(36 + dataSize);
  fourCC('WAVE');
  fourCC('fmt ');
  u32(16);
  u16(1); // PCM
  u16(numChannels);
  u32(sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  fourCC('data');
  u32(dataSize);

  final maxVal = (1 << (bitsPerSample - 1)) - 1;
  final minVal = -(1 << (bitsPerSample - 1));
  for (var f = 0; f < numFrames; f++) {
    for (var ch = 0; ch < numChannels; ch++) {
      var v = (channels[ch][f] * maxVal).round();
      if (v > maxVal) v = maxVal;
      if (v < minVal) v = minVal;
      if (bitsPerSample == 16) {
        bd.setInt16(p, v, Endian.little);
        p += 2;
      } else {
        final u = v & 0xFFFFFF;
        buf[p++] = u & 0xFF;
        buf[p++] = (u >> 8) & 0xFF;
        buf[p++] = (u >> 16) & 0xFF;
      }
    }
  }
  return buf;
}
