import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:rxdart/subjects.dart';

class FakeWifiScaleBrowser implements WifiScaleBrowser {
  final BehaviorSubject<List<WifiScaleEndpoint>> _ctrl = BehaviorSubject.seeded(
    <WifiScaleEndpoint>[],
  );
  bool started = false;
  bool failStart = false;

  @override
  Stream<List<WifiScaleEndpoint>> get endpoints => _ctrl.stream;

  @override
  Future<void> start() async {
    if (failStart) throw StateError('mDNS unavailable (no Avahi)');
    started = true;
  }

  @override
  Future<void> stop() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  void emit(List<WifiScaleEndpoint> eps) => _ctrl.add(eps);
}

class InMemoryManualStore implements WifiManualEndpointStore {
  List<String> hosts;
  InMemoryManualStore([this.hosts = const []]);

  @override
  Future<List<String>> load() async => List.of(hosts);

  @override
  Future<void> save(List<String> h) async => hosts = List.of(h);
}

/// Create a service with an injected reachability probe (reachable by default,
/// no real sockets) and an inert background timer — tests drive the liveness
/// check deterministically via [WifiScaleDiscoveryService.scanForDevices].
/// Registers teardown so the liveness timer never leaks.
WifiScaleDiscoveryService makeSvc({
  WifiScaleBrowser? browser,
  WifiManualEndpointStore? manualStore,
  WifiReachabilityProbe? probe,
  int failureThreshold = 2,
}) {
  final svc = WifiScaleDiscoveryService(
    browser: browser ?? FakeWifiScaleBrowser(),
    manualStore: manualStore ?? InMemoryManualStore(),
    reachabilityProbe: probe ?? (_, _) async => true,
    failureThreshold: failureThreshold,
    livenessInterval: const Duration(hours: 1),
  );
  addTearDown(svc.dispose);
  return svc;
}

/// Latest device list, after letting microtasks settle.
Future<List<Device>> _latest(WifiScaleDiscoveryService svc) async {
  await Future.delayed(Duration.zero);
  return svc.devices.first;
}

