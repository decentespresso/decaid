import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import '../helpers/felicita_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

/// Connection phase ownership for host-bound BLE plugin devices (#809).
///
/// Physical acquisition and platform recovery follow the transport's policy, so
/// they are not bounded by the plugin invocation timeout. The plugin's own
/// `connect` handler and protocol readiness still are.
///
/// The manager, the plugin runtime and the transport all live inside the
/// `fakeAsync` zone, so every deadline in the path is advanced by fake time and
/// no test sleeps. A manager built outside the zone cannot be driven this way:
/// its invocation deadlines are real timers that fake time never advances.
const _pluginTimeout = Duration(milliseconds: 200);
const _pastEveryDeadline = Duration(seconds: 30);

const _stallPluginId = 'phase-stall.reaplugin';

const _stallJs = '''
function createPlugin(host) {
  return {
    id: "phase-stall.reaplugin",
    onLoad() {
      return host.devices.bindDriver("stall", {
        create() {
          return {
            async connect(session) {
              await session.gatt.discoverServices();
              await new Promise(function () {});
            },
            disconnect() {}
          };
        }
      });
    }
  };
}
''';

PluginManifest _stallManifest() => PluginManifest.fromJson({
  'id': _stallPluginId,
  'name': 'Phase stall',
  'author': 'test',
  'description': 'Connection phase fixture',
  'version': '0.1.0',
  'apiVersion': 1,
  'permissions': ['transport.ble'],
  'drivers': [
    {
      'id': 'stall',
      'type': 'scale',
      'ble': {
        'match': {
          'name': {'contains': 'stall'},
        },
      },
    },
  ],
  'settings': {},
  'api': [],
});

class _Attempt {
  Device? device;
  StreamSubscription<ConnectionState>? subscription;
  final seen = <ConnectionState>[];
  bool settled = false;
  Object? outcome;
}

