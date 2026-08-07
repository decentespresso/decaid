import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver_service.dart';

class _FakeDevice implements Device {
  @override
  final String deviceId;
  @override
  final String name;
  @override
  final DeviceType type;
  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;
  @override
  TransportType get transportType => TransportType.unknown;
  final ConnectionState _state;
  _FakeDevice(
    this.deviceId,
    this.name,
    this.type, [
    this._state = ConnectionState.connected,
  ]);

  @override
  Stream<ConnectionState> get connectionState => Stream.value(_state);
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
}

void main() {
  group('buildAvailabilityDeviceList', () {
    test('a present device is available:true with its real state', () async {
      final list = await buildAvailabilityDeviceList([
        _FakeDevice('s1', 'Scale', DeviceType.scale, ConnectionState.connected),
      ], const []);
      expect(list, hasLength(1));
      expect(list[0]['id'], 's1');
      expect(list[0]['available'], isTrue);
      expect(list[0]['state'], 'connected');
    });

    test(
      'a remembered-but-absent device is available:false, disconnected',
      () async {
        final list = await buildAvailabilityDeviceList(const [], [
          const RememberedDevice(
            id: 'wifi:hds.local',
            name: 'HDS',
            type: DeviceType.scale,
          ),
        ]);
        expect(list, hasLength(1));
        expect(list[0]['id'], 'wifi:hds.local');
        expect(list[0]['available'], isFalse);
        expect(list[0]['state'], 'disconnected');
        expect(list[0]['type'], 'scale');
      },
    );

    test(
      'a remembered device that IS present is listed once, as available',
      () async {
        final list = await buildAvailabilityDeviceList(
          [_FakeDevice('s1', 'Scale', DeviceType.scale)],
          [
            const RememberedDevice(
              id: 's1',
              name: 'Scale',
              type: DeviceType.scale,
            ),
          ],
        );
        expect(list, hasLength(1));
        expect(list[0]['available'], isTrue);
      },
    );

    test('a non-remembered absent device does not appear', () async {
      final list = await buildAvailabilityDeviceList([
        _FakeDevice('present', 'P', DeviceType.machine),
      ], const []);
      expect(list.map((d) => d['id']), ['present']);
    });

    test('mix: present + remembered-absent', () async {
      final list = await buildAvailabilityDeviceList(
        [_FakeDevice('m1', 'DE1', DeviceType.machine)],
        [
          const RememberedDevice(
            id: 'm1',
            name: 'DE1',
            type: DeviceType.machine,
          ),
          const RememberedDevice(
            id: 's-gone',
            name: 'Scale',
            type: DeviceType.scale,
          ),
        ],
      );
      final byId = {for (final d in list) d['id']: d};
      expect(byId['m1']!['available'], isTrue);
      expect(byId['s-gone']!['available'], isFalse);
    });

    group('ordering', () {
      test('the preferred scale is listed first', () async {
        final list = await buildAvailabilityDeviceList(
          [
            _FakeDevice('zzz', 'Z', DeviceType.machine),
            _FakeDevice('pref', 'Pref scale', DeviceType.scale),
            _FakeDevice('aaa', 'A', DeviceType.scale),
          ],
          const [],
          preferredScaleId: 'pref',
        );
        expect(list.first['id'], 'pref');
      });

      test(
        'order is stable regardless of input order or connection state',
        () async {
          final a = await buildAvailabilityDeviceList(
            [
              _FakeDevice(
                's2',
                'S2',
                DeviceType.scale,
                ConnectionState.connected,
              ),
              _FakeDevice(
                'm1',
                'M1',
                DeviceType.machine,
                ConnectionState.discovered,
              ),
              _FakeDevice(
                's1',
                'S1',
                DeviceType.scale,
                ConnectionState.connected,
              ),
            ],
            const [],
            preferredScaleId: 's1',
          );
          final b = await buildAvailabilityDeviceList(
            [
              _FakeDevice(
                'm1',
                'M1',
                DeviceType.machine,
                ConnectionState.connected,
              ),
              _FakeDevice(
                's1',
                'S1',
                DeviceType.scale,
                ConnectionState.disconnected,
              ),
              _FakeDevice(
                's2',
                'S2',
                DeviceType.scale,
                ConnectionState.discovered,
              ),
            ],
            const [],
            preferredScaleId: 's1',
          );
          expect(
            a.map((d) => d['id']).toList(),
            b.map((d) => d['id']).toList(),
          );
          expect(a.map((d) => d['id']).toList(), ['s1', 'm1', 's2']);
        },
      );

      test('without a preferred scale, order is still deterministic', () async {
        final list = await buildAvailabilityDeviceList([
          _FakeDevice('s2', 'S2', DeviceType.scale),
          _FakeDevice('m1', 'M1', DeviceType.machine),
          _FakeDevice('s1', 'S1', DeviceType.scale),
        ], const []);
        expect(list.map((d) => d['id']).toList(), ['m1', 's1', 's2']);
      });
    });
  });
}
