class BleTimeoutException implements Exception {
  final String operation;
  final Object? cause;

  BleTimeoutException(this.operation, [this.cause]);

  @override
  String toString() =>
      'BleTimeoutException: $operation timed out'
      '${cause != null ? ' (cause: $cause)' : ''}';
}
