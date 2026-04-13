/// Core pop/click detection algorithm.
///
/// Algorithm overview:
/// 1. Apply a first-order high-pass differentiator: d[n] = x[n] - x[n-1].
///    This accentuates transients while suppressing slow-moving signal content.
/// 2. Compute the Median Absolute Deviation (MAD) of |d| over a sliding window
///    to obtain an adaptive local-noise estimate.
/// 3. Flag any sample whose |d| exceeds `thresholdMultiplier * MAD`.
/// 4. Merge consecutive flagged samples into contiguous defect regions.
/// 5. Classify each region as a *click* (1–10 samples) or *pop* (10–150 samples).
///    Regions wider than 150 samples are discarded (likely legitimate transients
///    such as drum hits).
/// 6. Compute a confidence score for each defect using a logistic function
///    applied to the peak-to-noise ratio.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'math_utils.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Named constants
// ---------------------------------------------------------------------------

/// Normal distribution consistency constant (MAD → sigma).
const double _kMadScaleFactor = 1.4826;

/// Minimum threshold to avoid division by zero in near-silence.
const double _kThresholdFloor = 1e-6;

/// Centre of the logistic (sigmoid) confidence curve.
const double _kLogisticCentre = 10.0;

/// Scale of the logistic (sigmoid) confidence curve.
const double _kLogisticScale = 3.0;

/// Maximum gap (in samples) between flagged samples to merge regions.
const int _kMergeGap = 4;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Detect pops and clicks in [channelSamples].
///
/// [channelSamples] must be a list of one [Float32List] per audio channel.
/// [sampleRate] is used to convert sample indices to time offsets.
/// [config] controls sensitivity and result filtering.
List<Defect> detectDefects(
  List<Float32List> channelSamples,
  int sampleRate,
  DetectorConfig config,
) {
  final List<Defect> allDefects = [];

  final channelsToProcess = config.perChannel ? channelSamples.length : 1;

  for (int ch = 0; ch < channelsToProcess; ch++) {
    final Float32List mono;
    if (config.perChannel) {
      mono = channelSamples[ch];
    } else {
      // Sum to mono
      mono = _sumToMono(channelSamples);
    }

    final defects = _detectOnChannel(mono, sampleRate, ch, config);
    allDefects.addAll(defects);
  }

  // Sort by offset
  allDefects.sort((a, b) => a.offset.compareTo(b.offset));

  // Apply minConfidence filter
  final filtered = config.minConfidence > 0
      ? allDefects.where((d) => d.confidence >= config.minConfidence).toList()
      : allDefects;

  // Apply maxDefects limit
  if (config.maxDefects > 0 && filtered.length > config.maxDefects) {
    return filtered.sublist(0, config.maxDefects);
  }
  return filtered;
}

// ---------------------------------------------------------------------------
// Per-channel detection
// ---------------------------------------------------------------------------

List<Defect> _detectOnChannel(
  Float32List samples,
  int sampleRate,
  int channelIndex,
  DetectorConfig config,
) {
  if (samples.length < 2) return [];

  // Step 1: first-order differentiator
  final diff = Float32List(samples.length);
  for (int i = 1; i < samples.length; i++) {
    diff[i] = samples[i] - samples[i - 1];
  }

  // Step 2: adaptive MAD threshold
  // Window size: ~10 ms worth of samples, minimum 128
  final windowSize = math.max(128, sampleRate ~/ 100);
  final threshold =
      _buildAdaptiveThreshold(diff, windowSize, config.thresholdMultiplier);

  // Step 3: flag samples
  final flagged = List<bool>.filled(samples.length, false);
  for (int i = 0; i < samples.length; i++) {
    flagged[i] = diff[i].abs() > threshold[i];
  }

  // Step 4: merge into regions
  final regions = _mergeRegions(flagged);

  // Step 5 & 6: classify and score
  const maxClickSamples = 10;
  const maxPopSamples = 150;

  final List<Defect> defects = [];

  for (final region in regions) {
    final width = region.$2 - region.$1 + 1;
    if (width > maxPopSamples) continue; // discard – too wide to be a defect

    final type = width <= maxClickSamples ? DefectType.click : DefectType.pop;

    // Peak amplitude in original signal within the region
    double peakAmp = 0.0;
    int peakIdx = region.$1;
    for (int i = region.$1; i <= region.$2; i++) {
      if (samples[i].abs() > peakAmp) {
        peakAmp = samples[i].abs();
        peakIdx = i;
      }
    }

    // Peak differential value in region
    double peakDiff = 0.0;
    for (int i = region.$1; i <= region.$2; i++) {
      if (diff[i].abs() > peakDiff) peakDiff = diff[i].abs();
    }

    // Local noise estimate at peak
    final localNoise = threshold[peakIdx] / config.thresholdMultiplier;
    final confidence = _logisticConfidence(peakDiff, localNoise);

    final offsetMs = (peakIdx / sampleRate * 1000).round();
    final lengthMs = math.max(1, (width / sampleRate * 1000).round());

    defects.add(Defect(
      offset: Duration(milliseconds: offsetMs),
      length: Duration(milliseconds: lengthMs),
      type: type,
      confidence: confidence,
      channel: channelIndex,
      sampleIndex: peakIdx,
      amplitude: peakAmp,
    ));
  }

  return defects;
}

