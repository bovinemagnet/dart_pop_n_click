/// Micro-benchmark for the MAD hot path and end-to-end analysis.
///
/// Synthetic mode (default) times the library `mad` against a frozen
/// sort-based reference and times full `detectDefects`, asserting the two
/// MAD paths agree:
///
///   dart run tool/bench_mad.dart
///
/// Real-music mode times end-to-end `analyseFile` over a local corpus
/// (never committed):
///
///   dart run tool/bench_mad.dart --music /Volumes/mac_volume_1/music
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:audio_defect_detector/src/detector.dart';

import '../test/reference_mad.dart';

Future<void> main(List<String> args) async {
  final musicIdx = args.indexOf('--music');
  if (musicIdx >= 0 && musicIdx + 1 < args.length) {
    await _benchMusic(args[musicIdx + 1]);
  } else {
    _benchSynthetic();
  }
}

void _benchSynthetic() {
  final rng = math.Random(2026);
  const windowSize = 441; // ~10 ms at 44.1 kHz
  const numWindows = 2000;
  final windows = List<Float32List>.generate(numWindows, (_) {
    final w = Float32List(windowSize);
    for (int i = 0; i < windowSize; i++) {
      w[i] = (rng.nextDouble() - 0.5) * 2.0;
    }
    return w;
  });

  for (final w in windows) {
    if (mad(w) != referenceMad(w)) {
      stderr.writeln('MISMATCH: mad != referenceMad');
      exitCode = 1;
      return;
    }
  }

  const reps = 200;
  final refMs = _time(() {
    for (final w in windows) {
      referenceMad(w);
    }
  }, reps);
  final fastMs = _time(() {
    for (final w in windows) {
      mad(w);
    }
  }, reps);
  final ops = numWindows * reps;
  stdout.writeln('MAD micro-benchmark ($windowSize-sample windows):');
  stdout.writeln('  reference : ${_nsPerOp(refMs, ops)} ns/op');
  stdout.writeln('  library   : ${_nsPerOp(fastMs, ops)} ns/op');
  stdout.writeln('  speedup   : ${(refMs / fastMs).toStringAsFixed(2)}x');

  final big = _noiseWithDefects(44100 * 30, rng);
  const dReps = 20;
  final dMs = _time(() {
    detectDefects(
        [big], 44100, const DetectorConfig(sensitivity: Sensitivity.high));
  }, dReps);
  stdout.writeln('detectDefects (30 s mono):');
  stdout.writeln('  ${(dMs / dReps).toStringAsFixed(2)} ms/call');
}

Float32List _noiseWithDefects(int n, math.Random rng) {
  final buf = Float32List(n);
  for (int i = 0; i < n; i++) {
    buf[i] = (rng.nextDouble() - 0.5) * 0.02;
  }
  for (int i = 0; i < n; i += 7000) {
    buf[i] = 0.9;
  }
  return buf;
}

/// Total wall-clock milliseconds for [reps] runs of [body] (after warmup).
double _time(void Function() body, int reps) {
  for (int i = 0; i < 3; i++) {
    body();
  }
  final sw = Stopwatch()..start();
  for (int i = 0; i < reps; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / 1000.0;
}

String _nsPerOp(double totalMs, int ops) =>
    (totalMs * 1e6 / ops).toStringAsFixed(1);

Future<void> _benchMusic(String dir) async {
  final root = Directory(dir);
  if (!root.existsSync()) {
    stderr.writeln('No such directory: $dir');
    exitCode = 2;
    return;
  }
  final files = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) =>
          f.path.toLowerCase().endsWith('.flac') ||
          f.path.toLowerCase().endsWith('.wav'))
      .toList();
  if (files.isEmpty) {
    stderr.writeln('No .flac/.wav files under $dir');
    exitCode = 2;
    return;
  }
  stdout.writeln('Analysing ${files.length} files from $dir ...');
  final sw = Stopwatch()..start();
  int analysed = 0;
  int totalDefects = 0;
  for (final f in files) {
    try {
      final r = await analyseFile(f.path,
          config: const DetectorConfig(sensitivity: Sensitivity.high));
      analysed++;
      totalDefects += r.defects.length;
    } catch (_) {
      // Skip unreadable/unsupported files.
    }
  }
  sw.stop();
  final secs = sw.elapsedMilliseconds / 1000.0;
  stdout.writeln('Analysed $analysed files in ${secs.toStringAsFixed(1)} s '
      '(${(analysed / secs).toStringAsFixed(1)} files/s, '
      '$totalDefects defects total)');
}
