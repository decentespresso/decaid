import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_ble_session.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

const bleSensorSource = '''
function createPlugin(host) {
  return {
    id: 'ble.sensor',
    async onLoad() {
      await host.devices.bindDriver('humidity', {
        create(device) {
          globalThis.factoryDevice = device;
          let context;
          return {
            vendor: 'Fixture',
            dataChannels: [{key: 'humidity', type: 'number'}],
            commands: [{id: 'sample'}],
            async connect(session) {
              context = session;
              globalThis.oldContext = globalThis.oldContext || session;
              globalThis.currentContext = session;
              host.emit('connecting', true);
              const services = await session.gatt.discoverServices();
              host.emit('services', services);
              await session.gatt.subscribe('180f', '2a19', async data => {
                const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
                if (data.length !== 4 || data.slice(2) !== '==') throw Error('Invalid humidity frame');
                const humidity = (alphabet.indexOf(data[0]) << 2) | (alphabet.indexOf(data[1]) >> 4);
                await session.publish({humidity});
                host.emit('sample', data);
              });
            },
            async disconnect({gatt}) {
              if (gatt) await gatt.writeWithResponse('180f', '2a19', 'AA==');
            },
            async execute(command) {
              await context.gatt.writeWithResponse('180f', '2a19', 'AQ==');
              return {humidity: 52};
            }
          };
        }
      });
      host.emit('bound', true);
    }
  };
}
''';

PluginManifest bleSensorManifest({String id = 'ble.sensor'}) => testManifest(
  id,
  permissions: {PluginPermissions.emit, PluginPermissions.transportBle},
  drivers: [
    PluginDriverDeclaration(
      id: 'humidity',
      type: PluginDriverType.sensor,
      ble: PluginBleMatcher.fromJson({
        'serviceUuids': ['180f'],
      }),
    ),
  ],
);

