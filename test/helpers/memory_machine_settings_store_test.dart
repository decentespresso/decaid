import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';

import 'memory_machine_settings_store.dart';

void main() {
  test(
    'read returns null for an empty identity and records the attempt',
    () async {
      final store = MemoryMachineSettingsStore()
        ..values[''] = const MachineSettings(flowCalibration: 1.5);
      expect(await store.read(''), isNull);
      expect(store.reads, ['']);
    },
  );

  test(
    'update with an empty identity stores nothing and records the attempt',
    () async {
      final store = MemoryMachineSettingsStore();
      await store.update('', flowCalibration: 1.5);
      expect(store.updates, ['']);
      expect(store.values, isEmpty);
      expect(await store.read('serial:12345'), isNull);
    },
  );

  test('clear with an empty identity keeps existing entries', () async {
    final store = MemoryMachineSettingsStore()
      ..values[''] = const MachineSettings(flowCalibration: 9.9);
    await store.update('serial:12345', flowCalibration: 1.25);
    await store.clear('');
    expect(store.clears, ['']);
    expect(store.values, contains('serial:12345'));
    expect(store.values['']?.flowCalibration, 9.9);
  });

  test('clearResetOverrides with an empty identity keeps entries', () async {
    final store = MemoryMachineSettingsStore()
      ..values[''] = const MachineSettings(fanThreshold: 7);
    await store.update('serial:12345', fanThreshold: 42, flowCalibration: 1.25);
    await store.clearResetOverrides('');
    expect(store.resetClears, ['']);
    expect(store.values['serial:12345']?.fanThreshold, 42);
    expect(store.values['serial:12345']?.flowCalibration, 1.25);
    expect(store.values['']?.fanThreshold, 7);
  });

  test('clearResetOverrides without a flow entry removes the entry', () async {
    final store = MemoryMachineSettingsStore();
    await store.update('serial:12345', fanThreshold: 42);
    await store.clearResetOverrides('serial:12345');
    expect(await store.read('serial:12345'), isNull);
  });

  test('update without values stores an entry but reads as absent', () async {
    final store = MemoryMachineSettingsStore();
    final observed = <String>[];
    store.onRead = observed.add;
    await store.update('serial:12345');
    expect(store.values, contains('serial:12345'));
    expect(await store.read('serial:12345'), isNull);
    expect(store.reads, ['serial:12345']);
    expect(observed, ['serial:12345']);
  });

  test('null update arguments preserve the existing entry', () async {
    final store = MemoryMachineSettingsStore();
    await store.update(
      'serial:12345',
      fanThreshold: 42,
      refillKitSetting: De1RefillKitSettings.forceOn,
      flowCalibration: 1.25,
      refillLevel: 12,
    );
    await store.update('serial:12345', fanThreshold: 43);
    final stored = store.values['serial:12345'];
    expect(stored?.fanThreshold, 43);
    expect(stored?.refillKitSetting, De1RefillKitSettings.forceOn);
    expect(stored?.flowCalibration, 1.25);
    expect(stored?.refillLevel, 12);
  });

  test('clear removes only the named entry', () async {
    final store = MemoryMachineSettingsStore();
    await store.update('serial:12345', flowCalibration: 1.25);
    await store.update('serial:54321', flowCalibration: 1.5);
    await store.clear('serial:12345');
    expect(store.values, isNot(contains('serial:12345')));
    expect(store.values['serial:54321']?.flowCalibration, 1.5);
  });

  test('clearResetOverrides keeps only flow and refill level', () async {
    final store = MemoryMachineSettingsStore();
    await store.update(
      'serial:12345',
      fanThreshold: 42,
      refillKitSetting: De1RefillKitSettings.forceOn,
      flowCalibration: 1.25,
      refillLevel: 12,
    );
    await store.clearResetOverrides('serial:12345');
    final stored = store.values['serial:12345'];
    expect(stored?.fanThreshold, isNull);
    expect(stored?.refillKitSetting, isNull);
    expect(stored?.flowCalibration, 1.25);
    expect(stored?.refillLevel, 12);
  });

  test('onRead observes every read identity', () async {
    final store = MemoryMachineSettingsStore();
    final observed = <String>[];
    store.onRead = observed.add;
    await store.update('serial:12345', flowCalibration: 1.25);
    expect((await store.read('serial:12345'))?.flowCalibration, 1.25);
    expect(observed, ['serial:12345']);
  });
}
