import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/acaia/acaia_scale.dart';
import 'package:reaprime/src/models/device/impl/atomheart/atomheart_scale.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/blackcoffee/blackcoffee_scale.dart';
import 'package:reaprime/src/models/device/impl/bookoo/bookoo_grinder.dart';
import 'package:reaprime/src/models/device/impl/bookoo/miniscale.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_r2_sensor.dart';
import 'package:reaprime/src/models/device/impl/difluid/difluid_scale.dart';
import 'package:reaprime/src/models/device/impl/eureka/eureka_scale.dart';
import 'package:reaprime/src/models/device/impl/felicita/arc.dart';
import 'package:reaprime/src/models/device/impl/hiroia/hiroia_scale.dart';
import 'package:reaprime/src/models/device/impl/skale/skale2_scale.dart';
import 'package:reaprime/src/models/device/impl/smartchef/smartchef_scale.dart';
import 'package:reaprime/src/models/device/impl/varia/varia_aku_scale.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/services/device_matcher.dart';

class _MockBLETransport extends BLETransport {
  @override
  String get id => 'AA:BB:CC:DD:EE:FF';

  @override
  String get name => 'Mock';

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.discovered);

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<String>> discoverServices() async => [];

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {}

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

  @override
  Future<void> dispose() async {}
}

void main() {
  group('DeviceMatcher', () {
    late _MockBLETransport mockTransport;

    setUp(() {
      mockTransport = _MockBLETransport();
    });

    test('Eclair scan filter uses the current service UUID', () {
      final services = DeviceMatcher.serviceUuidsFor(DeviceType.scale);

      expect(services, contains('b905eaea-2e63-0e04-7582-7913f10d8f81'));
      expect(services, isNot(contains('b905eaea-6c7e-4f73-b43d-2cdfcab29570')));
    });

    test('exact match for Decent Scale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Decent Scale',
      );

      expect(device, isNotNull);
      expect(device, isA<DecentScale>());
    });

    test('exact match for Skale2', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Skale2',
      );

      expect(device, isNotNull);
      expect(device, isA<Skale2Scale>());
    });

    test('prefix match for Felicita', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Felicita Arc',
      );

      expect(device, isNotNull);
      expect(device, isA<FelicitaArc>());
    });

    test('contains match for Acaia', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'ACAIA LUNAR',
      );

      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('contains match for Acaia Pyxis', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Acaia Pyxis',
      );

      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('LUNAR matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'LUNAR',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('PEARL-S matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'PEARL-S',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('PEARLS matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'PEARLS',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('PROCH matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'PROCH',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('PYXIS matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'PYXIS',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('Lunar (mixed case) matches to AcaiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Lunar',
      );
      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('matching is case-insensitive', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'acaia pearl',
      );

      expect(device, isNotNull);
      expect(device, isA<AcaiaScale>());
    });

    test('DE1 exact match', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'DE1',
      );

      expect(device, isA<UnifiedDe1>());
    });

    test('nrf5x matches to DE1', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'nrf5x',
      );

      expect(device, isA<UnifiedDe1>());
    });

    test('de1 prefix matches to DE1', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'de1_something',
      );

      expect(device, isA<UnifiedDe1>());
    });

    test('Bengle exact match', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Bengle',
      );

      expect(device, isA<Bengle>());
    });

    test('Eureka matches to EurekaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Eureka Precisa',
      );

      expect(device, isA<EurekaScale>());
    });

    test('Solo Barista matches to EurekaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Solo Barista',
      );

      expect(device, isA<EurekaScale>());
    });

    test('CFS-9002 matches to EurekaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'CFS-9002',
      );

      expect(device, isA<EurekaScale>());
    });

    test('LSJ-001 matches to EurekaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'LSJ-001',
      );

      expect(device, isA<EurekaScale>());
    });

    test('SmartChef matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'SmartChef Scale',
      );

      expect(device, isA<SmartChefScale>());
    });

    test('Varia matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Varia AKU',
      );

      expect(device, isA<VariaAkuScale>());
    });

    test('AKU matches to VariaAkuScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'AKU',
      );

      expect(device, isA<VariaAkuScale>());
    });

    test('Hiroia matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Hiroia Jimmy',
      );

      expect(device, isA<HiroiaScale>());
    });

    test('Jimmy matches to HiroiaScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Jimmy',
      );

      expect(device, isA<HiroiaScale>());
    });

    test('DiFluid R2 matches reflectometer sensor', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Difluid R2',
      );

      expect(device, isA<DifluidR2Sensor>());
    });

    test('other DiFluid devices still match the scale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Difluid Microbalance',
      );

      expect(device, isA<DifluidScale>());
    });

    test('BlackCoffee prefix matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Black Mirror',
      );

      expect(device, isA<BlackCoffeeScale>());
    });

    test('Atomheart matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Atomheart Eclair',
      );

      expect(device, isA<AtomheartScale>());
    });

    test('Eclair matches to AtomheartScale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Eclair',
      );

      expect(device, isA<AtomheartScale>());
    });

    test('Bookoo matches', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Bookoo Mini',
      );

      expect(device, isA<BookooScale>());
    });

    test('BOOKOO MT80 matches the grinder, not the scale', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'BOOKOO MT80',
      );

      expect(device, isA<BookooGrinder>());
    });

    test('MOTTO80 BLE matches the grinder', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'MOTTO80 BLE',
      );

      expect(device, isA<BookooGrinder>());
    });

    test('serviceUuidsFor grinder contains the MT80 service', () {
      final services = DeviceMatcher.serviceUuidsFor(DeviceType.grinder);

      expect(services, contains('4d543830-0001-4b80-8f00-424f4f4b4f4f'));
    });

    test('returns null for unknown name', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: 'Unknown Device',
      );

      expect(device, isNull);
    });

    test('returns null for empty name', () async {
      final device = await DeviceMatcher.match(
        transport: mockTransport,
        advertisedName: '',
      );

      expect(device, isNull);
    });
  });
}
