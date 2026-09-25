class PermissionDeniedException implements Exception {
  final String? message;
  const PermissionDeniedException([this.message]);

  @override
  String toString() => message == null
      ? 'PermissionDeniedException'
      : 'PermissionDeniedException: $message';
}

enum DeviceKind { machine, scale, grinder, unknown }

class DeviceNotConnectedException implements Exception {
  final DeviceKind kind;

  const DeviceNotConnectedException(this.kind);
  const DeviceNotConnectedException.machine() : kind = DeviceKind.machine;
  const DeviceNotConnectedException.scale() : kind = DeviceKind.scale;
  const DeviceNotConnectedException.grinder() : kind = DeviceKind.grinder;
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
