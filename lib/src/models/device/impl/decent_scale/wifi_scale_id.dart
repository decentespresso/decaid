class WifiScaleId {
  static const String prefix = 'wifi:';

  static String forHost(String host) => '$prefix$host';

  static String hostOf(String deviceId) => deviceId.startsWith(prefix)
      ? deviceId.substring(prefix.length)
      : deviceId;
}
