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

/// A WiFi scale endpoint surfaced by the [WifiScaleBrowser].
class WifiScaleEndpoint {
  /// Logical host — the mDNS hostname (e.g. `hds.local`) when available,
  /// otherwise the resolved IP. Stable across reconnects; basis of the
  /// scale's `deviceId`.
  final String host;

  /// Resolved IPv4 address, if known. Cached for fast/resilient reconnect.
  final String? ip;

  const WifiScaleEndpoint({required this.host, this.ip});
}

/// Abstraction over the mDNS (DNS-SD) browser.
///
/// Keeping bonsoir behind this seam lets [WifiScaleDiscoveryService]'s
/// endpoint→device logic be unit-tested with a fake, while the real
/// bonsoir-backed [BonsoirWifiScaleBrowser] is verified on-device.
abstract class WifiScaleBrowser {
  /// The set of currently-visible resolved endpoints.
  Stream<List<WifiScaleEndpoint>> get endpoints;

  /// Start (or no-op if already started) browsing for `_decentscale._tcp`.
  Future<void> start();

  /// Stop browsing and release resources.
  Future<void> stop();
}

/// Persists manually-added WiFi scale hosts so they survive restarts and can
/// be re-emitted for auto-reconnect.
abstract class WifiManualEndpointStore {
  Future<List<String>> load();
  Future<void> save(List<String> hosts);
}

/// Cheap reachability check: does `host:port` accept a TCP connection?
/// Injected so tests can decide reachability without a real socket.
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

/// Discovers the WiFi Half Decent Scale on the local network (DNS-SD) and
/// surfaces manually-added endpoints, emitting an [HDSWifi] per known host
/// into the unified device stream.
///
/// Mirrors the USB HDS path: it constructs the scale *directly* rather than
/// routing through the BLE-coupled `DeviceMatcher`. Each scale is built with a
/// transport factory that connects to the cached IP first (then the hostname),
/// honoring the firmware's resolve-once / prefer-IPv4 guidance.
class WifiScaleDiscoveryService implements DeviceDiscoveryService {
  final _log = Logger('WifiScaleDiscovery');
  final WifiScaleBrowser _browser;
  final WifiIpCache _cache;
  final WifiManualEndpointStore _manualStore;

  /// Port the HDS WiFi scale serves (ws://host:80/snapshot); also the port the
  /// reachability probe connects to.
  static const int _wifiScalePort = 80;

  /// Reused scale instances keyed by `deviceId` so a connected scale survives
  /// list rebuilds (never recreate an in-use HDSWifi). This is the KNOWN set
  /// (mDNS-discovered ∪ manually-added); visibility is governed by [_unreachable].
  final Map<String, HDSWifi> _scales = {};
  List<String> _manualHosts = [];
  StreamSubscription<List<WifiScaleEndpoint>>? _browserSub;
  bool _started = false;

  // Presence is reachability-driven, not mDNS-membership-driven: mDNS is flaky
  // (the same scale flaps `service lost`/`found` while it's on), and a
  // powered-off scale's record lingers on its TTL. So once discovered we KEEP a
  // scale and decide whether to surface it by probing its cached IP. A scale is
  // hidden from the device list after [_failureThreshold] consecutive failed
  // probes, and re-surfaced the moment its IP answers again (or mDNS re-resolves
  // it). This keeps using the cached IP for as long as it works.
  final Set<String> _unreachable = {};
  final Map<String, int> _failures = {};
  Timer? _livenessTimer;
  // Guards against overlapping liveness passes: the periodic timer fires
  // un-awaited while `scanForDevices()` also awaits a pass, and each probe can
  // take up to the socket timeout — so a slow pass can outlast the interval.
  // Two concurrent passes would race on `_failures`/`_unreachable`.
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
    // mDNS browsing is passive and continuous — a "scan" just ensures it is
    // running, re-publishes the current set, and kicks an immediate reachability
    // pass so a just-returned scale surfaces without waiting for the next tick.
    await _ensureStarted();
    _emit();
    await _checkLiveness();
  }

  @override
  void stopScan() {
    // Leave the browser running; mDNS is passive and cheap, and stopping it
    // would drop endpoints needed for the next preferred-device match.
  }

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  Future<void> _ensureStarted() async {
    if (_started) return;
    try {
      await _browser.start();
      _started = true;
    } catch (e, st) {
      // Discovery unavailable (e.g. Linux without Avahi). Manual-IP entry
      // still works; do not crash the scan.
      _log.warning(
        'mDNS browser failed to start; manual entry still available',
        e,
        st,
      );
    }
  }

  /// The currently-configured manually-added hosts (IPs or hostnames).
  List<String> get manualEndpoints => List.unmodifiable(_manualHosts);

  /// Add a manually-entered host (IP or hostname). Idempotent.
  Future<void> addManualEndpoint(String host) async {
    final h = host.trim();
    if (h.isEmpty || _manualHosts.contains(h)) return;
    _manualHosts = [..._manualHosts, h];
    await _manualStore.save(_manualHosts);
    _scales.putIfAbsent(WifiScaleId.forHost(h), () => _buildScale(h));
    _emit();
  }

  /// Remove a manually-added host and tear down its scale instance.
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

  /// mDNS browse result. Discovery-only: record IPs, ensure a scale exists, and
  /// clear any "unreachable" mark for a host mDNS just re-announced (it's back).
  /// Never removes — a vanished mDNS record does NOT hide the scale (that's the
  /// reachability probe's job), so mDNS flapping can't flicker the list.
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

  /// Probe each known scale's cached IP. Only an actively CONNECTED scale is
  /// skipped — its live socket already proves reachability, and a second probe
  /// socket could occupy one of the HDS's few client slots. A CONNECTING scale
  /// is still probed: when a scale powers off the controller keeps retrying it
  /// (a flat reconnect retry), so it sits in `connecting` against a dead IP — if
  /// we skipped that too, it would never be hidden. Others are hidden after
  /// [_failureThreshold] consecutive failures and re-surfaced on the next
  /// success.
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
            // Cached IP stopped answering — hide it and drop the cache so the
            // next mDNS resolve can pick up a possibly-new IP.
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
