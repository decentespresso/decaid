import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_puck_estimator_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_puck_estimator.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';

import '../../helpers/mock_device_discovery_service.dart';

/// A Rev-3 frame with every optional field populated.
ByteData _fullFrame() {
  final b = ByteData(23);
  b.setUint8(0, 3); // rev
  b.setUint8(1, 0x05); // flags
  b.setUint16(2, 450, Endian.big); // r1 = 4.50
  b.setUint16(4, 1250, Endian.big); // r2 = 1.250
  b.setUint16(6, 2500, Endian.big); // c  = 2.500
  b.setUint8(8, 204); // confR = 0.8
  b.setUint8(9, 15); // lag = 1.5 s
  b.setUint8(10, 128); // lagConf
  b.setUint8(11, 25); // sigmaQ = 0.25
  b.setUint16(12, 130, Endian.big); // vAbs = 13.0 mL
  b.setUint16(14, 320, Endian.big); // lastPauseTau = 3.20 s
  b.setUint8(16, 3); // detEventCount
  b.setUint16(17, 88, Endian.big); // detLastEventT = 8.8 s
  b.setUint8(19, 100); // detLastEventMag
  b.setUint8(20, 60); // detLastEventConc
  b.setUint16(21, 1800, Endian.big); // wPuck = 1.800 W
  return b;
}

/// A Rev-3 frame whose power field is at its "not yet observed" sentinel.
ByteData _powerUnobservedFrame() {
  final b = _fullFrame();
  b.setUint16(21, 0xFFFF, Endian.big);
  return b;
}

/// A base Rev-1 frame with the unobservable fields at their wire sentinels.
ByteData _sentinelFrame() {
  final b = ByteData(16);
  b.setUint8(0, 1); // rev 1 -> no detector tail
  b.setUint8(1, 0);
  b.setUint16(2, 0xFFFF, Endian.big); // r1 unobserved
  b.setUint16(4, 0xFFFF, Endian.big); // r2 unobserved
  b.setUint16(6, 0xFFFF, Endian.big); // c unobserved
  b.setUint8(8, 0);
  b.setUint8(9, 0xFF); // lag unobserved
  b.setUint8(10, 0);
  b.setUint8(11, 0);
  b.setUint16(12, 0xFFFF, Endian.big); // vAbs unobserved
  b.setUint16(14, 0xFFFF, Endian.big); // lastPauseTau unobserved
  return b;
}

