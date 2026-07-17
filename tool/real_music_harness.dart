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
