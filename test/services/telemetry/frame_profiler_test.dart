import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/telemetry/frame_profiler.dart';

void main() {
  test('frame capture is off unless built with perfFrames', () {
    expect(FrameProfiler.enabled, isFalse);
  });

  test('mark and dump are no-ops when capture is off', () {
    FrameProfiler.mark('onboarding:initialization');
    FrameProfiler.dump();
    FrameProfiler.stop();
    expect(FrameProfiler.enabled, isFalse);
  });
}
