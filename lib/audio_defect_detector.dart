/// Audio defect detector — public library entry point.
///
/// Detects pops and clicks in WAV audio files.
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
library audio_defect_detector;

export 'src/analyser.dart';
export 'src/models.dart';
export 'src/pcm_decoder.dart';
