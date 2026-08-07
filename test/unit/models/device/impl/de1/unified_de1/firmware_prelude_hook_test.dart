import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _FwHookProbe extends UnifiedDe1 {
  _FwHookProbe({required super.transport});

  bool hookCalled = false;

  /// Number of writes captured at the moment the hook fires. Lets a test
  /// assert ordering relative to `requestState(sleeping)` without driving
  /// the full FW protocol.
  int writeCountAtHook = -1;

  /// Set by tests to read the underlying transport's write log when the
  /// hook fires.
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
      // The default implementation must complete without side effects.
      // Tests live in the same package; @protected lint is irrelevant here.
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
      } on TimeoutException catch (_) {
        // Expected: no erase response arrives.
      }

      expect(
        de1.hookCalled,
        isTrue,
        reason:
            'beforeFirmwareUpload hook was not invoked '
            'by the FW upload path',
      );

      // The hook must fire AFTER requestState(sleeping) — i.e., at least
      // one write to Endpoint.requestedState must have landed on the
      // wire before hookCalled flipped.
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
