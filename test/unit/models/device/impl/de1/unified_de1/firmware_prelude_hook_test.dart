import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _FwHookProbe extends UnifiedDe1 {
  _FwHookProbe({required super.transport});

  bool hookCalled = false;

  int writeCountAtHook = -1;

  late FakeBleTransport probeTransport;

  @override
  @protected
  Future<void> beforeFirmwareUpload() async {
    hookCalled = true;
    writeCountAtHook = probeTransport.writes.length;
  }
}

void main() {
  group('beforeFirmwareUpload hook', () {
    test('UnifiedDe1.beforeFirmwareUpload defaults to no-op', () async {
      final transport = FakeBleTransport();
      addTearDown(transport.dispose);
      final de1 = UnifiedDe1(transport: transport);
      // ignore: invalid_use_of_protected_member
      await de1.beforeFirmwareUpload();
      expect(transport.writes, isEmpty);
    });

    test('subclass override is invoked by the FW upload path', () async {
      final transport = FakeBleTransport();
      addTearDown(transport.dispose);
      transport.queueOnConnectResponses();

      final de1 = _FwHookProbe(transport: transport);
      de1.probeTransport = transport;
      await de1.onConnect();

      final preFwWrites = transport.writes.length;

      try {
        await de1
            .updateFirmware(Uint8List(0), onProgress: (_) {})
            .timeout(const Duration(seconds: 1));
      } on TimeoutException catch (_) {}

      expect(
        de1.hookCalled,
        isTrue,
        reason:
            'beforeFirmwareUpload hook was not invoked '
            'by the FW upload path',
      );

      expect(
        de1.writeCountAtHook,
        greaterThan(preFwWrites),
        reason: 'hook fired before requestState(sleeping) wrote to wire',
      );
      final fwPreludeWrites = transport.writes.sublist(preFwWrites);
      expect(
        fwPreludeWrites.first.characteristicUUID,
        Endpoint.requestedState.uuid,
        reason: 'first FW-path write must be requestState(sleeping)',
      );
    });
  });
}
