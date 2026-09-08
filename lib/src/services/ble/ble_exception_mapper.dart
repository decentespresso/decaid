import 'dart:async';

import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:universal_ble/universal_ble.dart';

String bleBridgeErrorCode(Object error) => switch (error) {
  GattAttributeUnavailableException() => 'attribute_unavailable',
  DeviceNotConnectedException() => 'link_lost',
  PermissionDeniedException() => 'permission_denied',
  TimeoutException() || BleTimeoutException() => 'timeout',
  UniversalBleException() => error.code.name,
  BleConnectException() => error.code ?? 'ble_error',
  _ => 'ble_error',
};

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
