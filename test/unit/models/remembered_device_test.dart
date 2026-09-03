import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/device_matcher.dart';

class _RealDevice implements Device {
  @override
  final String deviceId;
  @override
  final String name;
  @override
  final DeviceType type;
  @override
  final DeviceImplementation implementation;
  @override
  final TransportType transportType;
  _RealDevice(
    this.deviceId,
    this.name,
    this.type, {
    this.implementation = DeviceImplementation.unifiedDe1,
    this.transportType = TransportType.unknown,
  });
  @override
  Stream<ConnectionState> get connectionState => const Stream.empty();
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
}

class _MockDevice extends _RealDevice implements SimulatedDevice {
  _MockDevice(super.id, super.name, super.type);
}

void main() {
  group('RememberedDevice.fromDevice', () {
    test('builds a record from a real device', () {
      final r = RememberedDevice.fromDevice(
        _RealDevice('wifi:hds.local', 'HDS', DeviceType.scale),
      );
      expect(r, isNotNull);
      expect(r!.id, 'wifi:hds.local');
      expect(r.type, DeviceType.scale);
    });

    test('returns null for a simulated device (never remembered)', () {
      expect(
        RememberedDevice.fromDevice(
          _MockDevice('MockScale', 'Mock Scale', DeviceType.scale),
        ),
        isNull,
      );
    });
  });

  group('RememberedDevice', () {
    test('toJson/fromJson round-trips', () {
      const d = RememberedDevice(
        id: 'wifi:hds.local',
        name: 'Half Decent Scale (WiFi)',
        type: DeviceType.scale,
      );
      final back = RememberedDevice.fromJson(d.toJson());
      expect(back, isNotNull);
      expect(back!.id, d.id);
      expect(back.name, d.name);
      expect(back.type, DeviceType.scale);
    });

    test('fromJson rejects malformed / unknown type / empty id', () {
      expect(RememberedDevice.fromJson({'id': 'x'}), isNull);
      expect(
        RememberedDevice.fromJson({
          'id': 'x',
          'name': 'n',
          'type': 'spaceship',
        }),
        isNull,
      );
      expect(
        RememberedDevice.fromJson({'id': 1, 'name': 'n', 'type': 'scale'}),
        isNull,
      );
      expect(
        RememberedDevice.fromJson({'id': '', 'name': 'n', 'type': 'scale'}),
        isNull,
      );
    });

    test('sameMetadata compares name, type, implementation, transportType', () {
      const a = RememberedDevice(
        id: 'a',
        name: 'N',
        type: DeviceType.scale,
        implementation: DeviceImplementation.decentScale,
        transportType: TransportType.ble,
      );
      const sameMeta = RememberedDevice(
        id: 'different',
        name: 'N',
        type: DeviceType.scale,
        implementation: DeviceImplementation.decentScale,
        transportType: TransportType.ble,
      );
      const renamed = RememberedDevice(
        id: 'a',
        name: 'Other',
        type: DeviceType.scale,
        implementation: DeviceImplementation.decentScale,
        transportType: TransportType.ble,
      );
      const differentImpl = RememberedDevice(
        id: 'a',
        name: 'N',
        type: DeviceType.scale,
        implementation: DeviceImplementation.skale2,
        transportType: TransportType.ble,
      );
      const differentTransport = RememberedDevice(
        id: 'a',
        name: 'N',
        type: DeviceType.scale,
        implementation: DeviceImplementation.decentScale,
        transportType: TransportType.wifi,
      );
      expect(a.sameMetadata(sameMeta), isTrue);
      expect(a.sameMetadata(renamed), isFalse);
      expect(a.sameMetadata(differentImpl), isFalse);
      expect(a.sameMetadata(differentTransport), isFalse);
    });

    test('storedCount counts stored records before validity filtering', () {
      const json = '[{"id":"a","name":"A","type":"scale"},{"id":"b"}]';
      expect(RememberedDevice.storedCount(json), 2);
      expect(RememberedDevice.decodeList(json), hasLength(1));
      expect(RememberedDevice.storedCount('not json'), 0);
      expect(RememberedDevice.storedCount('{}'), 0);
    });

    test('encodeList/decodeList round-trips a list', () {
      final list = [
        const RememberedDevice(id: 'a', name: 'DE1', type: DeviceType.machine),
        const RememberedDevice(id: 'b', name: 'Scale', type: DeviceType.scale),
      ];
      final decoded = RememberedDevice.decodeList(
        RememberedDevice.encodeList(list),
      );
      expect(decoded.map((d) => d.id).toList(), ['a', 'b']);
      expect(decoded[0].type, DeviceType.machine);
    });

    test('decodeList tolerates malformed input', () {
      expect(RememberedDevice.decodeList(''), isEmpty);
      expect(RememberedDevice.decodeList('not json'), isEmpty);
      expect(RememberedDevice.decodeList('{}'), isEmpty);
      final mixed = '[{"id":"a","name":"A","type":"scale"},{"id":"b"}]';
      expect(RememberedDevice.decodeList(mixed).map((d) => d.id).toList(), [
        'a',
      ]);
    });

    test('equality is by id', () {
      const a1 = RememberedDevice(id: 'a', name: 'A', type: DeviceType.scale);
      const a2 = RememberedDevice(
        id: 'a',
        name: 'Renamed',
        type: DeviceType.machine,
      );
      const b = RememberedDevice(id: 'b', name: 'B', type: DeviceType.scale);
      expect(a1, a2);
      expect(a1, isNot(b));
      expect({a1, a2, b}.length, 2);
    });
  });

  group('RememberedDevice enrichment (implementation + transportType)', () {
    test('fromDevice captures implementation and transportType', () {
      final r = RememberedDevice.fromDevice(
        _RealDevice(
          'D9:11:0B:E6:9F:86',
          'DE1',
          DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.ble,
        ),
      );
      expect(r, isNotNull);
      expect(r!.implementation, DeviceImplementation.unifiedDe1);
      expect(r.transportType, TransportType.ble);
    });

    test('toJson includes implementation and transportType when present', () {
      const d = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.ble,
      );
      final json = d.toJson();
      expect(json['implementation'], 'unifiedDe1');
      expect(json['transportType'], 'ble');
    });

    test('toJson omits implementation and transportType when null', () {
      const d = RememberedDevice(
        id: 'a',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final json = d.toJson();
      expect(json.containsKey('implementation'), isFalse);
      expect(json.containsKey('transportType'), isFalse);
    });

    test('fromJson reads implementation and transportType', () {
      final r = RememberedDevice.fromJson({
        'id': 'a',
        'name': 'DE1',
        'type': 'machine',
        'implementation': 'bengle',
        'transportType': 'ble',
      });
      expect(r, isNotNull);
      expect(r!.implementation, DeviceImplementation.bengle);
      expect(r.transportType, TransportType.ble);
    });

    test(
      'fromJson tolerates missing implementation and transportType (old records)',
      () {
        final r = RememberedDevice.fromJson({
          'id': 'a',
          'name': 'DE1',
          'type': 'machine',
        });
        expect(r, isNotNull);
        expect(r!.implementation, isNull);
        expect(r.transportType, isNull);
      },
    );

    test('fromJson tolerates unknown implementation name (graceful null)', () {
      final r = RememberedDevice.fromJson({
        'id': 'a',
        'name': 'DE1',
        'type': 'machine',
        'implementation': 'nonexistentDevice',
      });
      expect(r, isNotNull);
      expect(r!.implementation, isNull);
    });

    test('round-trip preserves implementation and transportType', () {
      const d = RememberedDevice(
        id: 'wifi:hds.local',
        name: 'HDS',
        type: DeviceType.scale,
        implementation: DeviceImplementation.hdsWifi,
        transportType: TransportType.wifi,
      );
      final back = RememberedDevice.fromJson(d.toJson());
      expect(back, isNotNull);
      expect(back!.implementation, DeviceImplementation.hdsWifi);
      expect(back.transportType, TransportType.wifi);
    });
  });

  group('RememberedDevice.migrate', () {
    test('infers implementation from name when null', () {
      const old = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final migrated = old.migrate((name) {
        expect(name, 'DE1');
        return DeviceImplementation.unifiedDe1;
      });
      expect(migrated.implementation, DeviceImplementation.unifiedDe1);
    });

    test('infers transportType from deviceId when null (MAC → ble)', () {
      const old = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.transportType, TransportType.ble);
    });

    test('infers transportType from deviceId when null (wifi: → wifi)', () {
      const old = RememberedDevice(
        id: 'wifi:hds.local',
        name: 'HDS',
        type: DeviceType.scale,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.transportType, TransportType.wifi);
    });

    test('infers transportType from deviceId when null (serial- → serial)', () {
      const old = RememberedDevice(
        id: 'serial-ttyUSB0',
        name: 'HDS',
        type: DeviceType.scale,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.transportType, TransportType.serial);
    });

    test('infers transportType from deviceId when null (usb- → serial)', () {
      const old = RememberedDevice(
        id: 'usb-1a86-7523-serial123',
        name: 'HDS',
        type: DeviceType.scale,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.transportType, TransportType.serial);
    });

    test('does not override existing implementation', () {
      const old = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.bengle,
      );
      final migrated = old.migrate((_) => DeviceImplementation.unifiedDe1);
      expect(migrated.implementation, DeviceImplementation.bengle);
    });

    test('does not override existing transportType', () {
      const old = RememberedDevice(
        id: 'wifi:hds.local',
        name: 'HDS',
        type: DeviceType.scale,
        transportType: TransportType.ble,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.transportType, TransportType.ble);
    });

    test('migrate with DeviceMatcher.implementationForName — DE1', () {
      const old = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final migrated = old.migrate((name) {
        if (name == 'DE1') return DeviceImplementation.unifiedDe1;
        return null;
      });
      expect(migrated.implementation, DeviceImplementation.unifiedDe1);
      expect(migrated.transportType, TransportType.ble);
    });

    test('migrate with UUID id (iOS/macOS BLE) infers ble', () {
      const old = RememberedDevice(
        id: '12345678-1234-1234-1234-123456789ABC',
        name: 'Decent Scale',
        type: DeviceType.scale,
      );
      final migrated = old.migrate((_) => DeviceImplementation.decentScale);
      expect(migrated.transportType, TransportType.ble);
    });

    test('preserves id, name, type', () {
      const old = RememberedDevice(
        id: 'D9:11:0B:E6:9F:86',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final migrated = old.migrate((_) => null);
      expect(migrated.id, old.id);
      expect(migrated.name, old.name);
      expect(migrated.type, old.type);
    });
  });

  group('DeviceMatcher.implementationForName', () {
    test('DE1 → unifiedDe1', () {
      expect(
        DeviceMatcher.implementationForName('DE1'),
        DeviceImplementation.unifiedDe1,
      );
    });

    test('Bengle → bengle', () {
      expect(
        DeviceMatcher.implementationForName('Bengle'),
        DeviceImplementation.bengle,
      );
    });

    test('Decent Scale → decentScale', () {
      expect(
        DeviceMatcher.implementationForName('Decent Scale'),
        DeviceImplementation.decentScale,
      );
    });

    test('Skale2 → skale2', () {
      expect(
        DeviceMatcher.implementationForName('Skale2'),
        DeviceImplementation.skale2,
      );
    });

    test('Acaia Lunar → acaiaScale', () {
      expect(
        DeviceMatcher.implementationForName('Lunar'),
        DeviceImplementation.acaiaScale,
      );
    });

    test('TIMEMORE DOT → timemoreDot', () {
      expect(
        DeviceMatcher.implementationForName('TIMEMORE DOT'),
        DeviceImplementation.timemoreDot,
      );
    });

    test('TES017 → timemoreDot', () {
      expect(
        DeviceMatcher.implementationForName('TES017'),
        DeviceImplementation.timemoreDot,
      );
    });

    test('unknown name → null', () {
      expect(DeviceMatcher.implementationForName('Unknown Device'), isNull);
    });
  });
}
