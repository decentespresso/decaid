import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/services/ble/ble_exception_mapper.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  group('mapUniversalConnectError', () {
    test('deferred native recovery block remains classified', () {
      final error =
          mapUniversalConnectError(
                ConnectionException(
                  'CONNECT_START_FAILED: RECOVERY_BLOCKED: unresolved native GATT teardown',
                ),
              )
              as BleConnectException;

      expect(error.recoveryBlocked, isTrue);
    });

    test('connectionTimeout becomes BleTimeoutException', () {
      final mapped = mapUniversalConnectError(
        UniversalBleException(
          code: UniversalBleErrorCode.connectionTimeout,
          message: 'timed out',
        ),
      );

      expect(mapped, isA<BleTimeoutException>());
    });

    test('other codes become BleConnectException with code name', () {
      final mapped = mapUniversalConnectError(
        UniversalBleException(
          code: UniversalBleErrorCode.connectionFailed,
          message: 'nope',
        ),
      );

      expect(mapped, isA<BleConnectException>());
      final e = mapped as BleConnectException;
      expect(e.code, 'connectionFailed');
      expect(e.description, 'nope');
      expect(e.function, 'connect');
      expect(e.cause, isA<UniversalBleException>());
    });
  });
}
