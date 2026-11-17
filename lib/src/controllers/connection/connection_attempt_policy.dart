class ConnectionAttemptPolicy {
  final bool directRememberedMachine;
  final bool connectPreferredDuringScan;
  final bool stopScanAfterPreferredConnect;
  final bool stopBeforePreferredScaleConnect;

  const ConnectionAttemptPolicy._({
    required this.directRememberedMachine,
    required this.connectPreferredDuringScan,
    required this.stopScanAfterPreferredConnect,
    this.stopBeforePreferredScaleConnect = false,
  });

  static const automatic = ConnectionAttemptPolicy._(
    directRememberedMachine: true,
    connectPreferredDuringScan: true,
    stopScanAfterPreferredConnect: true,
  );

  static const explicitScan = ConnectionAttemptPolicy._(
    directRememberedMachine: false,
    connectPreferredDuringScan: false,
    stopScanAfterPreferredConnect: false,
  );

  static const explicitPreferredScaleReconnect = ConnectionAttemptPolicy._(
    directRememberedMachine: false,
    connectPreferredDuringScan: false,
    stopScanAfterPreferredConnect: false,
    stopBeforePreferredScaleConnect: true,
  );

  static const scaleRecovery = ConnectionAttemptPolicy._(
    directRememberedMachine: false,
    connectPreferredDuringScan: true,
    stopScanAfterPreferredConnect: false,
  );
}
