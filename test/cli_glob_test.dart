import 'dart:io';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import '../bin/audiodefect.dart' as cli;

void main() {
  late Directory tmp;

  /// Prefix a relative [pattern] with the temp directory so the test never
  /// depends on the process-wide `Directory.current` (mutating it races with
  /// other concurrently running test suites).
  String inTmp(String pattern) => '${tmp.path}/$pattern';

  /// Strip the temp-dir prefix and normalise separators so assertions are
  /// platform-agnostic.
  List<String> norm(List<String> paths) {
    final prefix = '${tmp.path.replaceAll(r'\', '/')}/';
    return paths
        .map((p) => p.replaceAll(r'\', '/'))
        .map((p) => p.startsWith(prefix) ? p.substring(prefix.length) : p)
        .toList();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audiodefect_glob_');
    File('${tmp.path}/a.wav').writeAsStringSync('x');
    File('${tmp.path}/b.wav').writeAsStringSync('x');
    File('${tmp.path}/c.txt').writeAsStringSync('x');
    Directory('${tmp.path}/sub1').createSync();
    File('${tmp.path}/sub1/d.wav').writeAsStringSync('x');
    Directory('${tmp.path}/sub2').createSync();
    File('${tmp.path}/sub2/e.wav').writeAsStringSync('x');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('literal existing file passes through', () async {
    final r = norm(await cli.expandPaths([inTmp('a.wav')]));
    expect(r, equals(['a.wav']));
  });

  test('single-star glob matches top-level', () async {
    final r = norm(await cli.expandPaths([inTmp('*.wav')]));
    expect(r, containsAll(['a.wav', 'b.wav']));
    expect(r.where((p) => p.endsWith('c.txt')), isEmpty);
    expect(r.where((p) => p.contains('sub1')), isEmpty);
  });

  test('recursive glob matches nested files', () async {
    final r = norm(await cli.expandPaths([inTmp('**/*.wav')]));
    expect(r, containsAll(['sub1/d.wav', 'sub2/e.wav']));
  });

  test('brace expansion', () async {
    final r = norm(await cli.expandPaths([inTmp('{a,b}.wav')]));
    expect(r..sort(), equals(['a.wav', 'b.wav']));
  });

  test('character class', () async {
    final r = norm(await cli.expandPaths([inTmp('[ab].wav')]));
    expect(r..sort(), equals(['a.wav', 'b.wav']));
  });

  test('non-matching pattern returns empty', () async {
    final r = await cli.expandPaths([inTmp('nope_*.xyz')]);
    expect(r, isEmpty);
  });

  group('readRawBytes', () {
    test('reads an existing file', () async {
      final bytes = await cli.readRawBytes(inTmp('a.wav'));
      expect(bytes, isNotEmpty);
    });

    test('translates a filesystem error into IoException', () {
      // Reading a directory as bytes fails with a FileSystemException; the
      // CLI must surface it as the library IoException (caught -> exit 3),
      // not crash with an unhandled exception.
      expect(
        () => cli.readRawBytes(inTmp('sub1')),
        throwsA(isA<IoException>()),
      );
    });
  });

  test('malformed glob pattern returns empty instead of throwing', () async {
    // Unmatched '[' is invalid glob syntax; package:glob throws a
    // FormatException. The CLI must treat it as "no match", not crash.
    final r = await cli.expandPaths([inTmp('track[1.wav')]);
    expect(r, isEmpty);
  });

  test('malformed glob still yields a matching literal file', () async {
    // If a file literally named with the malformed pattern exists, the
    // literal fast-path should still find it.
    File('${tmp.path}/lit[.wav').writeAsStringSync('x');
    final r = norm(await cli.expandPaths([inTmp('lit[.wav')]));
    expect(r, equals(['lit[.wav']));
  });

  group('normaliseGlobPattern', () {
    test('converts backslashes to forward slashes on Windows', () {
      expect(
        cli.normaliseGlobPattern(r'recordings\*.wav', windows: true),
        equals('recordings/*.wav'),
      );
      expect(
        cli.normaliseGlobPattern(r'a\b\c\*.wav', windows: true),
        equals('a/b/c/*.wav'),
      );
    });

    test('leaves backslashes untouched on POSIX', () {
      expect(
        cli.normaliseGlobPattern(r'weird\*name.wav', windows: false),
        equals(r'weird\*name.wav'),
      );
    });
  });
}
