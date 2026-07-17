/// Real-music regression harness for the audio defect detector.
///
/// Scans a local FLAC corpus, reports defect statistics, extracts audio
/// snippets around the highest-confidence detections for listening, and
/// accumulates human real/false labels used to score precision on
/// subsequent runs.
///
/// All outputs are written under the git-ignored `tool/harness_results/`
/// directory. Design: docs/superpowers/specs/2026-07-17-real-music-harness-design.md
///
/// Usage:
///   dart run tool/real_music_harness.dart scan [--music-dir=`dir`] [options]
///   dart run tool/real_music_harness.dart merge-labels `exported-labels.json`
///   dart run tool/real_music_harness.dart compare `runA-dir` `runB-dir`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

import 'wav_writer.dart';

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

/// A human verdict on one detection: was it a real defect or musical
/// content misdetected?
class LabelEntry {
  /// Absolute path of the source audio file.
  final String file;

  /// Zero-based channel index of the detection.
  final int channel;

  /// Sample index of the detection peak within the file.
  final int sampleIndex;

  /// Defect type name at labelling time (e.g. 'click', 'pop').
  final String type;

  /// Either 'real' or 'false'.
  final String verdict;

  /// ISO-8601 date the label was recorded.
  final String labelledOn;

  const LabelEntry({
    required this.file,
    required this.channel,
    required this.sampleIndex,
    required this.type,
    required this.verdict,
    required this.labelledOn,
  });

  factory LabelEntry.fromJson(Map<String, dynamic> json) => LabelEntry(
        file: json['file'] as String,
        channel: json['channel'] as int,
        sampleIndex: json['sample_index'] as int,
        type: json['type'] as String,
        verdict: json['verdict'] as String,
        labelledOn: json['labelled_on'] as String,
      );

  Map<String, dynamic> toJson() => {
        'file': file,
        'channel': channel,
        'sample_index': sampleIndex,
        'type': type,
        'verdict': verdict,
        'labelled_on': labelledOn,
      };

  /// Identity of the labelled position (verdict excluded).
  String get positionKey => '$file|$channel|$sampleIndex';
}

/// Merges [incoming] labels into [existing]. Idempotent: an incoming label
/// at the same file/channel/sample position overwrites the existing verdict.
List<LabelEntry> mergeLabels(
    List<LabelEntry> existing, List<LabelEntry> incoming) {
  final byKey = {for (final l in existing) l.positionKey: l};
  for (final l in incoming) {
    byKey[l.positionKey] = l;
  }
  return byKey.values.toList()
    ..sort((a, b) => a.positionKey.compareTo(b.positionKey));
}

