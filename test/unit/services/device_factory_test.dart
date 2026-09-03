import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/services/device_factory.dart';

class _FakeBleTransport extends BLETransport {
  @override
  String get id => 'fake-ble';

  @override
  String get name => 'Fake BLE';

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.disconnected);

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<List<String>> discoverServices() async => [];

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {}

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {}

  @override
  Future<void> setTransportPriority(bool prioritized) async {}
}

class _FakeSerialTransport extends SerialTransport {
  @override
  String get id => 'fake-serial';

  @override
  String get name => 'Fake Serial';

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.disconnected);

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();
}

void main() {
  group('DeviceFactory.createBle', () {
    final transport = _FakeBleTransport();

    test('unifiedDe1 returns UnifiedDe1', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.unifiedDe1,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.unifiedDe1);
      expect(device.transportType, TransportType.ble);
    });

    test('bengle returns Bengle', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.bengle,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.bengle);
    });

    test('decentScale returns DecentScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.decentScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.decentScale);
    });

    test('skale2 returns Skale2Scale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.skale2,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.skale2);
    });

    test('acaiaScale returns AcaiaScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.acaiaScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.acaiaScale);
    });

    test('felicitaArc returns FelicitaArc', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.felicitaArc,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.felicitaArc);
    });

    test('blackCoffeeScale returns BlackCoffeeScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.blackCoffeeScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.blackCoffeeScale);
    });

    test('bookooScale returns BookooScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.bookooScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.bookooScale);
    });

    test('timemoreDot returns TimemoreDotScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.timemoreDot,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.timemoreDot);
      expect(device.transportType, TransportType.ble);
    });

    test('eurekaScale returns EurekaScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.eurekaScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.eurekaScale);
    });

    test('smartChefScale returns SmartChefScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.smartChefScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.smartChefScale);
    });

    test('variaAkuScale returns VariaAkuScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.variaAkuScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.variaAkuScale);
    });

    test('difluidScale returns DifluidScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.difluidScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.difluidScale);
    });

    test('hiroiaScale returns HiroiaScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.hiroiaScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.hiroiaScale);
    });

    test('atomheartScale returns AtomheartScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.atomheartScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.atomheartScale);
    });

    test('weighMasterScale returns WeighMasterScale', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.weighMasterScale,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.weighMasterScale);
    });

    test('decentTemp returns DecentTemp', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.decentTemp,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.decentTemp);
    });

    test('difluidR2Sensor returns DifluidR2Sensor', () {
      final device = DeviceFactory.createBle(
        DeviceImplementation.difluidR2Sensor,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.difluidR2Sensor);
    });

    test('serial-only implementations return null', () {
      expect(
        DeviceFactory.createBle(DeviceImplementation.hdsSerial, transport),
        isNull,
      );
      expect(
        DeviceFactory.createBle(DeviceImplementation.hdsWifi, transport),
        isNull,
      );
      expect(
        DeviceFactory.createBle(DeviceImplementation.debugPort, transport),
        isNull,
      );
      expect(
        DeviceFactory.createBle(DeviceImplementation.sensorBasket, transport),
        isNull,
      );
      expect(
        DeviceFactory.createBle(
          DeviceImplementation.bengleDebugPort,
          transport,
        ),
        isNull,
      );
    });
  });

  group('DeviceFactory.createSerial', () {
    final transport = _FakeSerialTransport();

    test('hdsSerial returns HDSSerial', () {
      final device = DeviceFactory.createSerial(
        DeviceImplementation.hdsSerial,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.hdsSerial);
      expect(device.transportType, TransportType.serial);
    });

    test('debugPort returns DebugPort', () {
      final device = DeviceFactory.createSerial(
        DeviceImplementation.debugPort,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.debugPort);
    });

    test('sensorBasket returns SensorBasket', () {
      final device = DeviceFactory.createSerial(
        DeviceImplementation.sensorBasket,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.sensorBasket);
    });

    test('bengleDebugPort returns BengleDebugPort', () {
      final device = DeviceFactory.createSerial(
        DeviceImplementation.bengleDebugPort,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.bengleDebugPort);
      expect(device.transportType, TransportType.serial);
    });

    test('unifiedDe1 returns UnifiedDe1 (serial DE1)', () {
      final device = DeviceFactory.createSerial(
        DeviceImplementation.unifiedDe1,
        transport,
      );
      expect(device, isNotNull);
      expect(device!.implementation, DeviceImplementation.unifiedDe1);
      expect(device.transportType, TransportType.serial);
    });

    test('BLE-only implementations return null', () {
      expect(
        DeviceFactory.createSerial(DeviceImplementation.decentScale, transport),
        isNull,
      );
      expect(
        DeviceFactory.createSerial(DeviceImplementation.bengle, transport),
        isNull,
      );
      expect(
        DeviceFactory.createSerial(DeviceImplementation.hdsWifi, transport),
        isNull,
      );
    });
  });

  group('TransportType', () {
    test('has ble, serial, wifi, unknown variants', () {
      expect(TransportType.values, contains(TransportType.ble));
      expect(TransportType.values, contains(TransportType.serial));
      expect(TransportType.values, contains(TransportType.wifi));
      expect(TransportType.values, contains(TransportType.unknown));
    });
  });

  group('DeviceImplementation', () {
    test('has all expected values', () {
      expect(DeviceImplementation.values.length, greaterThanOrEqualTo(20));
      expect(
        DeviceImplementation.values,
        contains(DeviceImplementation.unifiedDe1),
      );
      expect(
        DeviceImplementation.values,
        contains(DeviceImplementation.bengle),
      );
      expect(
        DeviceImplementation.values,
        contains(DeviceImplementation.decentScale),
      );
      expect(
        DeviceImplementation.values,
        contains(DeviceImplementation.hdsSerial),
      );
      expect(
        DeviceImplementation.values,
        contains(DeviceImplementation.hdsWifi),
      );
    });
  });

  group('Transport self-reporting', () {
    test('BLETransport.transportType returns ble', () {
      expect(_FakeBleTransport().transportType, TransportType.ble);
    });

    test('SerialTransport.transportType returns serial', () {
      expect(_FakeSerialTransport().transportType, TransportType.serial);
    });
  });
}