void main() {
  /// Creates a manager inside [async] and loads the Felicita reference plugin.
  PluginManager felicitaManager(FakeAsync async) {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceInvocationTimeout: _pluginTimeout,
    );
    Object? loadError;
    loadFelicitaPlugin(manager).then(
      (_) {},
      onError: (Object error) {
        loadError = error;
      },
    );
    async.elapse(const Duration(seconds: 1));
    expect(loadError, isNull, reason: 'the plugin fixture must load');
    return manager;
  }

  PluginManager stallManager(FakeAsync async) {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceInvocationTimeout: _pluginTimeout,
    );
    Object? loadError;
    manager
        .loadPlugin(
          id: _stallPluginId,
          manifest: _stallManifest(),
          settings: {},
          jsCode: _stallJs,
        )
        .then(
          (_) {},
          onError: (Object error) {
            loadError = error;
          },
        );
    async.elapse(const Duration(seconds: 1));
    expect(loadError, isNull, reason: 'the stall fixture must load');
    return manager;
  }

  /// Disposes [manager] inside the fixture's fake zone.
  ///
  /// The plugin host cannot finish its JavaScript unload under fake time, so a
  /// residual cleanup failure is discarded rather than failing a phase-ownership
  /// assertion; the zone teardown releases the rest.
  void disposeInsideZone(PluginManager manager, FakeAsync async) {
    manager.dispose().ignore();
    async.elapse(const Duration(seconds: 2));
  }

  /// Starts candidate creation and the connection attempt, then advances fake
  /// time until the candidate exists.
  _Attempt startAttempt(
    PluginManager manager,
    FakeAsync async, {
    required String evidenceName,
    required BLETransport Function() createTransport,
  }) {
    final attempt = _Attempt();
    addTearDown(() async => attempt.subscription?.cancel());
    final evidence = BleAdvertisementEvidence(name: evidenceName);
    manager.bleService
        .createCandidate(
          driver: manager.bleService.registry.decide(evidence).drivers.single,
          physicalId: 'AA:BB',
          evidence: evidence,
          admit: () => true,
          createTransport: createTransport,
        )
        .then((device) {
          attempt.device = device;
          attempt.subscription = device.connectionState.listen(
            attempt.seen.add,
          );
          return device.onConnect();
        })
        .then(
          (_) {
            attempt.settled = true;
          },
          onError: (Object error) {
            attempt.settled = true;
            attempt.outcome = error;
          },
        );
    async.elapse(const Duration(seconds: 1));
    return attempt;
  }

  test('physical acquisition may outlive the plugin invocation timeout', () {
    fakeAsync((async) {
      final manager = felicitaManager(async);
      final acquisition = Completer<void>();
      final transport = FelicitaPluginTransport(
        'AA:BB',
        firstPacket: felicitaPacket(2),
        connectBlocker: acquisition,
      );
      final attempt = startAttempt(
        manager,
        async,
        evidenceName: 'Felicita Arc',
        createTransport: () => transport,
      );
      expect(attempt.device, isNotNull);

      async.elapse(_pastEveryDeadline);
      expect(
        attempt.settled,
        isFalse,
        reason: 'the plugin deadline must not pre-empt acquisition',
      );
      expect(attempt.seen, contains(ConnectionState.connecting));
      expect(transport.connectCalls, 1);
      expect(
        transport.discoverServicesCalls,
        0,
        reason: 'the plugin must not start before the session exists',
      );

      acquisition.complete();
      async.elapse(_pastEveryDeadline);

      expect(attempt.settled, isTrue);
      expect(attempt.outcome, isNull);
      expect(attempt.seen, contains(ConnectionState.connected));
      expect(transport.discoverServicesCalls, 1);
      disposeInsideZone(manager, async);
    });
  });

  test('a slow acquisition still leaves the plugin handler bounded', () {
    fakeAsync((async) {
      final manager = stallManager(async);
      final acquisition = Completer<void>();
      final transport = FelicitaPluginTransport(
        'AA:BB',
        connectBlocker: acquisition,
      );
      final attempt = startAttempt(
        manager,
        async,
        evidenceName: 'stall device',
        createTransport: () => transport,
      );

      async.elapse(_pastEveryDeadline);
      expect(
        attempt.settled,
        isFalse,
        reason: 'acquisition is not bounded by the plugin deadline',
      );

      acquisition.complete();
      async.elapse(_pastEveryDeadline);

      expect(
        attempt.settled,
        isTrue,
        reason: 'protocol startup is still bounded after acquisition',
      );
      expect(attempt.outcome, isNotNull);
      expect(
        transport.discoverServicesCalls,
        1,
        reason: 'the handler ran only once the session existed',
      );
      expect(attempt.seen, isNot(contains(ConnectionState.connected)));
      disposeInsideZone(manager, async);
    });
  });

  test('a stalled plugin connect handler stays bounded', () {
    fakeAsync((async) {
      final manager = stallManager(async);
      final transport = FelicitaPluginTransport('AA:BB');
      final attempt = startAttempt(
        manager,
        async,
        evidenceName: 'stall device',
        createTransport: () => transport,
      );

      async.elapse(_pastEveryDeadline);

      expect(attempt.settled, isTrue);
      expect(attempt.outcome, isNotNull);
      expect(transport.connectCalls, 1);
      expect(attempt.seen, isNot(contains(ConnectionState.connected)));
      expect(
        attempt.seen.last,
        ConnectionState.disconnected,
        reason: 'a stalled handler must not leave the device half-live',
      );
      disposeInsideZone(manager, async);
    });
  });

  test('readiness that never arrives stays bounded', () {
    fakeAsync((async) {
      final manager = felicitaManager(async);
      final transport = FelicitaPluginTransport('AA:BB');
      final attempt = startAttempt(
        manager,
        async,
        evidenceName: 'Felicita Arc',
        createTransport: () => transport,
      );

      async.elapse(_pastEveryDeadline);

      expect(attempt.settled, isTrue);
      expect(
        attempt.outcome,
        isNotNull,
        reason: 'readiness that never arrives must not hang the attempt',
      );
      expect(attempt.seen.last, ConnectionState.disconnected);
      expect(
        transport.disconnectCalls,
        greaterThanOrEqualTo(1),
        reason: 'the physical session is retired with the failed attempt',
      );
      disposeInsideZone(manager, async);
    });
  });

  test(
    'stalled readiness rejects with the plugin timeout in real time',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: _pluginTimeout,
      );
      addTearDown(manager.dispose);
      await loadFelicitaPlugin(manager);
      final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
      final transport = FelicitaPluginTransport('AA:BB');
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:BB',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;

      final outcome = await scale.onConnect().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );

      expect(outcome, isA<TimeoutException>());
      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(transport.disconnectCalls, greaterThanOrEqualTo(1));
      await Future<void>.delayed(Duration.zero);
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );

  test(
    'a stalled plugin handler still releases BLE ownership in real time',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: _pluginTimeout,
      );
      addTearDown(manager.dispose);
      await manager.loadPlugin(
        id: _stallPluginId,
        manifest: _stallManifest(),
        settings: {},
        jsCode: _stallJs,
      );
      final evidence = BleAdvertisementEvidence(name: 'stall device');
      final transport = FelicitaPluginTransport('AA:BB');
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:BB',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;

      final outcome = await scale.onConnect().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );

      expect(outcome, isNotNull);
      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(transport.connectCalls, 1);
      await Future<void>.delayed(Duration.zero);
      expect(
        manager.bleService.registry.activeBindingCount,
        0,
        reason: 'failed startup must release BLE ownership',
      );
    },
  );

  test(
    'a failed acquisition keeps its native error and never starts the plugin',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: _pluginTimeout,
      );
      addTearDown(manager.dispose);
      await loadFelicitaPlugin(manager);
      final transport = FelicitaPluginTransport(
        'AA:BB',
        firstPacket: felicitaPacket(4),
        connectFailure: BleConnectException(code: '133'),
      );
      final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
      final scale =
          await manager.bleService.createCandidate(
                driver: manager.bleService.registry
                    .decide(evidence)
                    .drivers
                    .single,
                physicalId: 'AA:BB',
                evidence: evidence,
                admit: () => true,
                createTransport: () => transport,
              )
              as Scale;

      final outcome = await scale.onConnect().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );

      expect(
        outcome,
        isA<BleConnectException>().having((error) => error.code, 'code', '133'),
      );
      expect(
        transport.discoverServicesCalls,
        0,
        reason: 'a failed acquisition must not run the plugin protocol',
      );
      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );

  test('disposal during acquisition never publishes connected', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceInvocationTimeout: _pluginTimeout,
    );
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final acquisition = Completer<void>();
    final transport = FelicitaPluginTransport(
      'AA:BB',
      firstPacket: felicitaPacket(5),
      connectBlocker: acquisition,
    );
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final scale =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'AA:BB',
              evidence: evidence,
              admit: () => true,
              createTransport: () => transport,
            )
            as Scale;
    final seen = <ConnectionState>[];
    final subscription = scale.connectionState.listen(seen.add);
    addTearDown(subscription.cancel);

    final connecting = scale.onConnect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await transport.acquisitionStarted.future;
    await (scale as PluginDeviceAdapter).dispose();
    acquisition.complete();

    expect(await connecting, isNotNull);
    expect(seen, isNot(contains(ConnectionState.connected)));
    expect(transport.discoverServicesCalls, 0);
    expect(
      transport.disconnectCalls,
      greaterThanOrEqualTo(1),
      reason: 'a prepared physical session must be retired on disposal',
    );
    expect(manager.bleService.registry.activeBindingCount, 0);
  });

  test('disposal during protocol startup never publishes connected', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceInvocationTimeout: _pluginTimeout,
    );
    addTearDown(manager.dispose);
    await loadFelicitaPlugin(manager);
    final transport = FelicitaPluginTransport('AA:BB');
    final evidence = BleAdvertisementEvidence(name: 'Felicita Arc');
    final scale =
        await manager.bleService.createCandidate(
              driver: manager.bleService.registry
                  .decide(evidence)
                  .drivers
                  .single,
              physicalId: 'AA:BB',
              evidence: evidence,
              admit: () => true,
              createTransport: () => transport,
            )
            as Scale;
    final seen = <ConnectionState>[];
    final subscription = scale.connectionState.listen(seen.add);
    addTearDown(subscription.cancel);

    final connecting = scale.onConnect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await transport.servicesRequested.future;
    await (scale as PluginDeviceAdapter).dispose();

    expect(await connecting, isNotNull);
    expect(seen, isNot(contains(ConnectionState.connected)));
    expect(manager.bleService.registry.activeBindingCount, 0);
  });
}
