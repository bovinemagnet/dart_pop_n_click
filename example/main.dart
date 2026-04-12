import 'package:audio_defect_detector/audio_defect_detector.dart';

Future<void> main() async {
  // Configure the detector with high sensitivity and per-channel analysis.
  const config = DetectorConfig(
    sensitivity: Sensitivity.high,
    minConfidence: 0.3,
    perChannel: true,
  );

  try {
    final result = await analyseFile('recording.wav', config: config);

    print('Audio: ${result.metadata}');
    print('Aggregate confidence: '
        '${result.aggregateConfidence.toStringAsFixed(3)}');
    print('Defects found: ${result.defects.length}\n');

    for (final defect in result.defects) {
      print('  ${defect.offset.inMilliseconds}ms  '
          '${defect.type.name.padRight(5)}  '
          'ch${defect.channel}  '
          'confidence=${defect.confidence.toStringAsFixed(3)}');
    }
  } on UnsupportedFormatException catch (e) {
    print('Format error: $e');
  } on IoException catch (e) {
    print('I/O error: $e');
  }
}
