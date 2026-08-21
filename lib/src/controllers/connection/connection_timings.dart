class ConnectionTimings {
  static const preScanDeviceCheckTimeout = Duration(seconds: 2);

  static const postScanSettleDelay = Duration(milliseconds: 200);

  static const initialShotSettingsTimeout = Duration(seconds: 2);

  static const shotSettingsDebounce = Duration(milliseconds: 100);

  static const profileDownloadGuard = Duration(milliseconds: 500);

  static const machineReplacementTimeout = Duration(seconds: 10);
}
