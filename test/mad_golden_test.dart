import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_defect_detector/src/detector.dart';
import 'package:audio_defect_detector/src/models.dart';
import 'package:test/test.dart';

import 'package_root.dart';

/// One deterministic synthetic detection scenario.
class GoldenCase {
  final String name;
  final int sampleRate;
  final List<Float32List> channels;
  final DetectorConfig config;
  const GoldenCase(this.name, this.sampleRate, this.channels, this.config);
}

List<GoldenCase> buildGoldenSignals() => [
      GoldenCase('silence_44100', 44100, [Float32List(44100)],
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('sine_48000', 48000, _stereoSine(48000, 1.0, 440.0, 0.5),
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('noise_clicks_44100', 44100, [_noiseWithDefects(44100)],
          const DetectorConfig(sensitivity: Sensitivity.high)),
      GoldenCase('sine_pops_96000', 96000, [_sineWithPops(96000)],
          const DetectorConfig(sensitivity: Sensitivity.medium)),
    ];

List<Float32List> _stereoSine(int rate, double secs, double freq, double amp) {
  final n = (rate * secs).round();
  final l = Float32List(n);
  final r = Float32List(n);
  for (int i = 0; i < n; i++) {
    final s = amp * math.sin(2 * math.pi * freq * i / rate);
    l[i] = s;
    r[i] = s;
  }
  return [l, r];
}

Float32List _noiseWithDefects(int rate) {
  final rng = math.Random(42);
  final buf = Float32List(rate);
  for (int i = 0; i < rate; i++) {
    buf[i] = (rng.nextDouble() - 0.5) * 0.02;
  }
  for (final pos in [5000, 12000, 20500, 31000, 40000]) {
    buf[pos] = 0.9;
  }
  for (int i = 25000; i < 25020; i++) {
    buf[i] = 0.6;
  }
  return buf;
}

Float32List _sineWithPops(int rate) {
  final rng = math.Random(7);
  final n = rate ~/ 2;
  final buf = Float32List(n);
  for (int i = 0; i < n; i++) {
    buf[i] = 0.4 * math.sin(2 * math.pi * 220.0 * i / rate);
  }
  for (final pos in [8000, 22000, 35000]) {
    final width = 12 + rng.nextInt(20);
    for (int i = pos; i < pos + width && i < n; i++) {
      buf[i] += 0.5;
    }
  }
  return buf;
}

String encodeGolden() {
  final list = buildGoldenSignals()
      .map((c) => {
            'name': c.name,
            'sample_rate': c.sampleRate,
            'defects': detectDefects(c.channels, c.sampleRate, c.config)
                .map((d) => d.toJson())
                .toList(),
          })
      .toList();
  return const JsonEncoder.withIndent('  ').convert(list);
}

void main() {
  test('detector output matches committed golden', () async {
    final root = await packageRootUri();
    final goldenFile =
        File(root.resolve('test/fixtures/mad_golden.json').toFilePath());
    final current = encodeGolden();
    final recording = Platform.environment['RECORD_GOLDEN'] == '1';
    if (recording || !goldenFile.existsSync()) {
      goldenFile.parent.createSync(recursive: true);
      goldenFile.writeAsStringSync('$current\n');
      fail('Golden (re)written to ${goldenFile.path}; commit it and re-run.');
    }
    expect(current, equals(goldenFile.readAsStringSync().trimRight()));
  });
}