void main() {
  Future<Sensor> candidate(
    PluginManager manager,
    List<PluginBleFixtureTransport> transports, {
    String id = 'AA:BB',
  }) async {
    final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
    return await manager.bleService.createCandidate(
          driver: manager.bleService.registry.decide(evidence).drivers.single,
          physicalId: id,
          evidence: evidence,
          admit: () => true,
          createTransport: () {
            final transport = PluginBleFixtureTransport(id);
            transports.add(transport);
            return transport;
          },
        )
        as Sensor;
  }

  Future<void> load(PluginManager manager, {String source = bleSensorSource}) =>
      manager.loadPlugin(
        id: 'ble.sensor',
        manifest: bleSensorManifest(),
        settings: {},
        jsCode: source,
      );

  for (final cleanup in [
    'throw Error("cleanup");',
    'await new Promise(() => {});',
  ]) {
    test('repeated permanently suspended initialization with $cleanup', () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(manager.dispose);
      await load(
        manager,
        source: bleSensorSource
            .replaceFirst(
              "const services = await session.gatt.discoverServices();",
              "await new Promise(() => {}); const services = [];",
            )
            .replaceFirst(
              "if (gatt) await gatt.writeWithResponse('180f', '2a19', 'AA==');",
              cleanup,
            ),
      );
      final transports = <PluginBleFixtureTransport>[];
      final sensor = await candidate(manager, transports);
      for (var i = 0; i < 4; i++) {
        final entered = manager.emitStream.firstWhere(
          (event) => event['event'] == 'connecting',
        );
        final connect = expectLater(sensor.onConnect(), throwsA(anything));
        await entered.timeout(const Duration(seconds: 2));
        await sensor.disconnect();
        await connect;
        expect(manager.bleService.registry.activeBindingCount, 0);
        expect(manager.deviceConnectAttemptCount, 0);
        expect(manager.retiredDeviceConnectCount, 0);
        expect(transports.last.disposeCalls, 1);
      }
    });
  }

  test(
    'unconfirmed teardown excludes reuse and unload still removes the driver',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceInvocationTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(manager.dispose);
      await load(manager);
      final transports = <PluginBleFixtureTransport>[];
      final sensor = await candidate(manager, transports);
      await sensor.onConnect();
      final release = Completer<void>();
      transports.single.teardown = release;
      await expectLater(sensor.disconnect(), throwsA(isA<TimeoutException>()));
      expect(manager.bleService.registry.isClaimed('AA:BB'), isTrue);
      await expectLater(sensor.onConnect(), throwsA(anything));
      expect(transports, hasLength(1));
      await expectLater(manager.unloadPlugin('ble.sensor'), throwsA(anything));
      expect(manager.bleService.registry.hasDrivers, isFalse);
      expect(manager.bleService.bindingCount, 0);
      expect(manager.bleService.registry.isClaimed('AA:BB'), isTrue);
      release.complete();
      await transports.single.disposed.future.timeout(
        const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero);
      expect(manager.bleService.registry.activeBindingCount, 0);
    },
  );

  test(
    'two physical Sensors own independent sessions with injected capacity',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        bleRegistry: PluginBleRegistry(activeBindingLimit: 2),
      );
      addTearDown(manager.dispose);
      await load(manager);
      final transports = <PluginBleFixtureTransport>[];
      final first = await candidate(manager, transports);
      final second = await candidate(manager, transports, id: 'CC:DD');
      await first.onConnect();
      await second.onConnect();
      expect(manager.bleService.registry.activeBindingCount, 2);
      await first.disconnect();
      expect(await second.execute('sample', null), {'humidity': 52});
      expect(manager.bleService.registry.activeBindingCount, 1);
      expect(
        () => manager.bleService.call(
          'foreign',
          1,
          'forged',
          'forged',
          'read',
          {'service': '180f', 'characteristic': '2a19'},
        ),
        throwsA(isA<PluginBleException>()),
      );
    },
  );

  test(
    'default capacity rejects a second Sensor without disturbing the first',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await load(manager);
      final transports = <PluginBleFixtureTransport>[];
      final first = await candidate(manager, transports);
      final second = await candidate(manager, transports, id: 'CC:DD');
      await first.onConnect();
      await expectLater(second.onConnect(), throwsA(isA<PluginBleException>()));
      expect(transports, hasLength(1));
      expect(manager.bleService.registry.activeBindingCount, 1);
      expect(await first.execute('sample', null), {'humidity': 52});
      await first.disconnect();
      await second.onConnect();
      expect(transports, hasLength(2));
    },
  );

  for (final linkLost in [false, true]) {
    test(
      'revocation skips protocol cleanup and emits one terminal event: linkLost=$linkLost',
      () async {
        final manager = PluginManager(kvStore: FakeKeyValueStoreService());
        addTearDown(manager.dispose);
        await load(
          manager,
          source: bleSensorSource.replaceFirst(
            'context = session;',
            "context = session; session.gatt.onDisconnect(() => host.emit('terminal', true));",
          ),
        );
        final events = <Map<String, dynamic>>[];
        final subscription = manager.emitStream.listen(events.add);
        addTearDown(subscription.cancel);
        final transports = <PluginBleFixtureTransport>[];
        final sensor = await candidate(manager, transports);
        await sensor.onConnect();
        if (linkLost) {
          transports.single.states.add(ConnectionState.disconnected);
        } else {
          manager.bleService.revokeSessions();
        }
        await transports.single.disposed.future.timeout(
          const Duration(seconds: 2),
        );
        await sensor.disconnect();
        expect(transports.single.writes, isEmpty);
        expect(
          events.where((event) => event['event'] == 'terminal'),
          hasLength(1),
        );
        expect(manager.bleService.registry.activeBindingCount, 0);
      },
    );
  }

  test('real JS factory, GATT, Sensor commands and reconnect fence', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    final bound = manager.emitStream.firstWhere((e) => e['event'] == 'bound');
    await manager.loadPlugin(
      id: 'ble.sensor',
      manifest: bleSensorManifest(),
      settings: {},
      jsCode: bleSensorSource,
    );
    await bound.timeout(const Duration(seconds: 2));
    final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
    final driver = manager.bleService.registry.decide(evidence).drivers.single;
    final transports = <PluginBleFixtureTransport>[];
    final sensor =
        await manager.bleService.createCandidate(
              driver: driver,
              physicalId: 'AA:BB',
              evidence: evidence,
              createTransport: () {
                final transport = PluginBleFixtureTransport('AA:BB');
                transports.add(transport);
                return transport;
              },
              admit: () => true,
            )
            as Sensor;
    expect(sensor.deviceId, 'plugin:ble.sensor:humidity:aa:bb');
    expect(sensor.transportType, TransportType.ble);
    expect(transports, isEmpty);
    final sample = sensor.data.first;
    await sensor.onConnect();
    expect(await sample.timeout(const Duration(seconds: 2)), {'humidity': 52});
    expect(await sensor.execute('sample', null), {'humidity': 52});
    expect(transports.single.writes.single.withResponse, isTrue);
    await sensor.disconnect();
    await sensor.onConnect();
    expect(transports, hasLength(2));
    expect(transports.first.disposeCalls, 1);
    manager.js.evaluate('''
      oldContext.gatt.read('180f', '2a19').then(
        () => { throw Error('stale read succeeded'); },
        e => currentContext.publish({humidity: 51}).then(() => {
          globalThis.staleCode = e.code;
        })
      );
    ''');
    while (manager.js.executePendingJob() > 0) {}
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      manager.js.evaluate('globalThis.staleCode').stringResult,
      'stale_session',
    );
    final states = <ConnectionState>[];
    final stateSubscription = sensor.connectionState.listen(states.add);
    await manager.unloadPlugin('ble.sensor');
    await stateSubscription.cancel();
    expect(states.last, ConnectionState.disconnected);
    expect(manager.bleService.registry.hasDrivers, isFalse);
    expect(manager.bleService.registry.activeBindingCount, 0);
  });
}
