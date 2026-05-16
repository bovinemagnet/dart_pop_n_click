import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

import 'flac_fixtures.dart';

void main() {
  group('analyseFile – FLAC', () {
    test('detects an injected click in a FLAC file', () async {
      final result =
          await analyseFile(await flacFixturePath('sine_click_16_stereo.flac'));
      final clicks =
          result.defects.where((d) => d.type == DefectType.click).toList();
      expect(clicks, isNotEmpty);
      // The fixture injects the click at sample 1000.
      expect(clicks.any((d) => (d.sampleIndex - 1000).abs() < 50), isTrue);
    });

    test('reports a clean FLAC file as click/pop-free', () async {
      final result =
          await analyseFile(await flacFixturePath('sine_clean_16_stereo.flac'));
      final transients = result.defects
          .where((d) => d.type == DefectType.click || d.type == DefectType.pop);
      expect(transients, isEmpty);
    });

    test('populates metadata from STREAMINFO', () async {
      final result =
          await analyseFile(await flacFixturePath('sine_24_stereo.flac'));
      expect(result.metadata.sampleRate, 8000);
      expect(result.metadata.channels, 2);
      expect(result.metadata.bitDepth, 24);
    });
  });

  group('analyseBytes – FLAC format detection', () {
    test('detects FLAC from the "fLaC" magic bytes with no path', () async {
      final result =
          analyseBytes(await flacFixtureBytes('sine_click_16_stereo.flac'));
      expect(
          result.defects.where((d) => d.type == DefectType.click), isNotEmpty);
    });

    test('detects FLAC from the .flac extension', () async {
      final result = analyseBytes(
        await flacFixtureBytes('sine_clean_16_stereo.flac'),
        path: 'recordings/track.flac',
      );
      expect(result.metadata.channels, 2);
    });

    test('rejects Ogg-encapsulated audio', () {
      // A buffer beginning with the Ogg container signature "OggS".
      final ogg = Uint8List.fromList([
        0x4F, 0x67, 0x67, 0x53, // "OggS"
        ...List.filled(60, 0x00),
      ]);
      expect(
          () => analyseBytes(ogg), throwsA(isA<UnsupportedFormatException>()));
    });

    test('throws CorruptFileException for a .flac path that is not FLAC', () {
      final notFlac = Uint8List.fromList(List.filled(64, 0x42));
      expect(
        () => analyseBytes(notFlac, path: 'bad.flac'),
        throwsA(isA<CorruptFileException>()),
      );
    });
  });
}