void main() {
  group('BenglePuckEstimator sensor payload', () {
    test('a full Rev-2 frame maps every declared channel', () {
      final sample = parseBengleEstSample(_fullFrame())!;
      final json = BenglePuckEstimator.encodeSample(sample);

      expect(json['rev'], 3);
      expect(json['flags'], 0x05);
      expect(json['r1'], closeTo(4.5, 1e-9));
      expect(json['r2'], closeTo(1.25, 1e-9));
      expect(json['compliance'], closeTo(2.5, 1e-9));
      expect(json['confidence'], closeTo(204 / 255, 1e-9));
      expect(json['lag'], closeTo(1.5, 1e-9));
      expect(json['sigmaQ'], closeTo(0.25, 1e-9));
      expect(json['absorbedVolume'], closeTo(13.0, 1e-9));
      expect(json['lastPauseTau'], closeTo(3.2, 1e-9));
      expect(json['collapseEventCount'], 3);
      expect(json['collapseLastEventT'], closeTo(8.8, 1e-9));
      expect(json['hydraulicPowerMeasured'], closeTo(1.8, 1e-9));
    });

    test('unobserved fields are OMITTED, never zero', () {
      final sample = parseBengleEstSample(_sentinelFrame())!;
      final json = BenglePuckEstimator.encodeSample(sample);

      // A zero here would read as a real measurement of zero resistance.
      for (final key in [
        'r1',
        'r2',
        'compliance',
        'lag',
        'absorbedVolume',
        'lastPauseTau',
        'collapseEventCount',
        'collapseLastEventT',
      ]) {
        expect(json.containsKey(key), isFalse, reason: '$key must be omitted');
      }
      // Always-present fields survive.
      expect(json.containsKey('confidence'), isTrue);
      expect(json.containsKey('sigmaQ'), isTrue);
      expect(json['rev'], 1);
      // A Rev-1 frame has no power tail at all.
      expect(json.containsKey('hydraulicPowerMeasured'), isFalse);
    });

    test('an unobserved power sentinel is omitted, not zeroed', () {
      final sample = parseBengleEstSample(_powerUnobservedFrame())!;
      expect(sample.wPuck, isNull);
      final json = BenglePuckEstimator.encodeSample(sample);
      // 0 W is a real, different statement from "not yet observed".
      expect(json.containsKey('hydraulicPowerMeasured'), isFalse);
    });

    test('a Rev-2 frame decodes fully but carries no power', () {
      // Offsets 0-20 are frozen, so the older firmware still decodes; only the
      // Rev-3 tail is absent.
      final full = _fullFrame();
      final v2 = ByteData(21);
      for (var i = 0; i < 21; i++) {
        v2.setUint8(i, full.getUint8(i));
      }
      v2.setUint8(0, 2); // rev 2
      final sample = parseBengleEstSample(v2)!;
      expect(sample.r1, closeTo(4.5, 1e-9));
      expect(sample.detEventCount, 3);
      expect(sample.wPuck, isNull);
    });

    test('a rev-3 frame truncated to 22 bytes drops the power tail', () {
      final full = _fullFrame();
      final short = ByteData(22);
      for (var i = 0; i < 22; i++) {
        short.setUint8(i, full.getUint8(i));
      }
      final sample = parseBengleEstSample(short)!;
      expect(sample.rev, 3);
      expect(sample.detEventCount, 3, reason: 'the rev-2 tail must survive');
      expect(
        sample.wPuck,
        isNull,
        reason: 'a half-present u16 must not decode',
      );
    });

    test('every emitted key is a declared data channel', () async {
      final bengle = MockBengle();
      final sensor = BenglePuckEstimator(bengle: bengle);
      final declared = sensor.info.dataChannels.map((c) => c.key).toSet();

      final json = BenglePuckEstimator.encodeSample(
        parseBengleEstSample(_fullFrame())!,
      );

      expect(json.keys.toSet().difference(declared), isEmpty);
      await sensor.disconnect();
    });

    test('the sensor id is derived from the machine id', () {
      final bengle = MockBengle(deviceId: 'BengleXYZ');
      final sensor = BenglePuckEstimator(bengle: bengle);
      expect(sensor.deviceId, 'BengleXYZ-puckestimator');
      expect(sensor.type, DeviceType.sensor);
    });

    test('frames reach the data stream once connected', () async {
      final bengle = MockBengle();
      final sensor = BenglePuckEstimator(bengle: bengle);
      await sensor.onConnect();

      final first = sensor.data.first;
      bengle.emitPuckEstimator(parseBengleEstSample(_fullFrame())!);

      final payload = await first;
      expect(payload['r1'], closeTo(4.5, 1e-9));
      await sensor.disconnect();
    });
  });

  group('BenglePuckEstimatorBridge registration', () {
    late DeviceController deviceController;
    late SensorController sensorController;
    late De1Controller de1Controller;

    setUp(() async {
      deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      sensorController = SensorController(controller: deviceController);
      de1Controller = De1Controller(controller: deviceController);
    });

    test('no sensor is registered until a frame actually arrives', () async {
      final bridge = BenglePuckEstimatorBridge(
        de1Controller: de1Controller,
        sensorController: sensorController,
      );
      final bengle = MockBengle();
      await de1Controller.connectToDe1(bengle);
      await Future<void>.delayed(Duration.zero);

      // 0xA014 is serial-only: a Bengle that never emits [T] must not
      // advertise an estimator sensor.
      expect(
        sensorController.sensors.keys.any(
          (id) => id.endsWith('-puckestimator'),
        ),
        isFalse,
      );

      bengle.emitPuckEstimator(parseBengleEstSample(_fullFrame())!);
      await Future<void>.delayed(Duration.zero);

      expect(
        sensorController.sensors.keys.any(
          (id) => id.endsWith('-puckestimator'),
        ),
        isTrue,
      );

      await bridge.dispose();
    });

    test('the sensor is unregistered when the machine goes away', () async {
      final bridge = BenglePuckEstimatorBridge(
        de1Controller: de1Controller,
        sensorController: sensorController,
      );
      final bengle = MockBengle();
      await de1Controller.connectToDe1(bengle);
      await Future<void>.delayed(Duration.zero);
      bengle.emitPuckEstimator(parseBengleEstSample(_fullFrame())!);
      await Future<void>.delayed(Duration.zero);
      expect(
        sensorController.sensors.keys.any(
          (id) => id.endsWith('-puckestimator'),
        ),
        isTrue,
      );

      await bridge.dispose();

      expect(
        sensorController.sensors.keys.any(
          (id) => id.endsWith('-puckestimator'),
        ),
        isFalse,
      );
    });
  });
}
