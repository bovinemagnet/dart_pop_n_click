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
import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';

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
