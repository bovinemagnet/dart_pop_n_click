/// One-off generator for the FLAC test fixtures under `test/fixtures/flac/`.
///
/// Builds small synthetic WAV files in memory, encodes them to FLAC with the
/// `flac` command-line encoder, and writes the results into the fixtures
/// directory. The generated `.flac` files are committed to the repository, so
/// this script only needs to be re-run if the fixtures must be regenerated.
///
/// Requires the `flac` encoder on the `PATH`.
///
/// Usage: `dart run tool/generate_flac_fixtures.dart`
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate of every fixture (Hz). Deliberately low to keep files tiny.
const int sampleRate = 8000;

/// Number of inter-channel frames in every fixture (0.25 s at [sampleRate]).
const int frameCount = 2000;

/// Frequency of the synthetic sine tone (Hz).
const double toneFrequency = 440.0;

/// Amplitude of the background sine, low enough that an injected click stands
/// out clearly as a defect.
const double toneAmplitude = 0.3;

/// Sample index at which the click is injected in the click fixture.
const int clickPosition = 1000;

void main() {
  final outDir = Directory('test/fixtures/flac');
  outDir.createSync(recursive: true);

  _writeFixture(
    'sine_clean_16_stereo.flac',
    _buildWav(channels: [_sine(), _sine()], bitsPerSample: 16),
  );
  _writeFixture(
    'sine_click_16_stereo.flac',
    _buildWav(
      channels: [_sineWithClick(), _sineWithClick()],
      bitsPerSample: 16,
    ),
  );
  _writeFixture(
    'sine_16_mono.flac',
    _buildWav(channels: [_sine()], bitsPerSample: 16),
  );
  _writeFixture(
    'sine_24_stereo.flac',
    _buildWav(channels: [_sine(), _sine()], bitsPerSample: 24),
  );

  stdout.writeln('All fixtures generated.');
}

/// A clean sine tone, values normalised to [-1.0, 1.0].
Float64List _sine() {
  final buf = Float64List(frameCount);
  for (var i = 0; i < frameCount; i++) {
    buf[i] =
        toneAmplitude * math.sin(2 * math.pi * toneFrequency * i / sampleRate);
  }
  return buf;
}

/// A sine tone with a sharp two-sample click injected at [clickPosition].
Float64List _sineWithClick() {
  final buf = _sine();
  buf[clickPosition] = 0.9;
  buf[clickPosition + 1] = -0.9;
  return buf;
}

/// Builds a little-endian PCM WAV file from normalised per-channel samples.
Uint8List _buildWav({
  required List<Float64List> channels,
  required int bitsPerSample,
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

/// Encodes [wavBytes] to FLAC and writes it to `test/fixtures/flac/[name]`.
void _writeFixture(String name, Uint8List wavBytes) {
  final tmp = File('${Directory.systemTemp.path}/add_fixture_$name.wav');
  tmp.writeAsBytesSync(wavBytes);
  final outPath = 'test/fixtures/flac/$name';
  final result = Process.runSync('flac', [
    '--silent',
    '--force',
    '--no-padding',
    '--output-name=$outPath',
    tmp.path,
  ]);
  tmp.deleteSync();
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw Exception('flac encoding failed for $name (exit ${result.exitCode})');
  }
  stdout.writeln('Wrote $outPath (${File(outPath).lengthSync()} bytes)');
}
