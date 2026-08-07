import 'package:reaprime/src/models/errors.dart';

/// Expected universal_ble errors that are already handled by the transport.
/// When these escape to the framework error handler (e.g., from a
/// fire-and-forget timer callback or a cancelled queue item), they are not
/// crash signals. Gone-device errors trigger disconnect cleanup;
/// `operationCancelled` is a local queue-recovery result.
const _benignBleErrorCodes = <String>{
  'characteristicNotFound',
  'deviceNotFound',
  'serviceNotFound',
  'connectionTerminated',
  'deviceDisconnected',
  'operationCancelled',
  'unknownError',
};

/// Returns `true` if [error] is a known-benign exception that should NOT be
/// recorded as a Crashlytics FATAL.
///
/// These are exceptions that are part of the codebase's normal error model —
/// they are caught and handled by upper layers, but can escape to the
/// framework's global error handler (`FlutterError.onError` or
/// `PlatformDispatcher.instance.onError`) from fire-and-forget contexts
/// (Timer.periodic callbacks, unawaited Futures). Recording them as FATAL
/// pollutes Crashlytics with false crash signals (see `fa51312d`,
/// `eeea9be0`).
///
/// This is the framework-level safety net — the last line of defence.
/// Individual device implementations should still catch these at their
/// write/heartbeat level for graceful recovery.
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