// ---------------------------------------------------------------------------
// Adaptive threshold
// ---------------------------------------------------------------------------

/// Build a per-sample threshold array using a sliding-window MAD estimate.
Float32List _buildAdaptiveThreshold(
  Float32List diff,
  int windowSize,
  double multiplier,
) {
  final n = diff.length;
  final threshold = Float32List(n);
  final half = windowSize ~/ 2;

  for (int i = 0; i < n; i++) {
    final start = math.max(0, i - half);
    final end = math.min(n, i + half);
    final window = Float32List(end - start);
    for (int j = start; j < end; j++) {
      window[j - start] = diff[j].abs();
    }
    final madValue = mad(window);
    // MAD → sigma: multiply by consistency factor for normal distribution.
    threshold[i] = madValue * _kMadScaleFactor * multiplier;
    // Enforce a minimum floor to avoid spurious detections in digital silence.
    if (threshold[i] < _kThresholdFloor) threshold[i] = _kThresholdFloor;
  }
  return threshold;
}

// median() and mad() are in math_utils.dart (public API).

// ---------------------------------------------------------------------------
// Region merging
// ---------------------------------------------------------------------------

/// Merge consecutive flagged samples into (start, end) inclusive tuples.
/// Adjacent flagged regions separated by ≤ `gap` samples are merged.
List<(int, int)> _mergeRegions(List<bool> flagged, {int gap = _kMergeGap}) {
  final List<(int, int)> regions = [];
  int? start;
  int? last;

  for (int i = 0; i < flagged.length; i++) {
    if (flagged[i]) {
      if (start == null) {
        start = i;
        last = i;
      } else if (i - last! <= gap) {
        last = i;
      } else {
        regions.add((start, last));
        start = i;
        last = i;
      }
    }
  }
  if (start != null && last != null) regions.add((start, last));
  return regions;
}

// ---------------------------------------------------------------------------
// Confidence scoring
// ---------------------------------------------------------------------------