/// Returns the verdict of the label matching a detection at [sampleIndex]
/// on [channel] of [file], or null when no label lies within [toleranceMs]
/// of the detection.
String? matchVerdict(
  List<LabelEntry> labels, {
  required String file,
  required int channel,
  required int sampleIndex,
  required int sampleRate,
  double toleranceMs = 50,
}) {
  final toleranceSamples = (sampleRate * toleranceMs / 1000).round();
  for (final l in labels) {
    if (l.file == file &&
        l.channel == channel &&
        (l.sampleIndex - sampleIndex).abs() <= toleranceSamples) {
      return l.verdict;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Snippet selection and extraction
// ---------------------------------------------------------------------------

/// The [n] highest-confidence defects, ties broken by earlier offset.
List<Defect> topDefects(List<Defect> defects, int n) {
  final sorted = [...defects]..sort((a, b) {
      final c = b.confidence.compareTo(a.confidence);
      return c != 0 ? c : a.offset.compareTo(b.offset);
    });
  return sorted.take(n).toList();
}

/// Ten-bin histogram of defect confidences
/// (bin 0 = [0.0, 0.1) … bin 9 = [0.9, 1.0]).
List<int> confidenceHistogram(List<Defect> defects) {
  final bins = List<int>.filled(10, 0);
  for (final d in defects) {
    var bin = (d.confidence * 10).floor();
    if (bin > 9) bin = 9;
    if (bin < 0) bin = 0;
    bins[bin]++;
  }
  return bins;
}

/// A file-name-safe slug of an audio file path's base name (no extension).
String slugify(String audioPath) {
  var base = audioPath.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
}

/// Deterministic unique snippet file name for a defect within [audioPath].
String snippetName(String audioPath, Defect d) =>
    '${slugify(audioPath)}_${d.offset.inMilliseconds}ms_${d.type.name}'
    '_c${(d.confidence * 100).round()}_ch${d.channel}_s${d.sampleIndex}.wav';

/// Slices ±[halfWindowSeconds] of audio around [sampleIndex] from every
/// channel, clamped to the sample bounds.
List<List<double>> extractSnippet(
  List<Float32List> channels,
  int sampleIndex,
  int sampleRate, {
  double halfWindowSeconds = 1.0,
}) {
  final half = (sampleRate * halfWindowSeconds).round();
  final len = channels[0].length;
  var start = sampleIndex - half;
  var end = sampleIndex + half;
  if (start < 0) start = 0;
  if (end > len) end = len;
  return [for (final ch in channels) ch.sublist(start, end)];
}

// ---------------------------------------------------------------------------
// Run summaries
// ---------------------------------------------------------------------------

/// Builds the run.json entry for one scanned file. [verdicts] is parallel
/// to [result.defects]; entries are 'real', 'false', or null (unlabelled).
Map<String, dynamic> summariseFile({
  required String path,
  required AnalysisResult result,
  required List<String?> verdicts,
}) {
  final byType = <String, int>{};
  for (final d in result.defects) {
    byType[d.type.name] = (byType[d.type.name] ?? 0) + 1;
  }
  final seconds = result.metadata.duration.inMilliseconds / 1000;
  return {
    'path': path,
    'duration_ms': result.metadata.duration.inMilliseconds,
    'defect_count': result.defects.length,
    'defects_per_second': seconds > 0 ? result.defects.length / seconds : 0.0,
    'by_type': byType,
    'confidence_histogram': confidenceHistogram(result.defects),
    'labelled': {
      'real': verdicts.where((v) => v == 'real').length,
      'false': verdicts.where((v) => v == 'false').length,
    },
  };
}

/// Totals across per-file summaries, including precision over labelled
/// detections (null when nothing is labelled).
Map<String, dynamic> summariseTotals(List<Map<String, dynamic>> files) {
  var defects = 0, real = 0, falseCount = 0, durationMs = 0;
  for (final f in files) {
    defects += f['defect_count'] as int;
    durationMs += f['duration_ms'] as int;
    final l = f['labelled'] as Map;
    real += l['real'] as int;
    falseCount += l['false'] as int;
  }
  final labelled = real + falseCount;
  return {
    'file_count': files.length,
    'defect_count': defects,
    'duration_ms': durationMs,
    'defects_per_second': durationMs > 0 ? defects / (durationMs / 1000) : 0.0,
    'labelled_count': labelled,
    'precision': labelled > 0 ? real / labelled : null,
  };
}

// ---------------------------------------------------------------------------
// Labelling report page
// ---------------------------------------------------------------------------

/// Builds the static listening/labelling page. Each entry in
/// [snippetEntries] holds: snippet (relative wav path), file, channel,
/// sample_index, type, confidence, offset_ms.
String buildReportHtml(List<Map<String, dynamic>> snippetEntries) {
  final data = const JsonEncoder.withIndent('  ').convert(snippetEntries);
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Real-music harness — labelling</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #ccc; padding: 0.4rem 0.6rem; text-align: left; }
  tr.real { background: #e6ffe6; }
  tr.false { background: #ffe6e6; }
  button { margin-right: 0.3rem; }
  #export { margin-top: 1rem; padding: 0.5rem 1rem; }
</style>
</head>
<body>
<h1>Real-music harness — snippet labelling</h1>
<p>Listen to each snippet and mark it <strong>Real</strong> (a genuine
defect) or <strong>False</strong> (musical content misdetected). Then use
<em>Export labels</em> and merge the download with:
<code>dart run tool/real_music_harness.dart merge-labels &lt;download&gt;</code></p>
<table id="rows">
  <tr><th>Snippet</th><th>Track</th><th>Type</th><th>Conf</th>
      <th>Offset</th><th>Ch</th><th>Verdict</th></tr>
</table>
<button id="export">Export labels</button>
<script>
const entries = $data;
const verdicts = {};
const table = document.getElementById('rows');
entries.forEach((e, i) => {
  const tr = document.createElement('tr');
  tr.innerHTML =
    '<td><audio controls preload="none" src="' + e.snippet + '"></audio></td>' +
    '<td>' + e.file.split('/').pop() + '</td>' +
    '<td>' + e.type + '</td>' +
    '<td>' + e.confidence.toFixed(3) + '</td>' +
    '<td>' + e.offset_ms + ' ms</td>' +
    '<td>' + e.channel + '</td>' +
    '<td><button data-i="' + i + '" data-v="real">Real</button>' +
    '<button data-i="' + i + '" data-v="false">False</button></td>';
  table.appendChild(tr);
});
table.addEventListener('click', (ev) => {
  const b = ev.target.closest('button');
  if (!b) return;
  const i = Number(b.dataset.i);
  verdicts[i] = b.dataset.v;
  b.closest('tr').className = b.dataset.v;
});
document.getElementById('export').addEventListener('click', () => {
  const labels = Object.entries(verdicts).map(([i, v]) => {
    const e = entries[Number(i)];
    return { file: e.file, channel: e.channel, sample_index: e.sample_index,
             type: e.type, verdict: v,
             labelled_on: new Date().toISOString().slice(0, 10) };
  });
  const blob = new Blob([JSON.stringify(labels, null, 2)],
                        { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'labels-export.json';
  a.click();
});
</script>
</body>
</html>
''';
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

/// Root of all harness output (git-ignored).
const String resultsDir = 'tool/harness_results';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addCommand(
      'scan',
      ArgParser()
        ..addOption('music-dir',
            help: 'Root directory of the FLAC corpus.',
            defaultsTo: '/Volumes/mac_volume_1/music')
        ..addOption('sensitivity',
            allowed: ['low', 'medium', 'high'], defaultsTo: 'medium')
        ..addOption('min-confidence',
            help: 'Suppress detections below this confidence.',
            defaultsTo: '0.0')
        ..addOption('limit',
            help: 'Only scan the first N files (0 = all).', defaultsTo: '0')
        ..addOption('max-snippets',
            help: 'Snippet WAVs per file, top-N by confidence.',
            defaultsTo: '10'),
    )
    ..addCommand('merge-labels', ArgParser())
    ..addCommand('compare', ArgParser());

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }

  switch (args.command?.name) {
    case 'scan':
      await runScan(args.command!);
    case 'merge-labels':
      runMergeLabels(args.command!.rest);
    case 'compare':
      runCompare(args.command!.rest);
    default:
      stderr.writeln('Usage: dart run tool/real_music_harness.dart '
          '<scan|merge-labels|compare> [options]');
      exitCode = 64;
  }
}

/// Loads the accumulated ground-truth labels (empty when none exist yet).
List<LabelEntry> loadLabels() {
  final f = File('$resultsDir/labels.json');
  if (!f.existsSync()) return [];
  final decoded = jsonDecode(f.readAsStringSync()) as List<dynamic>;
  return [
    for (final e in decoded) LabelEntry.fromJson(e as Map<String, dynamic>)
  ];
}

/// Scans the corpus: analyse every FLAC, write run.json, snippets, and the
/// labelling report, then print a summary and delta against the previous
/// run with the same config.
Future<void> runScan(ArgResults args) async {
  final musicDir = args['music-dir'] as String;
  final sensitivity = Sensitivity.values.byName(args['sensitivity'] as String);
  final minConfidence = double.parse(args['min-confidence'] as String);
  final limit = int.parse(args['limit'] as String);
  final maxSnippets = int.parse(args['max-snippets'] as String);

  final dir = Directory(musicDir);
  if (!dir.existsSync()) {
    stderr.writeln('Music directory not found: $musicDir (volume mounted?)');
    exitCode = 66;
    return;
  }

  var files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.flac'))
      .map((f) => f.path)
      .toList()
    ..sort();
  if (limit > 0 && files.length > limit) files = files.sublist(0, limit);
  if (files.isEmpty) {
    stderr.writeln('No FLAC files found under $musicDir');
    exitCode = 66;
    return;
  }

  final config = DetectorConfig(
    sensitivity: sensitivity,
    minConfidence: minConfidence,
  );
  final configJson = {
    'sensitivity': sensitivity.name,
    'min_confidence': minConfidence,
  };

  final labels = loadLabels();

  final stamp =
      DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
  final runDir = Directory('$resultsDir/runs/$stamp');
  final snippetsDir = Directory('${runDir.path}/snippets')
    ..createSync(recursive: true);

  final fileSummaries = <Map<String, dynamic>>[];
  final snippetEntries = <Map<String, dynamic>>[];

  for (var i = 0; i < files.length; i++) {
    final path = files[i];
    stdout.write('${i + 1}/${files.length}  ${path.split('/').last} … ');

    final FlacData flac;
    try {
      flac = decodeFlac(File(path).readAsBytesSync());
    } catch (e) {
      stdout.writeln('SKIP ($e)');
      continue;
    }

    final result = analyseSamples(
      flac.samples,
      sampleRate: flac.metadata.sampleRate,
      bitDepth: flac.metadata.bitDepth,
      config: config,
    );

    final verdicts = [
      for (final d in result.defects)
        matchVerdict(labels,
            file: path,
            channel: d.channel,
            sampleIndex: d.sampleIndex,
            sampleRate: flac.metadata.sampleRate),
    ];
    fileSummaries
        .add(summariseFile(path: path, result: result, verdicts: verdicts));

    for (final d in topDefects(result.defects, maxSnippets)) {
      final name = snippetName(path, d);
      final slice =
          extractSnippet(flac.samples, d.sampleIndex, flac.metadata.sampleRate);
      File('${snippetsDir.path}/$name').writeAsBytesSync(buildWav(
        channels: slice,
        bitsPerSample: 16,
        sampleRate: flac.metadata.sampleRate,
      ));
      snippetEntries.add({
        'snippet': 'snippets/$name',
        'file': path,
        'channel': d.channel,
        'sample_index': d.sampleIndex,
        'type': d.type.name,
        'confidence': d.confidence,
        'offset_ms': d.offset.inMilliseconds,
      });
    }
    stdout.writeln('${result.defects.length} defects');
  }

  final run = {
    'schema_version': '1',
    'timestamp': stamp,
    'config': configJson,
    'files': fileSummaries,
    'totals': summariseTotals(fileSummaries),
  };
  File('${runDir.path}/run.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(run));
  File('${runDir.path}/report.html')
      .writeAsStringSync(buildReportHtml(snippetEntries));

  printSummary(run);
  printDeltaAgainstPrevious(run, runDir.path);
  stdout.writeln('\nRun written to ${runDir.path}');
  stdout.writeln('Open ${runDir.path}/report.html to label snippets.');
}

/// Prints the per-file table and totals for a completed run.
void printSummary(Map<String, dynamic> run) {
  final files = (run['files'] as List).cast<Map<String, dynamic>>();
  stdout.writeln('\n${'Defects'.padLeft(8)}  ${'Rate/s'.padLeft(7)}  Track');
  for (final f in files) {
    final rate = (f['defects_per_second'] as num).toStringAsFixed(2);
    stdout.writeln('${f['defect_count'].toString().padLeft(8)}  '
        '${rate.padLeft(7)}  ${(f['path'] as String).split('/').last}');
  }
  final t = run['totals'] as Map<String, dynamic>;
  stdout.writeln('Totals: ${t['defect_count']} defects across '
      '${t['file_count']} files '
      '(${(t['defects_per_second'] as num).toStringAsFixed(2)}/s).');
  final p = t['precision'];
  if (p != null) {
    stdout.writeln('Precision over ${t['labelled_count']} labelled '
        'detections: ${((p as num) * 100).toStringAsFixed(1)}%');
  } else {
    stdout.writeln('No labelled detections yet — open report.html to label.');
  }
}

/// Prints the total-defect delta against the most recent earlier run that
/// used the same detector config. Silent when no comparable run exists.
void printDeltaAgainstPrevious(Map<String, dynamic> run, String currentDir) {
  final runsRoot = Directory('$resultsDir/runs');
  if (!runsRoot.existsSync()) return;
  final dirs = runsRoot.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  Map<String, dynamic>? previous;
  for (final d in dirs) {
    if (d.path == currentDir) continue;
    final f = File('${d.path}/run.json');
    if (!f.existsSync()) continue;
    final candidate = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    if (jsonEncode(candidate['config']) == jsonEncode(run['config'])) {
      previous = candidate; // dirs sorted ascending → last match wins
    }
  }
  if (previous == null) return;
  final cur = run['totals'] as Map<String, dynamic>;
  final prev = previous['totals'] as Map<String, dynamic>;
  final delta = (cur['defect_count'] as int) - (prev['defect_count'] as int);
  stdout.writeln('Delta vs run ${previous['timestamp']} (same config): '
      '${delta >= 0 ? '+' : ''}$delta defects '
      '(${prev['defect_count']} → ${cur['defect_count']}).');
}

/// Implemented in the merge/compare task.
void runMergeLabels(List<String> rest) {
  stderr.writeln('merge-labels: not yet implemented');
  exitCode = 70;
}

/// Implemented in the merge/compare task.
void runCompare(List<String> rest) {
  stderr.writeln('compare: not yet implemented');
  exitCode = 70;
}
