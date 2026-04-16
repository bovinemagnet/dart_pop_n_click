import 'dart:io';

import 'package:test/test.dart';

import '../bin/audiodefect.dart' as cli;

/// Strip leading `./` and normalise separators so assertions are platform-agnostic.
List<String> _norm(List<String> paths) => paths
    .map((p) => p.replaceAll(r'\', '/').replaceAll(RegExp(r'^\./'), ''))
    .toList();

void main() {
  late Directory tmp;
  late String prev;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audiodefect_glob_');
    prev = Directory.current.path;
    File('${tmp.path}/a.wav').writeAsStringSync('x');
    File('${tmp.path}/b.wav').writeAsStringSync('x');
    File('${tmp.path}/c.txt').writeAsStringSync('x');
    Directory('${tmp.path}/sub1').createSync();
    File('${tmp.path}/sub1/d.wav').writeAsStringSync('x');
    Directory('${tmp.path}/sub2').createSync();
    File('${tmp.path}/sub2/e.wav').writeAsStringSync('x');
    Directory.current = tmp.path;
  });

  tearDown(() async {
    Directory.current = prev;
    await tmp.delete(recursive: true);
  });

  test('literal existing file passes through', () async {
    final r = _norm(await cli.expandPaths(['a.wav']));
    expect(r, equals(['a.wav']));
  });

  test('single-star glob matches top-level', () async {
    final r = _norm(await cli.expandPaths(['*.wav']));
    expect(r, containsAll(['a.wav', 'b.wav']));
    expect(r.where((p) => p.endsWith('c.txt')), isEmpty);
    expect(r.where((p) => p.contains('sub1')), isEmpty);
  });

  test('recursive glob matches nested files', () async {
    final r = _norm(await cli.expandPaths(['**/*.wav']));
    expect(r, containsAll(['sub1/d.wav', 'sub2/e.wav']));
  });

  test('brace expansion', () async {
    final r = _norm(await cli.expandPaths(['{a,b}.wav']));
    expect(r..sort(), equals(['a.wav', 'b.wav']));
  });

  test('character class', () async {
    final r = _norm(await cli.expandPaths(['[ab].wav']));
    expect(r..sort(), equals(['a.wav', 'b.wav']));
  });

  test('non-matching pattern returns empty', () async {
    final r = await cli.expandPaths(['nope_*.xyz']);
    expect(r, isEmpty);
  });
}
