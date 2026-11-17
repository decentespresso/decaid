import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_sample_provenance.dart';

void main() {
  test('tokens are host-timed, bounded, single-use and session-local', () {
    var now = DateTime.utc(2026);
    withClock(Clock(() => now), () {
      final samples = PluginSampleProvenance(
        onClockRollback: () => fail('Unexpected rollback'),
      );
      final other = PluginSampleProvenance(
        onClockRollback: () => fail('Unexpected rollback'),
      );
      final first = samples.capture();
      now = now.add(const Duration(milliseconds: 100));
      final second = samples.capture();
      expect(() => other.consume(first), throwsA(isA<PluginDeviceException>()));
      expect(samples.consume(second), now);
      expect(
        () => samples.consume(first),
        throwsA(isA<PluginDeviceException>()),
      );
      expect(
        () => samples.consume(second),
        throwsA(isA<PluginDeviceException>()),
      );
      final evicted = samples.capture();
      for (var i = 0; i < PluginSampleProvenance.capacity; i++) {
        samples.capture();
      }
      expect(samples.count, PluginSampleProvenance.capacity);
      expect(
        () => samples.consume(evicted),
        throwsA(isA<PluginDeviceException>()),
      );
      samples.clear();
      expect(samples.count, 0);
    });
  });

  test('expiry and backward clock changes invalidate provenance', () {
    var now = DateTime.utc(2026);
    withClock(Clock(() => now), () {
      var rollbacks = 0;
      final samples = PluginSampleProvenance(
        onClockRollback: () => rollbacks++,
      );
      final expired = samples.capture();
      now = now.add(PluginSampleProvenance.lifetime);
      expect(
        () => samples.consume(expired),
        throwsA(isA<PluginDeviceException>()),
      );
      final future = samples.capture();
      now = now.subtract(const Duration(seconds: 1));
      expect(
        () => samples.consume(future),
        throwsA(isA<PluginDeviceException>()),
      );
      final current = samples.capture();
      expect(samples.consume(current), now);
      expect(rollbacks, 1);
    });
  });
}
