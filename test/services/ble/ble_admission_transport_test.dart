import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/services/ble/ble_admission_transport.dart';

import '../../helpers/plugin_ble_fixture.dart';

void main() {
  test(
    'native exclusion lasts until confirmed teardown and stale writes fail',
    () async {
      final registry = PluginBleRegistry();
      final raw = PluginBleFixtureTransport('AA:BB');
      final transport = BleAdmissionTransport(
        transport: raw,
        reserve: () => registry.reserveNative(raw.id),
        release: (claim) => registry.releaseNative(raw.id, claim),
      );
      addTearDown(() async {
        await transport.dispose();
        await registry.dispose();
      });
      await transport.disconnect();
      expect(raw.states.value.name, 'discovered');
      await transport.connect();
      final confirmation = Completer<void>();
      raw.teardown = confirmation;
      final closing = transport.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(registry.isClaimed(raw.id), isTrue);
      expect(() => registry.reserveNative(raw.id), throwsStateError);
      confirmation.complete();
      await closing;
      expect(registry.isClaimed(raw.id), isFalse);
      await expectLater(
        transport.write('180f', '2a19', Uint8List.fromList([1])),
        throwsA(isA<DeviceNotConnectedException>()),
      );
      expect(raw.writes, isEmpty);
      await transport.connect();
      expect(raw.connectCalls, 2);
      expect(registry.isClaimed(raw.id), isTrue);
    },
  );
}
