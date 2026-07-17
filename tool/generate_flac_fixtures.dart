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

import 'wav_writer.dart';

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
    buildWav(channels: [_sine(), _sine()], bitsPerSample: 16, sampleRate: sampleRate),
  );
  _writeFixture(
    'sine_click_16_stereo.flac',
    buildWav(
      channels: [_sineWithClick(), _sineWithClick()],
      bitsPerSample: 16,
      sampleRate: sampleRate,
    ),
  );
  _writeFixture(
    'sine_16_mono.flac',
    buildWav(channels: [_sine()], bitsPerSample: 16, sampleRate: sampleRate),
  );
  _writeFixture(
    'sine_24_stereo.flac',
    buildWav(channels: [_sine(), _sine()], bitsPerSample: 24, sampleRate: sampleRate),
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
