class ConnectionErrorKind {
  static const scaleConnectFailed = 'scaleConnectFailed';
  static const machineConnectFailed = 'machineConnectFailed';
  static const sensorConnectFailed = 'sensorConnectFailed';
  static const grinderConnectFailed = 'grinderConnectFailed';
  static const scaleDisconnected = 'scaleDisconnected';
  static const machineDisconnected = 'machineDisconnected';
  static const adapterOff = 'adapterOff';
  static const bluetoothPermissionDenied = 'bluetoothPermissionDenied';
  static const scanFailed = 'scanFailed';

  static const profileUploadFailed = 'profileUploadFailed';

  static const sticky = <String>{
    adapterOff,
    bluetoothPermissionDenied,
    scanFailed,
  };

  static const phasePersistent = <String>{profileUploadFailed};

  const ConnectionErrorKind._();
}

class ConnectionErrorSeverity {
  static const warning = 'warning';
  static const error = 'error';

  const ConnectionErrorSeverity._();
}

class ConnectionError {
  final String kind;
  final String severity;
  final DateTime timestamp;
  final String? deviceId;
  final String? deviceName;
  final String message;
  final String? suggestion;
  final Map<String, dynamic>? details;

  const ConnectionError({
    required this.kind,
    required this.severity,
    required this.timestamp,
    required this.message,
    this.deviceId,
    this.deviceName,
    this.suggestion,
    this.details,
  });

  Map<String, dynamic> toJson() {
    return {
      'kind': kind,
      'severity': severity,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'message': message,
      if (deviceId != null) 'deviceId': deviceId,
      if (deviceName != null) 'deviceName': deviceName,
      if (suggestion != null) 'suggestion': suggestion,
      if (details != null) 'details': details,
    };
  }
}
