import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';

import '../../helpers/mock_settings_service.dart';

void main() {
  late StreamController<RememberedDevice?> machine;
  late StreamController<RememberedDevice?> scale;
  late MockSettingsService settings;
  late RememberedDevicesController controller;

  setUp(() {
    machine = StreamController<RememberedDevice?>.broadcast();
    scale = StreamController<RememberedDevice?>.broadcast();
    settings = MockSettingsService();
  });

  RememberedDevicesController build() => RememberedDevicesController(
    machineConnections: machine.stream,
    scaleConnections: scale.stream,
    settings: settings,
  );

  tearDown(() async {
    await controller.dispose();
    await machine.close();
    await scale.close();
  });

  test('connecting a machine remembers it and persists', () async {
    controller = build();
    await controller.initialize();

    machine.add(
      const RememberedDevice(
        id: 'de1-1',
        name: 'DE1',
        type: DeviceType.machine,
      ),
    );
    await Future.delayed(Duration.zero);

    expect(controller.remembered.map((d) => d.id), ['de1-1']);
    expect(
      RememberedDevice.decodeList(
        await settings.rememberedDevices(),
      ).map((d) => d.id),
      ['de1-1'],
    );
  });

  test('connecting a scale remembers it', () async {
    controller = build();
    await controller.initialize();

    scale.add(
      const RememberedDevice(
        id: 'wifi:hds.local',
        name: 'HDS (WiFi)',
        type: DeviceType.scale,
      ),
    );
    await Future.delayed(Duration.zero);

    expect(controller.remembered.single.id, 'wifi:hds.local');
    expect(controller.remembered.single.type, DeviceType.scale);
  });

  test('a null emission (disconnect) does NOT remember/forget', () async {
    controller = build();
    await controller.initialize();

    scale.add(
      const RememberedDevice(id: 's', name: 'S', type: DeviceType.scale),
    );
    await Future.delayed(Duration.zero);
    scale.add(null);
    await Future.delayed(Duration.zero);

    expect(
      controller.remembered.map((d) => d.id),
      ['s'],
      reason: 'disconnect keeps it remembered',
    );
  });

  test('registry restores from settings on init', () async {
    await settings.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(id: 'a', name: 'A', type: DeviceType.scale),
        const RememberedDevice(id: 'b', name: 'B', type: DeviceType.machine),
      ]),
    );
    controller = build();
    await controller.initialize();

    expect(controller.remembered.map((d) => d.id).toSet(), {'a', 'b'});
  });

  test('forget removes and persists', () async {
    await settings.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(id: 'a', name: 'A', type: DeviceType.scale),
      ]),
    );
    controller = build();
    await controller.initialize();

    await controller.forget('a');
    expect(controller.remembered, isEmpty);
    expect(
      RememberedDevice.decodeList(await settings.rememberedDevices()),
      isEmpty,
    );
  });

  test('forget is a no-op for an unknown id', () async {
    controller = build();
    await controller.initialize();
    await controller.forget('nope'); // must not throw
    expect(controller.remembered, isEmpty);
  });

  test('re-remembering with a new name updates the entry', () async {
    controller = build();
    await controller.initialize();

    scale.add(
      const RememberedDevice(id: 's', name: 'Old', type: DeviceType.scale),
    );
    await Future.delayed(Duration.zero);
    scale.add(
      const RememberedDevice(id: 's', name: 'New', type: DeviceType.scale),
    );
    await Future.delayed(Duration.zero);

    expect(controller.remembered.single.name, 'New');
  });

  test(
    'reconnecting with identical metadata does not re-persist or re-emit',
    () async {
      controller = build();
      await controller.initialize();
      final emissions = <int>[];
      final sub = controller.changes.listen((l) => emissions.add(l.length));

      const device = RememberedDevice(
        id: 's',
        name: 'S',
        type: DeviceType.scale,
      );
      scale.add(device);
      await Future.delayed(Duration.zero);
      final writesAfterFirst = settings.rememberedDevicesWriteCount;

      // Identical reconnect (BLE drop/reconnect storm) must be a no-op.
      scale.add(device);
      await Future.delayed(Duration.zero);

      expect(
        settings.rememberedDevicesWriteCount,
        writesAfterFirst,
        reason: 'an identical reconnect must not persist again',
      );
      // seeded [] (0) + one emission for the first remember (1); no second.
      expect(emissions, [0, 1]);
      await sub.cancel();
    },
  );

  test('the same physical scale on two transports yields two entries', () async {
    // The WiFi/USB/BLE views of one physical HDS have distinct deviceIds and
    // are intentionally NOT merged — each transport is its own remembered entry.
    controller = build();
    await controller.initialize();

    scale.add(
      const RememberedDevice(
        id: 'wifi:hds.local',
        name: 'HDS',
        type: DeviceType.scale,
      ),
    );
    scale.add(
      const RememberedDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'HDS',
        type: DeviceType.scale,
      ),
    );
    await Future.delayed(Duration.zero);

    expect(
      controller.remembered.map((d) => d.id).toSet(),
      {'wifi:hds.local', 'AA:BB:CC:DD:EE:FF'},
      reason: 'same name, distinct ids → distinct entries',
    );
  });

  test(
    'a failed persist on the connect path is contained and rolled back',
    () async {
      controller = build();
      await controller.initialize();
      settings.failRememberedDevicesWrite = true;

      // A throwing persist on the un-awaited stream path must be caught (logged in
      // _persist) — if it leaked as an unhandled async error the test zone would
      // fail. The registry rolls back so memory matches disk (nothing persisted),
      // and the device self-heals on the next connect.
      scale.add(
        const RememberedDevice(id: 's', name: 'S', type: DeviceType.scale),
      );
      await Future.delayed(Duration.zero);

      expect(
        controller.remembered,
        isEmpty,
        reason: 'a failed persist rolls back the in-memory add',
      );
    },
  );

  test('forget surfaces a persist failure and rolls back', () async {
    await settings.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(id: 'a', name: 'A', type: DeviceType.scale),
      ]),
    );
    controller = build();
    await controller.initialize();
    settings.failRememberedDevicesWrite = true;

    await expectLater(
      controller.forget('a'),
      throwsA(isA<StateError>()),
      reason: 'the awaitable forget path must not swallow a persist failure',
    );
    expect(
      controller.remembered.map((d) => d.id),
      ['a'],
      reason: 'a failed persist rolls back the removal (memory matches disk)',
    );
  });

  test(
    'initialize is idempotent (no double-subscribe / double-load)',
    () async {
      controller = build();
      await controller.initialize();
      await controller.initialize(); // second call must be a no-op

      final emissions = <int>[];
      final sub = controller.changes.listen((l) => emissions.add(l.length));
      scale.add(
        const RememberedDevice(id: 's', name: 'S', type: DeviceType.scale),
      );
      await Future.delayed(Duration.zero);

      expect(controller.remembered.map((d) => d.id), ['s']);
      expect(emissions, [0, 1]);
      await sub.cancel();
    },
  );

  test(
    'a partially-malformed stored list loads only the valid records',
    () async {
      // One valid record + one missing required fields (dropped).
      await settings.setRememberedDevices(
        '[{"id":"a","name":"A","type":"scale"},{"id":"b"}]',
      );
      controller = build();
      await controller.initialize();

      expect(
        controller.remembered.map((d) => d.id),
        ['a'],
        reason: 'an unreadable record must not abort the whole load',
      );
    },
  );

  test('changes stream emits on remember and forget', () async {
    controller = build();
    await controller.initialize();
    final emissions = <int>[];
    final sub = controller.changes.listen((l) => emissions.add(l.length));

    machine.add(
      const RememberedDevice(id: 'm', name: 'M', type: DeviceType.machine),
    );
    await Future.delayed(Duration.zero);
    await controller.forget('m');
    await Future.delayed(Duration.zero);

    // seeded [] (0), after remember (1), after forget (0)
    expect(emissions, containsAllInOrder([0, 1, 0]));
    await sub.cancel();
  });
}
