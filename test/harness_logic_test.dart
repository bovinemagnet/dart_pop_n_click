import 'dart:typed_data';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import '../tool/real_music_harness.dart';

LabelEntry label(String file, int ch, int idx, String verdict) => LabelEntry(
      file: file,
      channel: ch,
      sampleIndex: idx,
      type: 'click',
      verdict: verdict,
      labelledOn: '2026-07-17',
    );

Defect defect({
  int ms = 0,
  double confidence = 0.5,
  int sampleIndex = 0,
  int channel = 0,
  DefectType type = DefectType.click,
}) =>
    Defect(
      offset: Duration(milliseconds: ms),
      length: const Duration(milliseconds: 1),
      type: type,
      confidence: confidence,
      channel: channel,
      sampleIndex: sampleIndex,
      amplitude: 0.5,
    );

void main() {
  group('LabelEntry JSON', () {
    test('round-trips through toJson/fromJson', () {
      final original = label('/music/a.flac', 1, 44100, 'real');
      final copy = LabelEntry.fromJson(original.toJson());
      expect(copy.file, original.file);
      expect(copy.channel, original.channel);
      expect(copy.sampleIndex, original.sampleIndex);
      expect(copy.type, original.type);
      expect(copy.verdict, original.verdict);
      expect(copy.labelledOn, original.labelledOn);
    });
  });

  group('mergeLabels', () {
    test('unions labels at different positions', () {
      final merged = mergeLabels(
        [label('/music/a.flac', 0, 100, 'real')],
        [label('/music/a.flac', 0, 200, 'false')],
      );
      expect(merged, hasLength(2));
    });

    test('incoming verdict overwrites existing at the same position', () {
      final merged = mergeLabels(
        [label('/music/a.flac', 0, 100, 'real')],
        [label('/music/a.flac', 0, 100, 'false')],
      );
      expect(merged, hasLength(1));
      expect(merged.single.verdict, 'false');
    });

    test('is idempotent', () {
      final incoming = [label('/music/a.flac', 0, 100, 'real')];
      final once = mergeLabels([], incoming);
      final twice = mergeLabels(once, incoming);
      expect(twice, hasLength(1));
    });
  });

  group('matchVerdict', () {
    final labels = [label('/music/a.flac', 0, 44100, 'false')];

    test('matches a detection within the tolerance window', () {
      // ±50ms at 44100 Hz = ±2205 samples.
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 0,
          sampleIndex: 44100 + 2000,
          sampleRate: 44100);
      expect(verdict, 'false');
    });

    test('does not match outside the tolerance window', () {
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 0,
          sampleIndex: 44100 + 3000,
          sampleRate: 44100);
      expect(verdict, isNull);
    });

    test('requires the same channel', () {
      final verdict = matchVerdict(labels,
          file: '/music/a.flac',
          channel: 1,
          sampleIndex: 44100,
          sampleRate: 44100);
      expect(verdict, isNull);
    });

    test('requires the same file', () {
      final verdict = matchVerdict(labels,
          file: '/music/b.flac',
          channel: 0,
          sampleIndex: 44100,
          sampleRate: 44100);
      expect(verdict, isNull);
    });
  });

  group('topDefects', () {
    test('returns the n highest-confidence defects, highest first', () {
      final defects = [
        defect(ms: 10, confidence: 0.3),
        defect(ms: 20, confidence: 0.9),
        defect(ms: 30, confidence: 0.6),
      ];
      final top = topDefects(defects, 2);
      expect(top.map((d) => d.confidence), [0.9, 0.6]);
    });

    test('breaks confidence ties by earlier offset', () {
      final defects = [
        defect(ms: 200, confidence: 0.5),
        defect(ms: 100, confidence: 0.5),
      ];
      final top = topDefects(defects, 2);
      expect(top.map((d) => d.offset.inMilliseconds), [100, 200]);
    });

    test('handles n larger than the list', () {
      expect(topDefects([defect()], 10), hasLength(1));
    });
  });

  group('confidenceHistogram', () {
    test('bins confidences into ten buckets', () {
      final bins = confidenceHistogram([
        defect(confidence: 0.05),
        defect(confidence: 0.15),
        defect(confidence: 0.95),
        defect(confidence: 1.0), // top edge belongs to bin 9
      ]);
      expect(bins[0], 1);
      expect(bins[1], 1);
      expect(bins[9], 2);
      expect(bins.reduce((a, b) => a + b), 4);
    });
  });

  group('slugify and snippetName', () {
    test('slugify strips directories, extension, and unsafe characters', () {
      expect(
        slugify("/music/Test Artist/03. Test Artist - Sample Track.flac"),
        '03._Test_Artist_-_Sample_Track',
      );
    });

    test('snippetName is deterministic and embeds position details', () {
      final d =
          defect(ms: 1234, confidence: 0.87, sampleIndex: 54432, channel: 1);
      expect(
        snippetName('/music/a track.flac', d),
        'a_track_1234ms_click_c87_ch1_s54432.wav',
      );
    });
  });

  group('extractSnippet', () {
    test('extracts a window of 2 × halfWindowSeconds around the index', () {
      final channels = [Float32List(48000), Float32List(48000)];
      final slice = extractSnippet(channels, 24000, 8000);
      expect(slice, hasLength(2));
      expect(slice[0].length, 16000); // ±1s at 8000 Hz
    });

    test('clamps at the start of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 1000, 8000);
      expect(slice[0].length, 9000); // 0..1000+8000
    });

    test('clamps at the end of the audio', () {
      final channels = [Float32List(48000)];
      final slice = extractSnippet(channels, 47000, 8000);
      expect(slice[0].length, 9000); // 47000-8000..48000
    });
  });
}
