import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';

void main() {
  group('MockBengle', () {
    test('implements BengleInterface', () {
      final m = MockBengle();
      expect(m, isA<BengleInterface>());
    });

    test(
      'still implements De1Interface (so existing scan paths consume it)',
      () {
        final m = MockBengle();
        expect(m, isA<De1Interface>());
      },
    );

    test('extends MockDe1 to reuse the simulated state machine', () {
      final m = MockBengle();
      expect(m, isA<MockDe1>());
    });

    test('default deviceId is "MockBengle"', () {
      final m = MockBengle();
      expect(m.deviceId, equals('MockBengle'));
    });

    test('default name is "MockBengle" (matches MockDe1 convention)', () {
      final m = MockBengle();
      expect(m.name, equals('MockBengle'));
    });

    test('deviceId can be overridden via constructor', () {
      final m = MockBengle(deviceId: 'CustomBengleId');
      expect(m.deviceId, equals('CustomBengleId'));
    });
  });

  group('MockBengle SAW', () {
    test('initial target is 0.0 (off)', () async {
      final m = MockBengle();
      expect(await m.getStopAtWeightTarget(), 0.0);
    });

    test('setStopAtWeightTarget stores the value', () async {
      final m = MockBengle();
      await m.setStopAtWeightTarget(30.0);
      expect(await m.getStopAtWeightTarget(), 30.0);
    });

    test('clamps over-range values to 10000.0', () async {
      final m = MockBengle();
      await m.setStopAtWeightTarget(12000.0);
      expect(await m.getStopAtWeightTarget(), 10000.0);
    });

    test('clamps negative values to 0.0', () async {
      final m = MockBengle();
      await m.setStopAtWeightTarget(-10.0);
      expect(await m.getStopAtWeightTarget(), 0.0);
    });

    test('stopAtWeightTarget stream emits cached value', () async {
      final m = MockBengle();
      await m.setStopAtWeightTarget(36.0);
      expect(await m.stopAtWeightTarget.first, 36.0);
    });
  });

  group('MockBengle cup warmer', () {
    test('initial setpoint is 0.0 (off)', () async {
      final m = MockBengle();
      expect(await m.getCupWarmerTemperature(), 0.0);
    });

    test('setCupWarmerTemperature stores the value', () async {
      final m = MockBengle();
      await m.setCupWarmerTemperature(60.0);
      expect(await m.getCupWarmerTemperature(), 60.0);
    });

    test('clamps over-range values to 80.0', () async {
      final m = MockBengle();
      await m.setCupWarmerTemperature(120.0);
      expect(await m.getCupWarmerTemperature(), 80.0);
    });

    test('clamps negative values to 0.0', () async {
      final m = MockBengle();
      await m.setCupWarmerTemperature(-10.0);
      expect(await m.getCupWarmerTemperature(), 0.0);
    });
  });
}
