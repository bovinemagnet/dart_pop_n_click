#!/usr/bin/env dart
/// `audiodefect` — Command-line interface for the audio_defect_detector library.
///
/// Supported formats: WAV (.wav), AIFF (.aiff, .aif, .aifc).
///
/// Usage:
///   audiodefect analyse `<file|glob>` [options]
///
/// Exit codes:
///   0 — clean file (no defects above threshold)
///   1 — defects found above threshold
///   2 — usage error
///   3 — file / decode error
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:audio_defect_detector/audio_defect_detector.dart';

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

const _exitClean = 0;
const _exitDefectsFound = 1;
const _exitUsageError = 2;
const _exitFileError = 3;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addCommand(
      'analyse',
      ArgParser()
        ..addOption(
          'format',
          abbr: 'f',
          help: 'Override format detection (wav, aiff).',
          allowed: ['wav', 'aiff'],
        )
        ..addOption(
          'sensitivity',
          abbr: 's',
          help: 'Detection sensitivity.',
          allowed: ['low', 'medium', 'high'],
          defaultsTo: 'medium',
        )
        ..addOption(
          'min-confidence',
          help: 'Suppress results below this confidence (0.0–1.0).',
          defaultsTo: '0.0',
        )
        ..addOption(
          'threshold',
          abbr: 't',
          help: 'Exit with code 1 when defects above this confidence are found.',
          defaultsTo: '0.0',
        )
        ..addOption(
          'output',
          abbr: 'o',
          help: 'Output format.',
          allowed: ['text', 'json'],
          defaultsTo: 'text',
        )
        ..addFlag('quiet', abbr: 'q', help: 'Suppress all output.', negatable: false)
        ..addFlag('verbose', abbr: 'v', help: 'Show extra diagnostics.', negatable: false)
        ..addFlag('raw', help: 'Treat input as raw PCM (no header).', negatable: false)
        ..addOption(
          'sample-rate',
          help: 'Sample rate for raw PCM.',
          defaultsTo: '44100',
        )
        ..addOption(
          'bit-depth',
          help: 'Bit depth for raw PCM (8, 16, 24, 32).',
          defaultsTo: '16',
        )
        ..addOption(
          'channels',
          help: 'Number of channels for raw PCM.',
          defaultsTo: '2',
        )
        ..addFlag('float', help: 'Treat raw PCM as IEEE float instead of integer.', negatable: false),
    )
    ..addFlag('help', abbr: 'h', help: 'Show this help.', negatable: false)
    ..addFlag('version', help: 'Print the version and exit.', negatable: false);

  ArgResults? topLevel;
  try {
    topLevel = parser.parse(args);
  } catch (e) {
    _usage(parser, '$e');
    exit(_exitUsageError);
  }

  if (topLevel['version'] as bool) {
    // TODO: Keep in sync with version in pubspec.yaml.
    stdout.writeln('audiodefect 0.0.1');
    exit(_exitClean);
  }

  if (topLevel['help'] as bool || topLevel.command == null) {
    _usage(parser);
    exit(topLevel['help'] as bool ? _exitClean : _exitUsageError);
  }

  final cmd = topLevel.command!;

  switch (cmd.name) {
    case 'analyse':
      await _runAnalyse(cmd);
    default:
      _usage(parser, 'Unknown command: ${cmd.name}');
      exit(_exitUsageError);
  }
}

// ---------------------------------------------------------------------------
// `analyse` command
// ---------------------------------------------------------------------------

