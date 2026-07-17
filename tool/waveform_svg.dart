/// Pure SVG waveform renderer for the harness labelling report.
///
/// Produces a two-panel image per snippet: a full-snippet min/max envelope
/// at a fixed ±1.0 scale (context), and a ±20 ms window around the defect
/// drawn sample-by-sample and auto-scaled to its own peak (zoom) — the view
/// where a genuine click stands out as an isolated spike.
library;

import 'dart:math' as math;

const int _width = 800;
const int _panelHeight = 160;
const int _captionHeight = 20;

/// Renders a two-panel waveform SVG for one snippet.
///
/// [samples] is the defect's channel, snippet-local; [defectIndex] is the
/// defect position within [samples]. Both panels carry a red marker at the
/// defect position.
String waveformSvg({
  required List<double> samples,
  required int sampleRate,
  required int defectIndex,
}) {
  final n = samples.length;
  final contextPath = _envelopePath(samples);
  final contextMarkerX = n > 0 ? defectIndex / n * _width : 0.0;

  final zoomHalf = (sampleRate * 0.020).round();
  var zStart = defectIndex - zoomHalf;
  var zEnd = defectIndex + zoomHalf;
  if (zStart < 0) zStart = 0;
  if (zEnd > n) zEnd = n;
  final zLen = math.max(1, zEnd - zStart);

  var peak = 0.0;
  for (var i = zStart; i < zEnd; i++) {
    final a = samples[i].abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 1.0 / peak : 1.0;

  final zoomTop = _panelHeight + _captionHeight;
  final zoomMid = zoomTop + _panelHeight / 2;
  final points = StringBuffer();
  for (var i = zStart; i < zEnd; i++) {
    final x = (i - zStart) / zLen * _width;
    final y = zoomMid - samples[i] * gain * (_panelHeight / 2 - 2);
    points
      ..write(x.toStringAsFixed(1))
      ..write(',')
      ..write(y.toStringAsFixed(1))
      ..write(' ');
  }
  final zoomMarkerX = (defectIndex - zStart) / zLen * _width;

  final height = 2 * (_panelHeight + _captionHeight);
  final cx = contextMarkerX.toStringAsFixed(1);
  final zx = zoomMarkerX.toStringAsFixed(1);
  return '''
<svg xmlns="http://www.w3.org/2000/svg" width="$_width" height="$height" viewBox="0 0 $_width $height">
<rect x="0" y="0" width="$_width" height="$_panelHeight" fill="#fafafa"/>
<line x1="0" y1="${_panelHeight ~/ 2}" x2="$_width" y2="${_panelHeight ~/ 2}" stroke="#ddd"/>
<path d="$contextPath" stroke="#1565c0" fill="none"/>
<line x1="$cx" y1="0" x2="$cx" y2="$_panelHeight" stroke="#d32f2f"/>
<text x="4" y="${_panelHeight + 14}" font-family="sans-serif" font-size="12" fill="#555">±1 s</text>
<rect x="0" y="$zoomTop" width="$_width" height="$_panelHeight" fill="#fafafa"/>
<line x1="0" y1="${zoomTop + _panelHeight ~/ 2}" x2="$_width" y2="${zoomTop + _panelHeight ~/ 2}" stroke="#ddd"/>
<polyline points="$points" stroke="#1565c0" fill="none"/>
<line x1="$zx" y1="$zoomTop" x2="$zx" y2="${zoomTop + _panelHeight}" stroke="#d32f2f"/>
<text x="4" y="${zoomTop + _panelHeight + 14}" font-family="sans-serif" font-size="12" fill="#555">±20 ms ×${gain.toStringAsFixed(1)}</text>
</svg>
''';
}

/// One min/max envelope column per horizontal pixel, fixed ±1.0 scale,
/// emitted as an SVG path of vertical strokes ("Mx y1Lx y2 " per column).
String _envelopePath(List<double> samples) {
  final n = samples.length;
  if (n == 0) return '';
  const mid = _panelHeight / 2;
  final buf = StringBuffer();
  for (var x = 0; x < _width; x++) {
    var lo = (x * n / _width).floor();
    var hi = ((x + 1) * n / _width).ceil();
    if (hi <= lo) hi = lo + 1;
    if (hi > n) hi = n;
    if (lo >= n) lo = n - 1;
    var minV = samples[lo], maxV = samples[lo];
    for (var i = lo + 1; i < hi; i++) {
      final v = samples[i];
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final y1 = mid - maxV.clamp(-1.0, 1.0) * (_panelHeight / 2 - 2);
    final y2 = mid - minV.clamp(-1.0, 1.0) * (_panelHeight / 2 - 2);
    buf
      ..write('M')
      ..write(x)
      ..write(' ')
      ..write(y1.toStringAsFixed(1))
      ..write('L')
      ..write(x)
      ..write(' ')
      ..write(y2.toStringAsFixed(1))
      ..write(' ');
  }
  return buf.toString();
}
