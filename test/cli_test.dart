import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package_root.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Run the CLI and return the [ProcessResult] including stdout, stderr,
/// and exit code.
Future<ProcessResult> runCli(List<String> args) async {
  return Process.run(
    'dart',
    ['run', 'bin/audiodefect.dart', ...args],
    workingDirectory: (await packageRootUri()).toFilePath(),
  );
}

/// Create a temporary WAV file (16-bit PCM) containing interleaved [samples].
///
/// [channels] is the number of interleaved channels (default mono).
/// The caller is responsible for deleting the parent temp directory when done.
File createTestWav(List<int> samples,
    {int sampleRate = 44100, int channels = 1}) {
  final numSamples = samples.length;
  final dataSize = numSamples * 2; // 16-bit = 2 bytes per sample
  final fileSize = 44 + dataSize; // 44-byte header + data

  final bd = ByteData(fileSize);

  // RIFF header
  bd.setUint8(0, 0x52); // R
  bd.setUint8(1, 0x49); // I
  bd.setUint8(2, 0x46); // F
  bd.setUint8(3, 0x46); // F
  bd.setUint32(4, fileSize - 8, Endian.little);
  bd.setUint8(8, 0x57); // W
  bd.setUint8(9, 0x41); // A
  bd.setUint8(10, 0x56); // V
  bd.setUint8(11, 0x45); // E

  // fmt sub-chunk
  bd.setUint8(12, 0x66); // f
  bd.setUint8(13, 0x6D); // m
  bd.setUint8(14, 0x74); // t
  bd.setUint8(15, 0x20); // (space)
  bd.setUint32(16, 16, Endian.little); // sub-chunk size
  bd.setUint16(20, 1, Endian.little); // PCM format
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2 * channels, Endian.little); // byte rate
  bd.setUint16(32, 2 * channels, Endian.little); // block align
  bd.setUint16(34, 16, Endian.little); // bits per sample

  // data sub-chunk
  bd.setUint8(36, 0x64); // d
  bd.setUint8(37, 0x61); // a
  bd.setUint8(38, 0x74); // t
  bd.setUint8(39, 0x61); // a
  bd.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < numSamples; i++) {
    bd.setInt16(44 + i * 2, samples[i], Endian.little);
  }

  final tmpDir = Directory.systemTemp.createTempSync('cli_test_');
  final file = File('${tmpDir.path}/test.wav');
  file.writeAsBytesSync(bd.buffer.asUint8List());
  return file;
}

/// Create a temporary WAV file (16-bit stereo PCM) from per-channel samples.
File createTestWavStereo(
  List<int> left,
  List<int> right, {
  int sampleRate = 44100,
}) {
  final interleaved = List<int>.filled(left.length * 2, 0);
  for (var i = 0; i < left.length; i++) {
    interleaved[i * 2] = left[i];
    interleaved[i * 2 + 1] = right[i];
  }
  return createTestWav(interleaved, sampleRate: sampleRate, channels: 2);
}

