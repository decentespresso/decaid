import 'package:reaprime/src/models/errors.dart';

const _benignBleErrorCodes = <String>{
  'characteristicNotFound',
  'deviceNotFound',
  'serviceNotFound',
  'connectionTerminated',
  'deviceDisconnected',
  'operationCancelled',
  'unknownError',
};

bool isBenignFrameworkError(Object error) {
  if (error is DeviceNotConnectedException) return true;

  final errorString = error.toString();
  if (errorString.startsWith('UniversalBleException:') ||
      errorString.contains('UniversalBleException:')) {
    for (final code in _benignBleErrorCodes) {
      if (errorString.contains('UniversalBleErrorCode.$code') ||
          errorString.contains('Code: $code')) {
        return true;
      }
    }
  }

  if (errorString.startsWith('PlatformException(') &&
      (errorString.contains('Bonsoir') ||
          errorString.contains('ServiceNotRunning'))) {
    return true;
  }

  return false;
}