/// Map peak-to-noise ratio to a \[0.0, 1.0\] confidence score using a
/// logistic (sigmoid) function so that intermediate ratios are interpretable.
double _logisticConfidence(double peakDiff, double localNoise) {
  if (localNoise <= 0) return 1.0;
  final ratio = peakDiff / localNoise;
  // Sigmoid centred at ratio = _kLogisticCentre, scaled so ratio ≈ 20 → 0.99
  final score =
      1.0 / (1.0 + math.exp(-(ratio - _kLogisticCentre) / _kLogisticScale));
  return score.clamp(0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Aggregate confidence
// ---------------------------------------------------------------------------

/// Compute an aggregate confidence score from a list of individual defects.
/// Uses 1 − ∏(1 − cᵢ) so each additional high-confidence defect raises the
/// overall score.
double computeAggregateConfidence(List<Defect> defects) {
  if (defects.isEmpty) return 0.0;
  double notProduct = 1.0;
  for (final d in defects) {
    notProduct *= (1.0 - d.confidence);
  }
  return (1.0 - notProduct).clamp(0.0, 1.0);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Clipping detection
// ---------------------------------------------------------------------------

/// Detect regions where consecutive samples saturate at or near [threshold].
///
/// Returns one [Defect] per run of [minRun]+ consecutive clipped samples,
/// per channel. Confidence scales with run length (caps at 1.0).
List<Defect> detectClipping(
  List<Float32List> channels,
  int sampleRate, {
  double threshold = 0.99,
  int minRun = 3,
}) {
  final List<Defect> defects = [];
  for (int ch = 0; ch < channels.length; ch++) {
    final samples = channels[ch];
    int runStart = -1;
    double peak = 0.0;

    void emit(int start, int endExclusive) {
      final runLength = endExclusive - start;
      if (runLength < minRun) return;
      final offsetMs = (start / sampleRate * 1000).round();
      final lengthMs = math.max(1, (runLength / sampleRate * 1000).round());
      defects.add(Defect(
        offset: Duration(milliseconds: offsetMs),
        length: Duration(milliseconds: lengthMs),
        type: DefectType.clipping,
        confidence: math.min(1.0, runLength / 10.0),
        channel: ch,
        sampleIndex: start,
        amplitude: peak,
      ));
    }

    for (int i = 0; i < samples.length; i++) {
      final a = samples[i].abs();
      if (a >= threshold) {
        if (runStart < 0) {
          runStart = i;
          peak = a;
        } else if (a > peak) {
          peak = a;
        }
      } else if (runStart >= 0) {
        emit(runStart, i);
        runStart = -1;
        peak = 0.0;
      }
    }
    if (runStart >= 0) {
      emit(runStart, samples.length);
    }
  }
  return defects;
}

// ---------------------------------------------------------------------------
// Dropout detection
// ---------------------------------------------------------------------------

/// Detect regions of unexpected digital silence surrounded by audio content.
///
/// A dropout is a run of samples below [silenceThreshold] whose length is
/// between [minMs] and [maxMs] (inclusive) and that is bordered on both
/// sides by non-silent samples. Runs at the very start or end of the
/// signal are ignored (they could be intentional leading/trailing silence).
List<Defect> detectDropouts(
  List<Float32List> channels,
  int sampleRate, {
  double silenceThreshold = 1e-4,
  double minMs = 1.0,
  double maxMs = 50.0,
}) {
  if (channels.isEmpty) return [];
  final mono = channels.length == 1 ? channels[0] : _sumToMono(channels);
  final n = mono.length;
  if (n < 3) return [];

  final minSamples = math.max(1, (minMs * sampleRate / 1000).round());
  final maxSamples = math.max(minSamples, (maxMs * sampleRate / 1000).round());

  final List<Defect> defects = [];
  int runStart = -1;
  for (int i = 0; i < n; i++) {
    final silent = mono[i].abs() < silenceThreshold;
    if (silent) {
      if (runStart < 0) runStart = i;
    } else if (runStart >= 0) {
      final runEnd = i; // exclusive
      final runLength = runEnd - runStart;
      if (runStart > 0 &&
          runEnd < n &&
          runLength >= minSamples &&
          runLength <= maxSamples &&
          mono[runStart - 1].abs() >= silenceThreshold &&
          mono[runEnd].abs() >= silenceThreshold) {
        // Compute surrounding RMS from a short window on either side
        final winRadius =
            math.min(sampleRate ~/ 100, math.min(runStart, n - runEnd));
        double sumSq = 0.0;
        int count = 0;
        for (int k = math.max(0, runStart - winRadius); k < runStart; k++) {
          sumSq += mono[k] * mono[k];
          count++;
        }
        for (int k = runEnd; k < math.min(n, runEnd + winRadius); k++) {
          sumSq += mono[k] * mono[k];
          count++;
        }
        final rms = count > 0 ? math.sqrt(sumSq / count) : 0.0;
        final confidence = math.min(1.0, rms * 10.0);

        final offsetMs = (runStart / sampleRate * 1000).round();
        final lengthMs = math.max(1, (runLength / sampleRate * 1000).round());
        defects.add(Defect(
          offset: Duration(milliseconds: offsetMs),
          length: Duration(milliseconds: lengthMs),
          type: DefectType.dropout,
          confidence: confidence,
          channel: 0,
          sampleIndex: runStart,
          amplitude: 0.0,
        ));
      }
      runStart = -1;
    }
  }
  return defects;
}

// ---------------------------------------------------------------------------
// DC offset
// ---------------------------------------------------------------------------

/// Compute per-channel DC offset (mean sample value). Returns a list with
/// one entry per input channel.
List<double> computeDcOffsets(List<Float32List> channels) {
  return channels.map((ch) {
    if (ch.isEmpty) return 0.0;
    double sum = 0;
    for (final s in ch) {
      sum += s;
    }
    return sum / ch.length;
  }).toList(growable: false);
}

Float32List _sumToMono(List<Float32List> channels) {
  if (channels.length == 1) return channels[0];
  final n = channels[0].length;
  for (int c = 1; c < channels.length; c++) {
    if (channels[c].length != n) {
      throw StateError(
        'Channel length mismatch: channel 0 has $n samples but '
        'channel $c has ${channels[c].length} samples.',
      );
    }
  }
  final mono = Float32List(n);
  final scale = 1.0 / channels.length;
  for (final ch in channels) {
    for (int i = 0; i < n; i++) {
      mono[i] += ch[i] * scale;
    }
  }
  return mono;
}
