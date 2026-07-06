/// Shared helper for locating the package root directory.
///
/// `dart test` runs test suites concurrently inside a single process, so
/// tests must not depend on the process-wide `Directory.current` (another
/// suite may temporarily point it elsewhere). Resolving through the package
/// URI keeps paths stable regardless of the working directory.
library;

import 'dart:io';
import 'dart:isolate';

/// Absolute URI of the package root (the directory containing pubspec.yaml).
Future<Uri> packageRootUri() async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:audio_defect_detector/audio_defect_detector.dart'),
  );
  if (libUri == null) {
    // Fallback for environments without a package config.
    return Directory.current.uri;
  }
  // libUri => <packageRoot>/lib/audio_defect_detector.dart
  return libUri.resolve('../');
}
