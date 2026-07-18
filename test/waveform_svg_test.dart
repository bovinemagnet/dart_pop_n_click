import 'package:test/test.dart';

import '../tool/waveform_svg.dart';

void main() {
  List<double> silence(int n) => List<double>.filled(n, 0.0);

  test('context marker sits at the defect position', () {
    final svg =
        waveformSvg(samples: silence(1000), sampleRate: 8000, defectIndex: 500);
    // 500/1000 × 800 = 400.0; context marker spans y=0..160.
    expect(svg, contains('x1="400.0" y1="0" x2="400.0" y2="160"'));
  });

  test('envelope draws one column per horizontal pixel', () {
    final svg = waveformSvg(
        samples: silence(16000), sampleRate: 8000, defectIndex: 8000);
    final path = RegExp(r'<path d="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(RegExp('M').allMatches(path).length, 800);
  });

  test('zoom window clamps at the start of the snippet', () {
    // 8000 Hz → ±160 samples; defect at 0 → window 0..160 (160 points).
    final svg =
        waveformSvg(samples: silence(1000), sampleRate: 8000, defectIndex: 0);
    final pts =
        RegExp(r'<polyline points="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(pts.trim().split(' ').length, 160);
  });

  test('zoom window clamps at the end of the snippet', () {
    // defect at 999 → window 839..1000 (161 points).
    final svg =
        waveformSvg(samples: silence(1000), sampleRate: 8000, defectIndex: 999);
    final pts =
        RegExp(r'<polyline points="([^"]*)"').firstMatch(svg)!.group(1)!;
    expect(pts.trim().split(' ').length, 161);
  });

  test('zoom panel auto-scales to the window peak and captions the gain', () {
    final samples = silence(1000)..[500] = 0.25;
    final svg =
        waveformSvg(samples: samples, sampleRate: 8000, defectIndex: 500);
    expect(svg, contains('±20 ms ×4.0'));
  });

  test('silent window falls back to unity gain', () {
    final svg =
        waveformSvg(samples: silence(1000), sampleRate: 8000, defectIndex: 500);
    expect(svg, contains('±20 ms ×1.0'));
  });
}
