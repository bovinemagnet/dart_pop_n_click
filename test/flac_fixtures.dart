/// Shared helpers for locating the committed FLAC fixtures.
///
/// `dart test` runs test suites concurrently inside a single process, and some
/// suites (e.g. `cli_glob_test.dart`) mutate the process-wide
/// `Directory.current`. Resolving fixtures through the package URI rather than
/// a relative path keeps them findable regardless of the working directory.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Absolute path to the FLAC fixture [name] under `test/fixtures/flac/`.
Future<String> flacFixturePath(String name) async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:audio_defect_detector/audio_defect_detector.dart'),
  );
  if (libUri == null) {
    // Fallback for environments without a package config.
    return 'test/fixtures/flac/$name';
  }
  // libUri => <packageRoot>/lib/audio_defect_detector.dart
  return libUri.resolve('../test/fixtures/flac/$name').toFilePath();
}

/// Reads the bytes of the FLAC fixture [name].
Future<Uint8List> flacFixtureBytes(String name) async =>
    File(await flacFixturePath(name)).readAsBytes();
