class BleConnectException implements Exception {
  final String? code;

  final String? description;

  final String? function;

  final Object? cause;

  BleConnectException({this.code, this.description, this.function, this.cause});

  bool get recoveryBlocked =>
      description?.startsWith('RECOVERY_BLOCKED:') ?? false;

  @override
  String toString() =>
      'BleConnectException: '
      '${function ?? 'connect'}'
      '${code != null ? ' (code: $code)' : ''}'
      '${description != null ? ' — $description' : ''}';
}