Future<void> _runAnalyse(ArgResults cmd) async {
  if (cmd.rest.isEmpty) {
    stderr.writeln('Error: no file specified.\n');
    stderr.writeln('Usage: audiodefect analyse <file> [options]');
    exit(_exitUsageError);
  }

  final quiet = cmd['quiet'] as bool;
  final verbose = cmd['verbose'] as bool;
  final outputFormat = cmd['output'] as String;
  final sensitivityStr = cmd['sensitivity'] as String;
  final minConfidence = _parseDouble(cmd['min-confidence'] as String, 'min-confidence');
  final threshold = _parseDouble(cmd['threshold'] as String, 'threshold');
  final isRaw = cmd['raw'] as bool;
  final isFloat = cmd['float'] as bool;

  // Build PcmFormat when --raw is specified.
  PcmFormat? pcmFormat;
  if (isRaw) {
    final sampleRate = int.tryParse(cmd['sample-rate'] as String);
    final bitDepth = int.tryParse(cmd['bit-depth'] as String);
    final channels = int.tryParse(cmd['channels'] as String);
    if (sampleRate == null || sampleRate <= 0) {
      stderr.writeln('Error: --sample-rate must be a positive integer.');
      exit(_exitUsageError);
    }
    if (bitDepth == null || ![8, 16, 24, 32].contains(bitDepth)) {
      stderr.writeln('Error: --bit-depth must be one of 8, 16, 24, 32.');
      exit(_exitUsageError);
    }
    if (channels == null || channels <= 0) {
      stderr.writeln('Error: --channels must be a positive integer.');
      exit(_exitUsageError);
    }
    pcmFormat = PcmFormat(
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      isFloat: isFloat,
    );
  }

  final sensitivity = switch (sensitivityStr) {
    'low' => Sensitivity.low,
    'high' => Sensitivity.high,
    _ => Sensitivity.medium,
  };

  final config = DetectorConfig(
    sensitivity: sensitivity,
    minConfidence: minConfidence,
  );

  // Expand globs
  final filePaths = await _expandPaths(cmd.rest);
  if (filePaths.isEmpty) {
    stderr.writeln('Error: no matching files found for: ${cmd.rest.join(', ')}');
    exit(_exitFileError);
  }

  // ---- Single file --------------------------------------------------------
  if (filePaths.length == 1) {
    final path = filePaths.first;
    AnalysisResult result;
    try {
      if (!quiet && verbose) stderr.writeln('Analysing $path …');
      if (isRaw) {
        final bytes = Uint8List.fromList(await File(path).readAsBytes());
        result = analysePcm(bytes, format: pcmFormat!, config: config);
      } else {
        result = await analyseFile(path, config: config);
      }
    } on IoException catch (e) {
      if (!quiet) stderr.writeln('Error: $e');
      exit(_exitFileError);
    } on UnsupportedFormatException catch (e) {
      if (!quiet) stderr.writeln('Error: $e');
      exit(_exitFileError);
    } on CorruptFileException catch (e) {
      if (!quiet) stderr.writeln('Error: $e');
      exit(_exitFileError);
    }

    final aboveThreshold =
        result.defects.where((d) => d.confidence >= threshold).toList();

    if (!quiet) {
      if (outputFormat == 'json') {
        _printJson(path, result);
      } else {
        _printText(path, result, verbose: verbose);
      }
    }

    exit(aboveThreshold.isNotEmpty ? _exitDefectsFound : _exitClean);
  }

  // ---- Batch mode ---------------------------------------------------------
  final List<Map<String, dynamic>> batchJson = [];
  int totalDefects = 0;
  int worstExitCode = _exitClean;

  for (final path in filePaths) {
    AnalysisResult? result;
    String? errorMsg;
    try {
      if (!quiet && verbose) stderr.writeln('Analysing $path …');
      if (isRaw) {
        final bytes = Uint8List.fromList(await File(path).readAsBytes());
        result = analysePcm(bytes, format: pcmFormat!, config: config);
      } else {
        result = await analyseFile(path, config: config);
      }
    } on IoException catch (e) {
      errorMsg = '$e';
    } on UnsupportedFormatException catch (e) {
      errorMsg = '$e';
    } on CorruptFileException catch (e) {
      errorMsg = '$e';
    }

    if (result != null) {
      totalDefects += result.defects.length;
      final above = result.defects.where((d) => d.confidence >= threshold);
      if (above.isNotEmpty && worstExitCode < _exitDefectsFound) {
        worstExitCode = _exitDefectsFound;
      }

      if (!quiet) {
        if (outputFormat == 'json') {
          batchJson.add({'file': path, 'result': result.toJson()});
        } else {
          _printTextCompact(path, result);
        }
      }
    } else {
      if (worstExitCode < _exitFileError) {
        worstExitCode = _exitFileError;
      }
      if (!quiet) {
        if (outputFormat == 'json') {
          batchJson.add({'file': path, 'error': errorMsg});
        } else {
          stdout.writeln('ERROR  $path: $errorMsg');
        }
      }
    }
  }

  if (!quiet && outputFormat == 'json') {
    stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({'files': batchJson}));
  } else if (!quiet && outputFormat == 'text') {
    stdout.writeln(
        '\nSummary: ${filePaths.length} file(s), $totalDefects total defect(s).');
  }

  exit(worstExitCode);
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

