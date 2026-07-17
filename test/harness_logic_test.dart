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
}
