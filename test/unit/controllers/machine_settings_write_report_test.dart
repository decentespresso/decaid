import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/machine_settings_write_report.dart';

void main() {
  group('MachineSettingWriteResult.verified', () {
    test('equal ints report applied', () {
      final result = MachineSettingWriteResult.verified(
        requested: 45,
        actual: 45,
      );
      expect(result.status, MachineSettingWriteStatus.applied);
    });

    test('a clamped int reports adjusted and carries the actual', () {
      final result = MachineSettingWriteResult.verified(
        requested: 51,
        actual: 50,
      );
      expect(result.status, MachineSettingWriteStatus.adjusted);
      expect(result.requested, 51);
      expect(result.actual, 50);
    });

    test('int comparison is exact — no implicit tolerance', () {
      final result = MachineSettingWriteResult.verified(
        requested: 20,
        actual: 21,
      );
      expect(result.status, MachineSettingWriteStatus.adjusted);
    });

    test('equal bools report applied', () {
      final result = MachineSettingWriteResult.verified(
        requested: true,
        actual: true,
      );
      expect(result.status, MachineSettingWriteStatus.applied);
    });

    test('differing bools report adjusted', () {
      final result = MachineSettingWriteResult.verified(
        requested: true,
        actual: false,
      );
      expect(result.status, MachineSettingWriteStatus.adjusted);
    });

    test('float representation noise inside half an LSB reports applied', () {
      final result = MachineSettingWriteResult.verified(
        requested: 4.1,
        actual: 4.1000000000000005,
        tolerance: 0.05,
      );
      expect(result.status, MachineSettingWriteStatus.applied);
    });

    test('a truncated scaled write of one LSB reports adjusted', () {
      final result = MachineSettingWriteResult.verified(
        requested: 3.3,
        actual: 3.2,
        tolerance: 0.05,
      );
      expect(result.status, MachineSettingWriteStatus.adjusted);
      expect(result.actual, 3.2);
    });

    test('a hundredth-LSB field flags a one-LSB difference', () {
      final result = MachineSettingWriteResult.verified(
        requested: 1.23,
        actual: 1.22,
        tolerance: 0.005,
      );
      expect(result.status, MachineSettingWriteStatus.adjusted);
    });

    test('a difference inside half an LSB is applied', () {
      final result = MachineSettingWriteResult.verified(
        requested: 4.1,
        actual: 4.14,
        tolerance: 0.05,
      );
      expect(result.status, MachineSettingWriteStatus.applied);
    });
  });

  group('MachineSettingWriteResult.unverified', () {
    test('carries the requested value and a null actual', () {
      final result = MachineSettingWriteResult.unverified(51);
      expect(result.status, MachineSettingWriteStatus.unverified);
      expect(result.requested, 51);
      expect(result.actual, isNull);
    });
  });

  group('toJson', () {
    test('a result serialises requested, actual and status', () {
      final json = MachineSettingWriteResult.verified(
        requested: 51,
        actual: 50,
      ).toJson();
      expect(json, {'requested': 51, 'actual': 50, 'status': 'adjusted'});
    });

    test('an unverified result serialises a null actual', () {
      final json = MachineSettingWriteResult.unverified(7.5).toJson();
      expect(json, {'requested': 7.5, 'actual': null, 'status': 'unverified'});
    });

    test('the report serialises as a field-keyed map', () {
      final report = MachineSettingsWriteReport({
        'fan': MachineSettingWriteResult.verified(requested: 51, actual: 50),
        'steamPurgeMode': MachineSettingWriteResult.verified(
          requested: 1,
          actual: 1,
        ),
      });

      expect(report.toJson(), {
        'fan': {'requested': 51, 'actual': 50, 'status': 'adjusted'},
        'steamPurgeMode': {'requested': 1, 'actual': 1, 'status': 'applied'},
      });
    });

    test('an empty report serialises as an empty map', () {
      expect(
        const MachineSettingsWriteReport({}).toJson(),
        <String, dynamic>{},
      );
    });
  });
}
