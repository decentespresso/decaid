import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_wifi.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/wifi_scale_id.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/web_socket_transport.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/services/wifi/bonsoir_wifi_scale_browser.dart';
import 'package:reaprime/src/services/wifi/wifi_ip_cache.dart';
import 'package:rxdart/subjects.dart';

class WifiScaleEndpoint {
  final String host;

  final String? ip;

  const WifiScaleEndpoint({required this.host, this.ip});
}

abstract class WifiScaleBrowser {
  Stream<List<WifiScaleEndpoint>> get endpoints;

  Future<void> start();

  Future<void> stop();
}

abstract class WifiManualEndpointStore {
  Future<List<String>> load();
  Future<void> save(List<String> hosts);
}

typedef WifiReachabilityProbe = Future<bool> Function(String host, int port);

Future<bool> _defaultReachabilityProbe(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

class WifiScaleDiscoveryService implements DeviceDiscoveryService {
  final _log = Logger('WifiScaleDiscovery');
  final WifiScaleBrowser _browser;
  final WifiIpCache _cache;
  final WifiManualEndpointStore _manualStore;

  static const int _wifiScalePort = 80;

  final Map<String, HDSWifi> _scales = {};
  List<String> _manualHosts = [];
  StreamSubscription<List<WifiScaleEndpoint>>? _browserSub;
  bool _started = false;

  final Set<String> _unreachable = {};
  final Map<String, int> _failures = {};
  Timer? _livenessTimer;
  bool _probing = false;

  final WifiReachabilityProbe _probe;
  final Duration _livenessInterval;
  final int _failureThreshold;

  final BehaviorSubject<List<Device>> _devices = BehaviorSubject.seeded(
    <Device>[],
  );

  WifiScaleDiscoveryService({
    WifiScaleBrowser? browser,
    WifiIpCache? cache,
    WifiManualEndpointStore? manualStore,
    WifiReachabilityProbe? reachabilityProbe,
    Duration livenessInterval = const Duration(seconds: 10),
    int failureThreshold = 2,
  }) : _browser = browser ?? BonsoirWifiScaleBrowser(),
       _cache = cache ?? WifiIpCache(),
       _manualStore = manualStore ?? SharedPrefsWifiManualEndpointStore(),
       _probe = reachabilityProbe ?? _defaultReachabilityProbe,
       _livenessInterval = livenessInterval,
       _failureThreshold = failureThreshold;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  @override
  Future<void> initialize() async {
    _manualHosts = await _manualStore.load();
    _ensureManualScales();
    _browserSub = _browser.endpoints.listen(_onEndpoints);
    await _ensureStarted();
    _emit();
    _livenessTimer ??= Timer.periodic(
      _livenessInterval,
      (_) => _checkLiveness(),
    );
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    await _ensureStarted();
    _emit();
    await _checkLiveness();
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  Future<void> _ensureStarted() async {
    if (_started) return;
    try {
      await _browser.start();
      _started = true;
    } catch (e, st) {
      _log.warning(
        'mDNS browser failed to start; manual entry still available',
        e,
        st,
      );
    }
  }

  List<String> get manualEndpoints => List.unmodifiable(_manualHosts);

  Future<void> addManualEndpoint(String host) async {
    final h = host.trim();
    if (h.isEmpty || _manualHosts.contains(h)) return;
    _manualHosts = [..._manualHosts, h];
    await _manualStore.save(_manualHosts);
    _scales.putIfAbsent(WifiScaleId.forHost(h), () => _buildScale(h));
    _emit();
  }

  Future<void> removeManualEndpoint(String host) async {
    if (!_manualHosts.contains(host)) return;
    _manualHosts = _manualHosts.where((h) => h != host).toList();
    await _manualStore.save(_manualHosts);
    final id = WifiScaleId.forHost(host);
    final removed = _scales.remove(id);
    _unreachable.remove(id);
    _failures.remove(id);
    await removed?.dispose();
    _cache.invalidate(host);
    _emit();
  }

  void _onEndpoints(List<WifiScaleEndpoint> eps) {
    for (final ep in eps) {
      if (ep.ip != null) _cache.record(ep.host, ep.ip!);
      final id = WifiScaleId.forHost(ep.host);
      _scales.putIfAbsent(id, () => _buildScale(ep.host));
      _unreachable.remove(id);
      _failures.remove(id);
    }
    _emit();
  }

  void _ensureManualScales() {
    for (final host in _manualHosts) {
      _scales.putIfAbsent(WifiScaleId.forHost(host), () => _buildScale(host));
    }
  }

  Future<void> _checkLiveness() async {
    if (_scales.isEmpty || _probing) return;
    _probing = true;
    var changed = false;
    try {
      for (final entry in _scales.entries.toList()) {
        final id = entry.key;
        final state = entry.value.currentState;
        if (state == ConnectionState.connected) {
          _failures.remove(id);
          if (_unreachable.remove(id)) changed = true;
          continue;
        }
        final host = WifiScaleId.hostOf(id);
        final reachable = await _probe(
          _cache.connectHostFor(host),
          _wifiScalePort,
        );
        if (reachable) {
          _failures.remove(id);
          if (_unreachable.remove(id)) changed = true;
        } else {
          final n = (_failures[id] ?? 0) + 1;
          _failures[id] = n;
          if (n >= _failureThreshold && _unreachable.add(id)) {
            _cache.invalidate(host);
            _log.info('WiFi scale $host unreachable (${n}x) — hiding');
            changed = true;
          }
        }
      }
    } finally {
      _probing = false;
    }
    if (changed) _emit();
  }

  void _emit() {
    if (_devices.isClosed) return;
    final visible = <Device>[
      for (final e in _scales.entries)
        if (!_unreachable.contains(e.key)) e.value,
    ];
    _devices.add(visible);
  }

  HDSWifi _buildScale(String host) => HDSWifi(
    host: host,
    transportFactory: () => WsTransport(host: _cache.connectHostFor(host)),
  );

  Future<void> dispose() async {
    _livenessTimer?.cancel();
    _livenessTimer = null;
    await _browserSub?.cancel();
    await _browser.stop();
    for (final scale in _scales.values) {
      await scale.dispose();
    }
    _scales.clear();
    if (!_devices.isClosed) await _devices.close();
  }
}
