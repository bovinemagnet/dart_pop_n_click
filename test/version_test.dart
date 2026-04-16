import 'dart:io';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml version field', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'Could not find version in pubspec.yaml');
    expect(packageVersion, equals(match!.group(1)));
  });
}