void main() {
  group('WifiScaleDiscoveryService', () {
    test('a discovered service becomes a wifi-scoped scale device', () async {
      final browser = FakeWifiScaleBrowser();
      final svc = makeSvc(browser: browser);
      await svc.initialize();
      expect(await _latest(svc), isEmpty);

      browser.emit([
        const WifiScaleEndpoint(host: 'hds.local', ip: '192.168.1.42'),
      ]);
      final devices = await _latest(svc);
      expect(devices, hasLength(1));
      expect(devices.single.deviceId, 'wifi:hds.local');
      expect(devices.single.type, DeviceType.scale);
    });

    test(
      'no service and no manual host yields an empty list, no error',
      () async {
        final svc = makeSvc();
        await svc.initialize();
        expect(await _latest(svc), isEmpty);
      },
    );

    test(
      'discovery unavailable does not crash; manual host still surfaces',
      () async {
        final browser = FakeWifiScaleBrowser()..failStart = true;
        final svc = makeSvc(
          browser: browser,
          manualStore: InMemoryManualStore(['192.168.1.7']),
        );
        // Must not throw even though the browser failed to start.
        await svc.initialize();
        final devices = await _latest(svc);
        expect(devices.single.deviceId, 'wifi:192.168.1.7');
      },
    );

    test(
      'persisted manual endpoints are emitted on init (reconnect path)',
      () async {
        final svc = makeSvc(manualStore: InMemoryManualStore(['hds.local']));
        await svc.initialize();
        expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');
      },
    );

    test('discovered and manual endpoints are unioned', () async {
      final browser = FakeWifiScaleBrowser();
      final svc = makeSvc(
        browser: browser,
        manualStore: InMemoryManualStore(['192.168.1.7']),
      );
      await svc.initialize();
      browser.emit([
        const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
      ]);
      final ids = (await _latest(svc)).map((d) => d.deviceId).toSet();
      expect(ids, {'wifi:192.168.1.7', 'wifi:hds.local'});
    });

    test('addManualEndpoint persists and surfaces a device', () async {
      final store = InMemoryManualStore();
      final svc = makeSvc(manualStore: store);
      await svc.initialize();
      await svc.addManualEndpoint('192.168.1.50');
      expect(store.hosts, ['192.168.1.50']);
      expect((await _latest(svc)).single.deviceId, 'wifi:192.168.1.50');
    });

    test('the same scale instance is reused across rebuilds', () async {
      final browser = FakeWifiScaleBrowser();
      final svc = makeSvc(browser: browser);
      await svc.initialize();
      browser.emit([
        const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
      ]);
      final first = (await _latest(svc)).single;
      browser.emit([
        const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.9'),
      ]);
      final second = (await _latest(svc)).single;
      expect(identical(first, second), isTrue);
    });

    group('reachability-driven presence', () {
      test('a discovered scale whose IP stops answering is hidden after the '
          'failure threshold', () async {
        var reachable = true;
        final browser = FakeWifiScaleBrowser();
        final svc = makeSvc(
          browser: browser,
          probe: (_, _) async => reachable,
          failureThreshold: 2,
        );
        await svc.initialize();
        browser.emit([
          const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
        ]);
        expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');

        reachable = false;
        await svc.scanForDevices();
        expect(await _latest(svc), hasLength(1));
        await svc.scanForDevices();
        expect(await _latest(svc), isEmpty);
      });

      test('a hidden scale reappears when its IP answers again', () async {
        var reachable = false;
        final browser = FakeWifiScaleBrowser();
        final svc = makeSvc(
          browser: browser,
          probe: (_, _) async => reachable,
          failureThreshold: 1,
        );
        await svc.initialize();
        browser.emit([
          const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
        ]);
        await svc.scanForDevices();
        expect(await _latest(svc), isEmpty);

        reachable = true;
        await svc.scanForDevices();
        expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');
      });

      test(
        'mDNS re-announcing a hidden scale resurfaces it (flap immunity)',
        () async {
          final browser = FakeWifiScaleBrowser();
          final svc = makeSvc(
            browser: browser,
            probe: (_, _) async => false,
            failureThreshold: 1,
          );
          await svc.initialize();
          browser.emit([
            const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
          ]);
          await svc.scanForDevices();
          expect(await _latest(svc), isEmpty);

          // mDNS re-announces the same host → it's back, clear the hidden mark.
          browser.emit([
            const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
          ]);
          expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');
        },
      );

      test('an mDNS re-announce resets the failure counter (does not just clear '
          'the hidden mark)', () async {
        var reachable = true;
        final browser = FakeWifiScaleBrowser();
        final svc = makeSvc(
          browser: browser,
          probe: (_, _) async => reachable,
          failureThreshold: 2,
        );
        await svc.initialize();
        browser.emit([
          const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
        ]);

        reachable = false;
        await svc.scanForDevices();
        expect(await _latest(svc), hasLength(1));

        // mDNS re-announces the same host mid-way through accumulating
        // failures. This must RESET the counter, not just clear a (not-yet-set)
        // hidden mark.
        browser.emit([
          const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
        ]);

        await svc.scanForDevices();
        expect(
          await _latest(svc),
          hasLength(1),
          reason:
              're-announce must reset the failure count, so one more '
              'failure is not enough to hide the scale',
        );

        await svc.scanForDevices();
        expect(await _latest(svc), isEmpty);
      });

      test(
        'liveness probes the cached IP, not the hostname, once mDNS resolves',
        () async {
          final probedHosts = <String>[];
          final browser = FakeWifiScaleBrowser();
          final svc = makeSvc(
            browser: browser,
            probe: (host, _) async {
              probedHosts.add(host);
              return true;
            },
          );
          await svc.initialize();
          browser.emit([
            const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
          ]);

          probedHosts.clear();
          await svc.scanForDevices();
          expect(
            probedHosts,
            contains('10.0.0.5'),
            reason:
                'the probe must target the resolved/cached IP (resolve-once '
                'firmware guidance), not the flaky mDNS hostname',
          );
          expect(probedHosts, isNot(contains('hds.local')));
        },
      );

      test(
        'mDNS losing a service does NOT hide a still-reachable scale',
        () async {
          final browser = FakeWifiScaleBrowser();
          final svc = makeSvc(browser: browser, probe: (_, _) async => true);
          await svc.initialize();
          browser.emit([
            const WifiScaleEndpoint(host: 'hds.local', ip: '10.0.0.5'),
          ]);
          expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');

          // mDNS "service lost" (empty list) — must stay, IP still answers.
          browser.emit(const []);
          await svc.scanForDevices();
          expect((await _latest(svc)).single.deviceId, 'wifi:hds.local');
        },
      );
    });
  });
}
