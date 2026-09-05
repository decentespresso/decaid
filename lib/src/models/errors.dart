class PermissionDeniedException implements Exception {
  final String? message;
  const PermissionDeniedException([this.message]);

  @override
  String toString() => message == null
      ? 'PermissionDeniedException'
      : 'PermissionDeniedException: $message';
}

enum DeviceKind { machine, scale, unknown }

class DeviceNotConnectedException implements Exception {
  final DeviceKind kind;

  const DeviceNotConnectedException(this.kind);
  const DeviceNotConnectedException.machine() : kind = DeviceKind.machine;
  const DeviceNotConnectedException.scale() : kind = DeviceKind.scale;
  const DeviceNotConnectedException.unknown() : kind = DeviceKind.unknown;

  @override
  String toString() =>
      'DeviceNotConnectedException: ${kind.name} not connected';
}

class GattAttributeUnavailableException extends DeviceNotConnectedException {
  final String operation;
  final String path;

  const GattAttributeUnavailableException({
    required this.operation,
    required this.path,
  }) : super(DeviceKind.unknown);

  @override
  String toString() =>
      'GattAttributeUnavailableException: $operation($path) not in the '
      'GATT database';
}

class DeviceIdentityMismatchException implements Exception {
  final String expected;
  final int actualModelValue;

  const DeviceIdentityMismatchException({
    required this.expected,
    required this.actualModelValue,
  });

  @override
  String toString() =>
      'DeviceIdentityMismatchException: expected $expected, got v13Model=$actualModelValue';
}

class DuplicateBleSubscription implements Exception {
  final String anonymizedDeviceId;

  const DuplicateBleSubscription(this.anonymizedDeviceId);

  @override
  String toString() =>
      'DuplicateBleSubscription: BLE setup re-run on already-connected '
      'transport ($anonymizedDeviceId)';
}

class EndpointUnavailableException implements Exception {
  final String endpointName;
  final Duration timeout;

  const EndpointUnavailableException(this.endpointName, this.timeout);

  @override
  String toString() =>
      'EndpointUnavailableException: no $endpointName frame within $timeout';
}

class MmrTimeoutException implements Exception {
  final String mmrItemName;
  final Duration timeout;

  const MmrTimeoutException(this.mmrItemName, this.timeout);

  @override
  String toString() =>
      'MmrTimeoutException: no response for $mmrItemName within $timeout';
}

class MachineReplacementTimeoutException implements Exception {
  final Duration timeout;

  const MachineReplacementTimeoutException(this.timeout);

  @override
  String toString() =>
      'MachineReplacementTimeoutException: no replacement machine '
      'within $timeout';
}

class De1WriteQueueFullException implements Exception {
  final int maxPendingWrites;

  const De1WriteQueueFullException(this.maxPendingWrites);

  @override
  String toString() =>
      'De1WriteQueueFullException: maximum $maxPendingWrites pending writes';
}

class De1WriteSupersededException implements Exception {
  final String key;

  const De1WriteSupersededException(this.key);

  @override
  String toString() => 'De1WriteSupersededException: $key was superseded';
}

class FirmwareUpdateInProgressException implements Exception {
  @override
  String toString() =>
      'FirmwareUpdateInProgressException: a firmware '
      'update is already in progress';
}

class FirmwareUpdateCancelledException implements Exception {
  const FirmwareUpdateCancelledException();

  @override
  String toString() =>
      'FirmwareUpdateCancelledException: firmware update '
      'was cancelled';
}

class FirmwareImageValidationException implements Exception {
  final String reason;

  const FirmwareImageValidationException(this.reason);

  @override
  String toString() => 'FirmwareImageValidationException: $reason';
}

/// Thrown by `UnifiedDe1._assertProfileModeSupported` when a profile using a
/// per-frame Power/Lever pump mode or a HOLD transition is uploaded to a
/// machine that cannot run it — either the connected device is not a Bengle
/// (the modes are protocol-v2 by definition), or its firmware did not advertise
/// the matching ProfileModeCaps bit.
///
/// This refusal is PERMANENT for a given connection: the capability cannot
/// appear without a firmware update followed by a reconnect, so callers must
/// PARK on it rather than retry (`WorkflowDeviceSync` catches this type
/// specifically and stops retrying). The REST boundary maps it to a clean 400
/// with [message]; a generic `StateError` from elsewhere stays a 500.
class ProfileModeUnsupportedException implements Exception {
  final String message;

  const ProfileModeUnsupportedException(this.message);

  @override
  String toString() => 'ProfileModeUnsupportedException: $message';
}
