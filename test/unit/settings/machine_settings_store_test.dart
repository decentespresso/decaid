import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists values across store instances', () async {
    final first = SharedPreferencesMachineSettingsStore();
    await first.update(
      'serial:one',
      fanThreshold: 42,
      refillKitSetting: De1RefillKitSettings.forceOn,
    );

    final restarted = SharedPreferencesMachineSettingsStore();
    expect(
      await restarted.read('serial:one'),
      const TypeMatcher<MachineSettings>(),
    );
    final settings = await restarted.read('serial:one');
    expect(settings?.fanThreshold, 42);
    expect(settings?.refillKitSetting, De1RefillKitSettings.forceOn);
  });

  test('does not create a bucket for an unknown identity', () async {
    final store = SharedPreferencesMachineSettingsStore();
    await store.update('', fanThreshold: 42);
    expect(await store.read(''), isNull);
    expect(await store.read('serial:known'), isNull);
  });

  test('evicts the oldest-updated machine after 32 entries', () async {
    final store = SharedPreferencesMachineSettingsStore();
    for (var i = 0; i < 32; i++) {
      await store.update('serial:$i', fanThreshold: i);
    }
    await store.update('serial:32', fanThreshold: 32);
    expect(await store.read('serial:0'), isNull);
    expect((await store.read('serial:32'))?.fanThreshold, 32);
  });

  test('updating a machine protects it from oldest eviction', () async {
    final store = SharedPreferencesMachineSettingsStore();
    for (var i = 0; i < 32; i++) {
      await store.update('serial:$i', fanThreshold: i);
    }
    await store.update('serial:0', fanThreshold: 100);
    await store.update('serial:32', fanThreshold: 32);

    expect((await store.read('serial:0'))?.fanThreshold, 100);
    expect(await store.read('serial:1'), isNull);
  });

  test('clear removes only the requested machine', () async {
    final store = SharedPreferencesMachineSettingsStore();
    await store.update('serial:one', fanThreshold: 42);
    await store.update('serial:two', fanThreshold: 43);

    await store.clear('serial:one');

    expect(await store.read('serial:one'), isNull);
    expect((await store.read('serial:two'))?.fanThreshold, 43);
  });
}
