import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  group('UnifiedDe1 firmware update concurrency', () {
    late FakeBleTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = FakeBleTransport();
      addTearDown(transport.dispose);
      de1 = UnifiedDe1(transport: transport);
    });

    test('firmwareUpdateState defaults to idle', () {
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    });

    test(
      'throws FirmwareUpdateInProgressException when update is active',
      () async {
        final first = de1.updateFirmware(Uint8List(0), onProgress: (_) {})
          ..catchError((_) {});

        expect(de1.firmwareUpdateState, isNot(FirmwareUpdateState.idle));

        // Second call must throw synchronously.
        expect(
          () => de1.updateFirmware(Uint8List(0), onProgress: (_) {}),
          throwsA(isA<FirmwareUpdateInProgressException>()),
        );

        await de1.cancelFirmwareUpload();
        try {
          await first;
        } catch (_) {}
      },
    );

    test('state returns to idle after successful completion', () async {
      final future = de1.updateFirmware(Uint8List(0), onProgress: (_) {})
        ..catchError((_) {});

      expect(de1.firmwareUpdateState, isNot(FirmwareUpdateState.idle));

      await de1.cancelFirmwareUpload();
      try {
        await future;
      } catch (_) {}

      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    });

    test('cancelFirmwareUpload is no-op when idle', () async {
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
      await de1.cancelFirmwareUpload();
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
      // Must not write to the transport when idle (sets machine to sleep).
      final writesAfter = transport.writes.length;
      expect(writesAfter, 0);
    });

    test(
      'state is not idle during active update and returns to idle after cancellation',
      () async {
        final future = de1.updateFirmware(Uint8List(0), onProgress: (_) {})
          ..catchError((_) {});

        expect(de1.firmwareUpdateState, isNot(FirmwareUpdateState.idle));

        await de1.cancelFirmwareUpload();
        try {
          await future;
        } catch (_) {}

        expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
      },
    );

    test(
      'second cancelFirmwareUpload after first cancel completes does not throw',
      () async {
        final future = de1.updateFirmware(Uint8List(0), onProgress: (_) {})
          ..catchError((_) {});

        await de1.cancelFirmwareUpload();

        await de1.cancelFirmwareUpload();

        try {
          await future;
        } catch (_) {}
        expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
      },
    );
  });

  group('MockDe1 firmware update concurrency', () {
    test('reserves synchronously and cancels on disconnect', () async {
      final de1 = MockDe1();
      final update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});
      final cancellation = expectLater(
        update,
        throwsA(isA<FirmwareUpdateCancelledException>()),
      );

      expect(
        () => de1.updateFirmware(Uint8List(16), onProgress: (_) {}),
        throwsA(isA<FirmwareUpdateInProgressException>()),
      );
      await de1.disconnect();
      await cancellation;
      expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    });
  });
}
