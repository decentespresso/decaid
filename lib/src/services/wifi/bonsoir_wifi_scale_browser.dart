import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:rxdart/subjects.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// bonsoir-backed [WifiScaleBrowser]. Browses `_decentscale._tcp`, resolves
/// each service to its host/IP, and publishes the visible set.
///
/// Native DNS-SD on every platform (NsdManager / Bonjour / Avahi / dns_sd), so
/// no app-managed `MulticastLock` is needed on Android. Not unit-tested (it
/// drives platform channels) — verified on-device; the testable endpoint→device
/// logic lives in [WifiScaleDiscoveryService] behind the [WifiScaleBrowser] seam.
class BonsoirWifiScaleBrowser implements WifiScaleBrowser {
  /// The DNS-SD service type the HDS firmware advertises.
  static const String serviceType = '_decentscale._tcp';

  /// The HDS firmware always sets its mDNS hostname via `MDNS.begin("hds")`,
  /// so a `_decentscale._tcp` service resolves to `hds.local`. Used as a
  /// fallback host when bonsoir's resolve step doesn't yield one (observed
  /// flaky on macOS), so a found scale still surfaces. On macOS/iOS/Linux
  /// dart:io resolves `.local` natively, so a WebSocket to `ws://hds.local`
  /// connects without needing bonsoir's resolver.
  static const String _firmwareHost = 'hds.local';

  final _log = Logger('BonsoirWifiScaleBrowser');
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  /// Resolved endpoints keyed by service instance name.
  final Map<String, WifiScaleEndpoint> _resolved = {};
  final BehaviorSubject<List<WifiScaleEndpoint>> _endpoints =
      BehaviorSubject.seeded(<WifiScaleEndpoint>[]);

  @override
  Stream<List<WifiScaleEndpoint>> get endpoints => _endpoints.stream;

  @override
  Future<void> start() async {
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(type: serviceType);
    try {
      await discovery.initialize();
      _sub = discovery.eventStream!.listen(_onEvent);
      await discovery.start();
    } catch (_) {
      // A transient init/start failure must NOT stick: leave `_discovery` null
      // (and tear down the half-open discovery) so the next `start()` retries
      // instead of early-returning forever.
      await _sub?.cancel();
      _sub = null;
      try {
        await discovery.stop();
      } catch (_) {}
      rethrow;
    }
    _discovery = discovery;
    _log.info('browsing $serviceType');
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    switch (event) {
      case BonsoirDiscoveryStartedEvent():
        _log.info('discovery started');
      case BonsoirDiscoveryServiceFoundEvent():
        final svc = event.service;
        _log.info(
          'service found: ${svc.name} hostname=${svc.hostname} '
          'port=${svc.port} addresses=${svc.hostAddresses}',
        );
        final ipNow = _firstIpv4(svc.hostAddresses);
        final hostname = svc.hostname;
        final hostNow = _normalizeHost(
          (hostname != null && hostname.isNotEmpty)
              ? hostname
              : (ipNow ?? _firmwareHost),
        );
        _resolved[svc.name] = WifiScaleEndpoint(host: hostNow, ip: ipNow);
        _emit();
        svc.resolve(_discovery!.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        final svc = event.service;
        final ip = _firstIpv4(svc.hostAddresses);
        final hostname = svc.hostname;
        final host = _normalizeHost(
          (hostname != null && hostname.isNotEmpty)
              ? hostname
              : (ip ??
                    (svc.hostAddresses.isNotEmpty
                        ? svc.hostAddresses.first
                        : svc.name)),
        );
        _log.info(
          'service resolved: ${svc.name} host=$host ip=$ip '
          'addresses=${svc.hostAddresses}',
        );
        _resolved[svc.name] = WifiScaleEndpoint(host: host, ip: ip);
        _emit();
      case BonsoirDiscoveryServiceResolveFailedEvent():
        _log.warning('service resolve failed: ${event.service?.name}');
      case BonsoirDiscoveryServiceLostEvent():
        _log.info('service lost: ${event.service.name}');
        _resolved.remove(event.service.name);
        _emit();
      default:
        _log.fine('discovery event: ${event.runtimeType}');
    }
  }

  /// mDNS hostnames arrive as FQDNs with a trailing dot (`hds.local.`). Strip
  /// it: a trailing dot breaks `package:logging` Logger names and would make
  /// `wifi:hds.local.` a different deviceId than the found-event fallback
  /// `wifi:hds.local`.
  String _normalizeHost(String host) =>
      host.endsWith('.') ? host.substring(0, host.length - 1) : host;

  /// Prefer an IPv4 address (the firmware authors warn AAAA lookups block);
  /// fall back to the first address if none look like IPv4.
  String? _firstIpv4(List<String> addrs) {
    final ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
    for (final a in addrs) {
      if (ipv4.hasMatch(a)) return a;
    }
    return addrs.isNotEmpty ? addrs.first : null;
  }

  void _emit() {
    if (!_endpoints.isClosed) {
      _endpoints.add(_resolved.values.toList(growable: false));
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
    } catch (e) {
      _log.fine('discovery stop failed', e);
    }
    _discovery = null;
    if (!_endpoints.isClosed) await _endpoints.close();
  }
}

/// [WifiManualEndpointStore] backed by `shared_preferences`.
class SharedPrefsWifiManualEndpointStore implements WifiManualEndpointStore {
  static const String _key = 'wifi_scale_manual_hosts';

  @override
  Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? <String>[];
  }

  @override
  Future<void> save(List<String> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, hosts);
  }
}
