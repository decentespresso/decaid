import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:universal_ble/universal_ble.dart';

Object mapUniversalConnectError(UniversalBleException e) {
  if (e.code == UniversalBleErrorCode.connectionTimeout) {
    return BleTimeoutException('connect', e);
  }
  return BleConnectException(
    code: e.code.name,
    description: e.message,
    function: 'connect',
    cause: e,
  );
}