/// Create a temporary AIFF file (16-bit mono PCM) containing [samples].
///
/// The caller is responsible for deleting the parent temp directory when done.
File createTestAiff(List<int> samples, {int sampleRate = 44100}) {
  final numSamples = samples.length;
  final dataSize = numSamples * 2; // 16-bit
  final ssndChunkSize = 8 + dataSize; // offset + blockSize + data
  final commChunkSize = 18; // standard AIFF COMM
  final formSize = 4 + (8 + commChunkSize) + (8 + ssndChunkSize);
  final totalSize = 12 + (8 + commChunkSize) + (8 + ssndChunkSize);

  final bd = ByteData(totalSize);
  var offset = 0;

  // FORM header
  for (final c in 'FORM'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, formSize, Endian.big);
  offset += 4;
  for (final c in 'AIFF'.codeUnits) {
    bd.setUint8(offset++, c);
  }

  // COMM chunk
  for (final c in 'COMM'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, commChunkSize, Endian.big);
  offset += 4;
  bd.setInt16(offset, 1, Endian.big);
  offset += 2; // channels
  bd.setUint32(offset, numSamples, Endian.big);
  offset += 4; // numFrames
  bd.setInt16(offset, 16, Endian.big);
  offset += 2; // bitDepth
  // 80-bit extended for 44100: exponent=0x400E, mantissa=0xAC44000000000000
  bd.setUint8(offset++, 0x40);
  bd.setUint8(offset++, 0x0E);
  bd.setUint8(offset++, 0xAC);
  bd.setUint8(offset++, 0x44);
  for (var i = 0; i < 6; i++) {
    bd.setUint8(offset++, 0);
  }

  // SSND chunk
  for (final c in 'SSND'.codeUnits) {
    bd.setUint8(offset++, c);
  }
  bd.setUint32(offset, ssndChunkSize, Endian.big);
  offset += 4;
  bd.setUint32(offset, 0, Endian.big);
  offset += 4; // data offset
  bd.setUint32(offset, 0, Endian.big);
  offset += 4; // blockSize
  for (var i = 0; i < numSamples; i++) {
    bd.setInt16(offset, samples[i], Endian.big);
    offset += 2;
  }

  final tmpDir = Directory.systemTemp.createTempSync('cli_aiff_test_');
  final file = File('${tmpDir.path}/test.aiff');
  file.writeAsBytesSync(bd.buffer.asUint8List());
  return file;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -----------------------------------------------------------------------
  // Basic options
  // -----------------------------------------------------------------------

  group('CLI – basic options', () {
    test('--version prints version and exits 0', () async {
      final result = await runCli(['--version']);
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString(), contains('audiodefect'));
    });

    test('--help prints usage and exits 0', () async {
      final result = await runCli(['--help']);
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString(), contains('Usage'));
    });

    test('no arguments prints usage and exits 2', () async {
      final result = await runCli([]);
      expect(result.exitCode, equals(2));
    });
  });

  // -----------------------------------------------------------------------
  // analyse command
  // -----------------------------------------------------------------------

  group('CLI – analyse command', () {
    test('clean (silent) WAV file with no defects exits 0', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path]);
        expect(result.exitCode, equals(0));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--format=wav is honoured on a clean WAV (exits 0)', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', '--format=wav', file.path]);
        expect(result.exitCode, equals(0));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--format overrides detection: forcing aiff on a WAV exits 3',
        () async {
      // Proves the flag is actually read: a real WAV forced to decode as
      // AIFF fails (exit 3), whereas auto-detection would exit 0.
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', '--format=aiff', file.path]);
        expect(result.exitCode, equals(3));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('WAV with a click exits 1 (default threshold 0.0)', () async {
      // A sharp spike in silence should be detected as a defect.
      // The default threshold is 0.0, so any defect triggers exit code 1.
      final samples = List.filled(44100, 0);
      samples[22050] = 32767;
      samples[22051] = -32768;
      final file = createTestWav(samples);
      try {
        final result = await runCli(['analyse', file.path]);
        expect(result.exitCode, equals(1));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('threshold controls exit code for defects', () async {
      // A full-scale spike should trigger exit code 1 with default threshold,
      // but setting threshold to 0.99 should still report exit code 1 since
      // the confidence of a full-scale spike is very high.
      final samples = List.filled(44100, 0);
      samples[22050] = 32767;
      samples[22051] = -32768;
      final file = createTestWav(samples);
      try {
        final lowThreshold =
            await runCli(['analyse', file.path, '--threshold=0.0']);
        final highThreshold =
            await runCli(['analyse', file.path, '--threshold=0.99']);
        // Both should find defects (the spike is extreme).
        expect(lowThreshold.exitCode, equals(1));
        expect(highThreshold.exitCode, equals(1));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('non-existent file exits 3', () async {
      final result = await runCli(['analyse', '/tmp/nonexistent_file_xyz.wav']);
      expect(result.exitCode, equals(3));
    });

    test('analyse without a file exits 2', () async {
      final result = await runCli(['analyse']);
      expect(result.exitCode, equals(2));
    });

    test('--quiet suppresses normal output on clean file', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--quiet']);
        expect(result.exitCode, equals(0));
        expect(result.stdout.toString().trim(), isEmpty);
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--quiet suppresses output even when defects found', () async {
      final samples = List.filled(44100, 0);
      samples[22050] = 32767;
      samples[22051] = -32768;
      final file = createTestWav(samples);
      try {
        final result = await runCli(['analyse', file.path, '--quiet']);
        // Exit code should still reflect defects, but stdout should be empty.
        expect(result.exitCode, equals(1));
        expect(result.stdout.toString().trim(), isEmpty);
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--output=json produces valid JSON with expected structure', () async {
      final samples = List.filled(44100, 0);
      samples[22050] = 32767;
      samples[22051] = -32768;
      final file = createTestWav(samples);
      try {
        final result = await runCli(['analyse', file.path, '--output=json']);
        // Parse stdout as JSON — should not throw.
        final json =
            jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
        expect(json, contains('file'));
        expect(json, contains('result'));
        final inner = json['result'] as Map<String, dynamic>;
        expect(inner, contains('schema_version'));
        expect(inner, contains('defect_count'));
        expect(inner, contains('defects'));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--output=json on clean file has zero defects', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--output=json']);
        expect(result.exitCode, equals(0));
        final json =
            jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
        final inner = json['result'] as Map<String, dynamic>;
        expect(inner['defect_count'], equals(0));
        expect((inner['defects'] as List), isEmpty);
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--sensitivity=low is accepted', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result =
            await runCli(['analyse', file.path, '--sensitivity=low']);
        expect(result.exitCode, equals(0));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--sensitivity=high is accepted', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result =
            await runCli(['analyse', file.path, '--sensitivity=high']);
        expect(result.exitCode, equals(0));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--verbose includes extra diagnostics', () async {
      final file = createTestWav(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--verbose']);
        expect(result.exitCode, equals(0));
        // Verbose writes diagnostics to stderr.
        expect(result.stderr.toString(), contains('Analysing'));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });
  });

  // -----------------------------------------------------------------------
  // Detector configuration options
  // -----------------------------------------------------------------------

  group('CLI – detector configuration options', () {
    /// Decode the JSON envelope of a single-file run.
    Map<String, dynamic> resultJson(ProcessResult result) =>
        (jsonDecode(result.stdout.toString()) as Map<String, dynamic>)['result']
            as Map<String, dynamic>;

    test('--max-defects caps the number of reported defects', () async {
      final samples = List.filled(44100, 0);
      // Two well-separated clicks.
      samples[10000] = 32767;
      samples[10001] = -32768;
      samples[30000] = 32767;
      samples[30001] = -32768;
      final file = createTestWav(samples);
      try {
        final all = await runCli(['analyse', file.path, '--output=json']);
        expect(resultJson(all)['defect_count'], greaterThan(1));

        final capped = await runCli(
            ['analyse', file.path, '--output=json', '--max-defects=1']);
        expect(resultJson(capped)['defect_count'], equals(1));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--per-channel attributes defects to their channel', () async {
      final n = 44100;
      final left = List.filled(n, 0);
      final right = List.filled(n, 0);
      right[22050] = 32767;
      right[22051] = -32768;
      final file = createTestWavStereo(left, right);
      try {
        final result = await runCli(
            ['analyse', file.path, '--output=json', '--per-channel']);
        final defects = resultJson(result)['defects'] as List;
        expect(defects, isNotEmpty);
        expect(defects.every((d) => d['channel'] == 1), isTrue);
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--no-clipping suppresses clipping defects', () async {
      final samples = List.filled(44100, 0);
      // A 50-sample full-scale run: unambiguous clipping.
      for (var i = 22050; i < 22100; i++) {
        samples[i] = 32767;
      }
      final file = createTestWav(samples);
      try {
        final all = await runCli(['analyse', file.path, '--output=json']);
        final allTypes =
            (resultJson(all)['defects'] as List).map((d) => d['type']).toSet();
        expect(allTypes, contains('clipping'));

        final suppressed = await runCli(
            ['analyse', file.path, '--output=json', '--no-clipping']);
        final types = (resultJson(suppressed)['defects'] as List)
            .map((d) => d['type'])
            .toSet();
        expect(types, isNot(contains('clipping')));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--no-dropouts suppresses dropout defects', () async {
      final samples = List<int>.generate(
        44100,
        (i) => (0.5 * 32767 * math.sin(2 * math.pi * 440 * i / 44100)).round(),
      );
      // ~10ms of silence mid-signal: a dropout.
      for (var i = 22000; i < 22441; i++) {
        samples[i] = 0;
      }
      final file = createTestWav(samples);
      try {
        final all = await runCli(['analyse', file.path, '--output=json']);
        final allTypes =
            (resultJson(all)['defects'] as List).map((d) => d['type']).toSet();
        expect(allTypes, contains('dropout'));

        final suppressed = await runCli(
            ['analyse', file.path, '--output=json', '--no-dropouts']);
        final types = (resultJson(suppressed)['defects'] as List)
            .map((d) => d['type'])
            .toSet();
        expect(types, isNot(contains('dropout')));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--no-dc-offset suppresses DC offset reporting', () async {
      // Constant +0.1 bias: no transients, just DC offset.
      final samples = List.filled(44100, 3277);
      final file = createTestWav(samples);
      try {
        final all = await runCli(['analyse', file.path, '--output=json']);
        final dc = resultJson(all)['dc_offset_per_channel'] as List;
        expect(dc, isNotEmpty);
        expect((dc.first as num).abs(), greaterThan(0.05));

        final suppressed = await runCli(
            ['analyse', file.path, '--output=json', '--no-dc-offset']);
        expect(
            resultJson(suppressed)['dc_offset_per_channel'] as List, isEmpty);
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--verbose text output includes DC offset', () async {
      // Constant +0.1 bias: reported DC offset should appear in verbose text.
      final samples = List.filled(44100, 3277);
      final file = createTestWav(samples);
      try {
        final result = await runCli(['analyse', file.path, '--verbose']);
        expect(result.stdout.toString(), contains('DC offset'));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('invalid --max-defects exits 2', () async {
      final file = createTestWav(List.filled(4410, 0));
      try {
        final result =
            await runCli(['analyse', file.path, '--max-defects=abc']);
        expect(result.exitCode, equals(2));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });
  });

  // -----------------------------------------------------------------------
  // Raw PCM mode
  // -----------------------------------------------------------------------

  group('CLI – raw PCM mode', () {
    test('--raw with valid PCM silence exits 0', () async {
      final tmpDir = Directory.systemTemp.createTempSync('cli_raw_test_');
      final file = File('${tmpDir.path}/test.raw');
      // 1 second of 16-bit mono silence (all zeros).
      file.writeAsBytesSync(Uint8List(44100 * 2));
      try {
        final result = await runCli([
          'analyse',
          file.path,
          '--raw',
          '--sample-rate=44100',
          '--bit-depth=16',
          '--channels=1',
        ]);
        expect(result.exitCode, equals(0));
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('--raw with spike in PCM exits 1', () async {
      final tmpDir = Directory.systemTemp.createTempSync('cli_raw_spike_');
      final numSamples = 44100;
      final bd = ByteData(numSamples * 2);
      // Inject a spike in the middle.
      bd.setInt16(22050 * 2, 32767, Endian.little);
      bd.setInt16(22051 * 2, -32768, Endian.little);

      final file = File('${tmpDir.path}/spike.raw');
      file.writeAsBytesSync(bd.buffer.asUint8List());
      try {
        final result = await runCli([
          'analyse',
          file.path,
          '--raw',
          '--sample-rate=44100',
          '--bit-depth=16',
          '--channels=1',
        ]);
        expect(result.exitCode, equals(1));
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('--raw without a file argument exits 2', () async {
      final result = await runCli([
        'analyse',
        '--raw',
        '--sample-rate=44100',
        '--bit-depth=16',
        '--channels=1',
      ]);
      expect(result.exitCode, equals(2));
    });
  });

  // -----------------------------------------------------------------------
  // AIFF files
  // -----------------------------------------------------------------------

  group('CLI – AIFF files', () {
    test('clean AIFF file exits 0', () async {
      final file = createTestAiff(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path]);
        expect(result.exitCode, equals(0));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('AIFF with click detected', () async {
      final samples = List.filled(44100, 0);
      samples[22050] = 32767;
      samples[22051] = -32768;
      final file = createTestAiff(samples);
      try {
        final result = await runCli(['analyse', file.path]);
        expect(result.stdout.toString(), contains('defect(s) found'));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--output=json works with AIFF', () async {
      final file = createTestAiff(List.filled(44100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--output=json']);
        expect(result.exitCode, equals(0));
        final json = jsonDecode(result.stdout.toString());
        expect(json, isA<Map>());
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });
  });

  // -----------------------------------------------------------------------
  // Invalid arguments
  // -----------------------------------------------------------------------

  group('CLI – invalid arguments', () {
    test('invalid --sensitivity value exits 2', () async {
      final file = createTestWav(List.filled(100, 0));
      try {
        final result =
            await runCli(['analyse', file.path, '--sensitivity=ultra']);
        expect(result.exitCode, equals(2));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('invalid --output value exits 2', () async {
      final file = createTestWav(List.filled(100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--output=xml']);
        expect(result.exitCode, equals(2));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--threshold out of range exits 2', () async {
      final file = createTestWav(List.filled(100, 0));
      try {
        final result = await runCli(['analyse', file.path, '--threshold=5.0']);
        expect(result.exitCode, equals(2));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });

    test('--min-confidence out of range exits 2', () async {
      final file = createTestWav(List.filled(100, 0));
      try {
        final result =
            await runCli(['analyse', file.path, '--min-confidence=-1.0']);
        expect(result.exitCode, equals(2));
      } finally {
        file.parent.deleteSync(recursive: true);
      }
    });
  });
}
