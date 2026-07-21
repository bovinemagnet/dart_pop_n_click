/// Audio defect detector — public library entry point.
///
/// Detects pops, clicks, clipping, dropouts, and DC offset in WAV, AIFF
/// and FLAC audio files.
///
/// Example:
/// ```dart
/// import 'package:audio_defect_detector/audio_defect_detector.dart';
///
/// void main() async {
///   final result = await analyseFile('recording.wav');
///   print('Found ${result.defects.length} defects');
///   for (final d in result.defects) {
///     print('${d.offset} – ${d.type.name} (confidence: ${d.confidence})');
///   }
/// }
/// ```
library;

export 'src/aiff_decoder.dart';
export 'src/analyser.dart';
export 'src/flac_decoder.dart';
export 'src/math_utils.dart' show median, mad;
export 'src/models.dart';
export 'src/pcm_decoder.dart';
export 'src/version.dart';
export 'src/wav_decoder.dart';
