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
