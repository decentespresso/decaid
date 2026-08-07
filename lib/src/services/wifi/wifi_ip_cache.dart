class WifiIpCache {
  final Map<String, String> _hostToIp = {};

  void record(String host, String ip) {
    if (host.isEmpty || ip.isEmpty) return;
    _hostToIp[host] = ip;
  }

  String? cachedIp(String host) => _hostToIp[host];

  String connectHostFor(String host) => _hostToIp[host] ?? host;

  void invalidate(String host) => _hostToIp.remove(host);

  void clear() => _hostToIp.clear();
}
