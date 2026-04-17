import 'dart:io';

import 'package:audio_defect_detector/audio_defect_detector.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml version field', () {
    var dir = Directory.current;
    File? pubspec;
    while (true) {
      final f = File('${dir.path}/pubspec.yaml');
      if (f.existsSync()) {
        pubspec = f;
        break;
      }
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    expect(pubspec, isNotNull, reason: 'pubspec.yaml not found');
    final match = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec!.readAsStringSync());
    expect(match, isNotNull, reason: 'Could not find version in pubspec.yaml');
    expect(packageVersion, equals(match!.group(1)));
  });
}
