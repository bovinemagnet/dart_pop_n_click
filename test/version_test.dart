import 'dart:io';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

import 'package_root.dart';

void main() {
  test('packageVersion matches pubspec.yaml version field', () async {
    final root = await packageRootUri();
    final pubspec = File(root.resolve('pubspec.yaml').toFilePath());
    expect(pubspec.existsSync(), isTrue, reason: 'pubspec.yaml not found');
    final match = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    expect(match, isNotNull, reason: 'Could not find version in pubspec.yaml');
    expect(packageVersion, equals(match!.group(1)));
  });
}