void _printJson(String path, AnalysisResult result) {
  final data = {'file': path, 'result': result.toJson()};
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(data));
}

void _printText(String path, AnalysisResult result, {bool verbose = false}) {
  final meta = result.metadata;
  stdout.writeln('\nFile : $path');
  stdout.writeln(
      'Audio: ${meta.channels}ch  ${meta.sampleRate} Hz  ${meta.bitDepth}-bit  '
      '${_fmtDuration(meta.duration)}');
  stdout.writeln(
      'Score: aggregate confidence = ${result.aggregateConfidence.toStringAsFixed(3)}');
  if (result.defects.isEmpty) {
    stdout.writeln('Result: No defects detected.\n');
    return;
  }
  stdout.writeln('\n${result.defects.length} defect(s) found:\n');
  stdout.writeln(
      '${'Offset (ms)'.padLeft(12)}  ${'Type'.padLeft(6)}  ${'Conf'.padLeft(6)}  '
      '${'Channel'.padLeft(7)}  ${'Amplitude'.padLeft(10)}');
  stdout.writeln('─' * 56);
  for (final d in result.defects) {
    stdout.writeln(
      '${d.offset.inMilliseconds.toString().padLeft(12)}  '
      '${d.type.name.padLeft(6)}  '
      '${d.confidence.toStringAsFixed(3).padLeft(6)}  '
      '${d.channel.toString().padLeft(7)}  '
      '${d.amplitude.toStringAsFixed(4).padLeft(10)}',
    );
  }
  stdout.writeln();
}

void _printTextCompact(String path, AnalysisResult result) {
  final status = result.defects.isEmpty ? 'CLEAN' : 'DEFECTS';
  stdout.writeln(
    '${status.padRight(8)}  ${result.defects.length.toString().padLeft(5)} defect(s)  '
    'score=${result.aggregateConfidence.toStringAsFixed(3)}  $path',
  );
}

String _fmtDuration(Duration d) {
  final min = d.inMinutes;
  final sec = d.inSeconds % 60;
  final ms = d.inMilliseconds % 1000;
  return '${min}m${sec.toString().padLeft(2, '0')}.${ms.toString().padLeft(3, '0')}s';
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

double _parseDouble(String s, String argName) {
  final v = double.tryParse(s);
  if (v == null || v < 0.0 || v > 1.0) {
    stderr.writeln('Error: --$argName must be a number between 0.0 and 1.0, got "$s"');
    exit(_exitUsageError);
  }
  return v;
}

// ---------------------------------------------------------------------------
// Path / glob expansion
// ---------------------------------------------------------------------------

Future<List<String>> _expandPaths(List<String> patterns) async {
  final List<String> paths = [];
  for (final pattern in patterns) {
    final f = File(pattern);
    if (await f.exists()) {
      paths.add(pattern);
      continue;
    }
    // Naive glob: only support trailing wildcard with a base directory
    final sep = Platform.pathSeparator;
    final idx = math.max(pattern.lastIndexOf('/'), pattern.lastIndexOf(sep));
    final dir = idx < 0 ? Directory.current : Directory(pattern.substring(0, idx));
    final glob = idx < 0 ? pattern : pattern.substring(idx + 1);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && _matchGlob(glob, entity.path.split(sep).last)) {
          paths.add(entity.path);
        }
      }
    }
  }
  return paths;
}

bool _matchGlob(String pattern, String name) {
  if (!pattern.contains('*')) return pattern == name;
  final parts = pattern.split('*');
  if (parts.length != 2) return false;
  return name.startsWith(parts[0]) && name.endsWith(parts[1]);
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

void _usage(ArgParser parser, [String? error]) {
  if (error != null) stderr.writeln('Error: $error\n');
  stdout
    ..writeln('audiodefect — Audio pop/click defect detector (WAV, AIFF)')
    ..writeln()
    ..writeln('Usage:')
    ..writeln('  audiodefect analyse <file|glob> [options]')
    ..writeln()
    ..writeln('Examples:')
    ..writeln('  audiodefect analyse recording.wav')
    ..writeln('  audiodefect analyse recording.aiff')
    ..writeln('  audiodefect analyse recording.raw --raw --sample-rate=48000 --bit-depth=24 --channels=1')
    ..writeln()
    ..writeln('Options:')
    ..writeln(parser.usage);
}
