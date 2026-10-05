import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/plugin_ble_fixture.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import 'plugin_test_helpers.dart';

typedef _GrinderFixtureFactory =
    Future<_GrinderFixture> Function({required bool controls, bool metadata});

void main() {
  final factories = <String, _GrinderFixtureFactory>{
    'network': _networkFixture,
    'BLE': _bleFixture,
  };

  for (final invalid in [
    {'state': 'invalid-state', 'controls': <String, dynamic>{}},
    {'state': 'idle', 'rpm': 'invalid', 'surfaces': []},
    {'state': 'invalid-state'},
    {'state': 'idle', 'rpm': 'invalid'},
  ]) {
    test(
      'BLE invalid snapshot retires after info publication: $invalid',
      () async {
        final fixture = await _bleFixture(controls: true, metadata: true);
        addTearDown(fixture.dispose);
        final grinder = fixture.grinder;
        await grinder.onConnect();
        fixture.manager.js.evaluate('''
        currentGrinderContext.publishInfo({controls: {grindSetting: {kind: 'opaque'}}, surfaces: []});
      ''');
        await _flushJs(fixture.manager);
        expect(grinder.controls['grindSetting']!.kind, 'opaque');
        expect(grinder.surfaces, isEmpty);
        fixture.manager.js.evaluate(
          'globalThis.invalidSnapshot = ${jsonEncode(invalid)}',
        );
        final disconnected = grinder.connectionState.firstWhere(
          (state) => state == ConnectionState.disconnected,
        );
        fixture.currentTransport!()!.subscribers.values.single(
          Uint8List.fromList([52]),
        );
        await disconnected.timeout(const Duration(seconds: 2));
        expect(fixture.currentTransport!()!.disconnectCalls, greaterThan(0));
      },
    );
  }

  test('BLE oversized snapshot publication remains fatal', () async {
    final fixture = await _bleFixture(controls: true, metadata: true);
    addTearDown(fixture.dispose);
    final grinder = fixture.grinder;
    await grinder.onConnect();
    fixture.manager.js.evaluate('''
      globalThis.invalidSnapshot = {state: 'idle', setting: 'x'.repeat(70 * 1024)};
    ''');
    final disconnected = grinder.connectionState.firstWhere(
      (state) => state == ConnectionState.disconnected,
    );
    fixture.currentTransport!()!.subscribers.values.single(
      Uint8List.fromList([52]),
    );
    await disconnected.timeout(const Duration(seconds: 2));
    expect(fixture.currentTransport!()!.disconnectCalls, greaterThan(0));
  });

  test(
    'BLE oversized info rejection preserves connection and metadata',
    () async {
      final fixture = await _bleFixture(controls: true, metadata: true);
      addTearDown(fixture.dispose);
      final grinder = fixture.grinder;
      await grinder.onConnect();
      fixture.manager.js.evaluate('''
      currentGrinderContext.publishInfo({controls: {grindSetting: {
        kind: 'enumerated', values: ['filter']
      }}, surfaces: ['settings']});
    ''');
      await _flushJs(fixture.manager);
      final acceptedControls = grinder.controls.map(
        (id, descriptor) => MapEntry(id, descriptor.toJson()),
      );
      final acceptedSurfaces = grinder.surfaces
          .map((surface) => Map<String, String>.from(surface))
          .toList();
      expect(acceptedControls['grindSetting']!['values'], ['filter']);
      expect(acceptedSurfaces, hasLength(1));
      fixture.manager.js.evaluate('globalThis.oversizedInfo = true');
      final rejected = fixture.manager.emitStream.firstWhere(
        (event) => event['event'] == 'metadataRejected',
      );
      fixture.currentTransport!()!.subscribers.values.single(
        Uint8List.fromList([52]),
      );
      expect(
        (await rejected.timeout(const Duration(seconds: 2)))['payload'],
        'resource_limit',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await grinder.connectionState.first, ConnectionState.connected);
      expect(fixture.currentTransport!()!.disconnectCalls, 0);
      expect(
        grinder.controls.map(
          (id, descriptor) => MapEntry(id, descriptor.toJson()),
        ),
        acceptedControls,
      );
      expect(grinder.surfaces, acceptedSurfaces);
      await grinder.setGrindSetting('filter');
      await grinder.start();
      expect(
        (await grinder.currentSnapshot.first).state,
        GrinderState.grinding,
      );
      expect(
        fixture.events
            .where((event) => event['event'] == 'setting')
            .single['payload'],
        'filter',
      );
    },
  );

  for (final entry in factories.entries) {
    group('${entry.key} Grinder contract', () {
      test(
        'fixed and runtime metadata share command and info contracts',
        () async {
          final fixture = await entry.value(controls: true, metadata: true);
          addTearDown(fixture.dispose);
          final grinder = fixture.grinder;
          await grinder.onConnect();
          final controller = GrinderController();
          addTearDown(controller.dispose);
          await controller.adoptGrinder(grinder);
          final router = Router().plus;
          GrinderHandler(controller: controller).addRoutes(router);
          Future<Map<String, dynamic>> info() async {
            final response = await router.call(
              Request('GET', Uri.parse('http://localhost/api/v1/grinder/info')),
            );
            return jsonDecode(await response.readAsString())
                as Map<String, dynamic>;
          }

          expect((await info())['controls']['grindSetting']['max'], 80);
          expect((await info())['surfaces'][0]['role'], 'settings');
          expect(
            () => controller.setRpm(121),
            throwsA(isA<GrinderOperationException>()),
          );
          await controller.setGrindSetting('1.5');
          await controller.setRpm(60);
          fixture.manager.js.evaluate('''
          currentGrinderContext.publishInfo({controls: {grindSetting: {
            kind: 'enumerated', values: ['filter']
          }}, surfaces: []});
        ''');
          await _flushJs(fixture.manager);
          expect(
            (await info())['controls']['grindSetting']['kind'],
            'enumerated',
          );
          expect((await info())['surfaces'], isEmpty);
          fixture.manager.js.evaluate('''
            currentGrinderContext.publishInfo({controls: {grindSetting: {
              kind: 'enumerated', values: ['x'.repeat(70 * 1024)]
            }}, surfaces: ['settings']}).then(
              () => globalThis.largeInfoCode = 'resolved',
              error => globalThis.largeInfoCode = error.code
            );
          ''');
          await _flushJs(fixture.manager);
          expect(
            fixture.manager.js
                .evaluate('globalThis.largeInfoCode')
                .stringResult,
            'resource_limit',
          );
          expect((await info())['controls']['grindSetting']['values'], [
            'filter',
          ]);
          expect((await info())['surfaces'], isEmpty);
          expect(
            () => controller.setGrindSetting('1.5'),
            throwsA(isA<GrinderOperationException>()),
          );
          await controller.setGrindSetting('filter');
          expect(
            fixture.events
                .where((event) => event['event'] == 'setting')
                .map((event) => event['payload']),
            ['1.5', 'filter'],
          );
          if (entry.key == 'BLE') {
            fixture.manager.js.evaluate('globalThis.failPublication = true');
            final rejected = fixture.manager.emitStream.firstWhere(
              (event) => event['event'] == 'metadataRejected',
            );
            fixture.currentTransport!()!.subscribers.values.single(
              Uint8List.fromList([52]),
            );
            expect(
              (await rejected.timeout(const Duration(seconds: 2)))['payload'],
              'invalid_argument',
            );
            await Future<void>.delayed(const Duration(milliseconds: 30));
            expect(
              controller.currentConnectionState,
              ConnectionState.connected,
            );
            expect(
              (await info())['controls']['grindSetting']['kind'],
              'enumerated',
            );
            expect((await info())['surfaces'], isEmpty);
            await controller.setGrindSetting('filter');
          }
          fixture.manager.js.evaluate(
            'globalThis.retainedInfoContext = currentGrinderContext',
          );
          final retired = grinder as PluginGrinder;
          final beforeUnload = await info();
          expect(beforeUnload['surfaces'], isEmpty);
          final replacement = await fixture.replace();
          await replacement.onConnect();
          await controller.adoptGrinder(replacement);
          fixture.manager.js.evaluate('''
            retainedInfoContext.publishInfo({controls: {grindSetting: {kind: 'opaque'}}, surfaces: []}).then(
              () => globalThis.retiredInfoCode = 'resolved',
              error => globalThis.retiredInfoCode = error.code
            );
          ''');
          await _flushJs(fixture.manager);
          expect(
            fixture.manager.js
                .evaluate('globalThis.retiredInfoCode')
                .stringResult,
            'stale_session',
          );
          expect((await info())['controls']['grindSetting']['kind'], 'numeric');
          expect((await info())['surfaces'], hasLength(1));
          expect(retired.controls['grindSetting']!.kind, 'numeric');
          expect(retired.surfaces, hasLength(1));
        },
      );

      test(
        'constructs the same adapter and enforces the typed contract',
        () async {
          final fixture = await entry.value(controls: true);
          addTearDown(fixture.dispose);
          final grinder = fixture.grinder;
          expect(grinder, isA<PluginGrinder>());
          expect(
            (grinder as PluginGrinder).invocationTimeout,
            const Duration(seconds: 10),
          );
          expect(grinder.type, DeviceType.grinder);
          expect(
            grinder.transportType,
            entry.key == 'BLE' ? TransportType.ble : TransportType.unknown,
          );

          final snapshots = <GrinderSnapshot>[];
          final subscription = grinder.currentSnapshot.listen(snapshots.add);
          addTearDown(subscription.cancel);
          fixture.manager.js.evaluate(
            'globalThis.delayInitialPublication = true',
          );
          var connected = false;
          final connection = grinder.onConnect().then((_) => connected = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(connected, isFalse);
          fixture.manager.js.evaluate('globalThis.publishInitialPublication()');
          await _flushJs(fixture.manager);
          await connection;
          expect(snapshots.single.state, GrinderState.idle);

          await grinder.start();
          await grinder.setGrindSetting('12.3');
          await grinder.setRpm(1200);
          await grinder.stop();
          await Future<void>.delayed(Duration.zero);
          expect(
            fixture.events
                .where((event) => event['event'] == 'setting')
                .single['payload'],
            '12.3',
          );
          expect(
            fixture.events
                .where((event) => event['event'] == 'rpm')
                .single['payload'],
            1200,
          );
          expect(snapshots.last.state, GrinderState.idle);
          expect(snapshots.last.setting, '12.3');
          expect(snapshots.last.rpm, 1200);

          fixture.manager.js.evaluate('''
          currentGrinderContext.publish({state: 'idle', vendor: true}).then(
            () => globalThis.invalidPublicationCode = 'resolved',
            error => globalThis.invalidPublicationCode = error.code || String(error)
          );
        ''');
          await _flushJs(fixture.manager);
          expect(
            fixture.manager.js
                .evaluate('globalThis.invalidPublicationCode')
                .stringResult,
            'invalid_argument',
          );

          await grinder.disconnect();
          await grinder.onConnect();
          fixture.manager.js.evaluate('''
          oldContext.publish({state: 'grinding'}).catch(error => {
            globalThis.staleCode = error.code;
          });
        ''');
          while (fixture.manager.js.executePendingJob() > 0) {}
          await grinder.start();
          expect(
            fixture.manager.js.evaluate('globalThis.staleCode').stringResult,
            'stale_session',
          );
        },
      );

      test('unsupported controls never invoke handlers', () async {
        final fixture = await entry.value(controls: false);
        addTearDown(fixture.dispose);
        final grinder = fixture.grinder;
        await grinder.onConnect();

        fixture.manager.js.evaluate('''
          currentGrinderContext.publish({state: 'idle', rpm: 1200}).then(
            () => globalThis.undeclaredPublicationCode = 'resolved',
            error => globalThis.undeclaredPublicationCode = error.code || String(error)
          );
        ''');
        await _flushJs(fixture.manager);
        expect(
          fixture.manager.js
              .evaluate('globalThis.undeclaredPublicationCode')
              .stringResult,
          'invalid_argument',
        );

        await expectLater(
          grinder.start(),
          throwsA(
            isA<GrinderOperationException>().having(
              (error) => error.code,
              'code',
              'unsupported_operation',
            ),
          ),
        );
        expect(
          fixture.events.where((event) => event['event'] == 'start'),
          isEmpty,
        );

        final controller = GrinderController();
        addTearDown(controller.dispose);
        await controller.adoptGrinder(grinder);
        final router = Router().plus;
        GrinderHandler(controller: controller).addRoutes(router);
        final response = await router.call(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/v1/grinder/state/grinding'),
          ),
        );
        expect(response.statusCode, HttpStatus.internalServerError);
        expect(jsonDecode(await response.readAsString()), {
          'error': 'start is unsupported',
          'code': 'unsupported_operation',
        });
      });

      test(
        'supports shared inventory, API, reconnect, and websocket',
        () async {
          final fixture = await entry.value(controls: true);
          final discovery = _RefreshingDiscovery(fixture.grinder);
          final devices = DeviceController([discovery]);
          await devices.initialize();
          final settings = SettingsController(MockSettingsService());
          await settings.loadSettings();
          await settings.setPreferredGrinderDeviceId(fixture.grinder.deviceId);
          final grinders = GrinderController();
          final connections = ConnectionManager(
            deviceScanner: devices,
            de1Controller: De1Controller(controller: devices),
            scaleController: ScaleController(),
            grinderController: grinders,
            settingsController: settings,
          );
          final router = Router().plus;
          final inventory = DevicesHandler(
            controller: devices,
            connectionManager: connections,
            preferredGrinderDeviceId: () => settings.preferredGrinderDeviceId,
          );
          inventory.addRoutes(router);
          GrinderHandler(controller: grinders).addRoutes(router);
          final server = await shelf_io.serve(router.call, '127.0.0.1', 0);
          final client = HttpClient();

          Future<(int, dynamic)> request(
            String method,
            String path, {
            Object? body,
          }) async {
            final request = await client.openUrl(
              method,
              Uri.parse('http://127.0.0.1:${server.port}$path'),
            );
            if (body != null) {
              request.headers.contentType = ContentType.json;
              request.write(jsonEncode(body));
            }
            final response = await request.close();
            final text = await utf8.decoder.bind(response).join();
            return (
              response.statusCode,
              text.isEmpty ? null : jsonDecode(text),
            );
          }

          final initialInventory =
              (await request('GET', '/api/v1/devices')).$2 as List;
          expect(initialInventory.single['type'], 'grinder');

          await connections.connect();
          await grinders.connectionState
              .firstWhere((state) => state == ConnectionState.connected)
              .timeout(const Duration(seconds: 2));
          expect(grinders.connectedGrinder(), same(fixture.grinder));
          expect(
            (await request('GET', '/api/v1/grinder/info')).$2,
            containsPair('deviceId', fixture.grinder.deviceId),
          );
          expect(
            (await request('GET', '/api/v1/grinder/state')).$2,
            isNot(contains('vendor')),
          );

          final channel = IOWebSocketChannel.connect(
            Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/grinder/snapshot'),
          );
          final frames = <Map<String, dynamic>>[];
          final subscription = channel.stream.listen(
            (data) =>
                frames.add(jsonDecode(data as String) as Map<String, dynamic>),
          );
          await channel.ready;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(frames.map((frame) => frame['state']), ['idle']);

          expect(
            (await request(
              'PUT',
              '/api/v1/devices/disconnect',
              body: {'deviceId': fixture.grinder.deviceId},
            )).$1,
            HttpStatus.ok,
          );
          final replacement = await fixture.replace();
          discovery
            ..removeDevice(fixture.grinder.deviceId)
            ..addDevice(replacement);
          expect(
            (await request(
              'PUT',
              '/api/v1/devices/connect',
              body: {'deviceId': replacement.deviceId},
            )).$1,
            HttpStatus.ok,
          );
          expect(
            (await request('PUT', '/api/v1/grinder/state/grinding')).$1,
            HttpStatus.ok,
          );
          expect(
            (await request(
              'PUT',
              '/api/v1/grinder/setting',
              body: {'setting': '12.3'},
            )).$1,
            HttpStatus.ok,
          );
          expect(
            (await request(
              'PUT',
              '/api/v1/grinder/rpm',
              body: {'rpm': 1200},
            )).$1,
            HttpStatus.ok,
          );
          expect(
            (await request('PUT', '/api/v1/grinder/state/idle')).$1,
            HttpStatus.ok,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(frames.any((frame) => frame['state'] == 'grinding'), isTrue);
          expect(frames.every((frame) => !frame.containsKey('status')), isTrue);

          await channel.sink.close();
          await subscription.cancel();
          client.close(force: true);
          await server.close(force: true);
          inventory.dispose();
          await connections.dispose();
          devices.dispose();
          discovery.dispose();
          settings.dispose();
          await fixture.dispose();
        },
      );
    });
  }
}

class _RefreshingDiscovery extends MockDeviceDiscoveryService {
  _RefreshingDiscovery(this.device) {
    addDevice(device);
  }

  final Device device;

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    clear();
    addDevice(device);
    await super.scanForDevices(filter: filter);
  }
}

class _GrinderFixture {
  final PluginManager manager;
  final GrinderDevice grinder;
  final List<Map<String, dynamic>> events;
  final Future<GrinderDevice> Function() replace;
  final PluginBleFixtureTransport? Function()? currentTransport;

  const _GrinderFixture(
    this.manager,
    this.grinder,
    this.events,
    this.replace, {
    this.currentTransport,
  });

  Future<void> dispose() => manager.dispose();
}

PluginDriverDeclaration _driver({
  required bool controls,
  bool metadata = false,
  PluginBleMatcher? ble,
}) => PluginDriverDeclaration(
  id: 'grinder',
  type: PluginDriverType.grinder,
  ble: ble,
  controls: metadata
      ? {
          'grindSetting': GrinderControlDescriptor.fromJson('grindSetting', {
            'kind': 'numeric',
            'min': 1,
            'max': 80,
            'step': 1,
          }),
          'rpmControl': GrinderControlDescriptor.fromJson('rpmControl', {
            'kind': 'numeric',
            'min': 60,
            'max': 120,
          }),
        }
      : const {},
  surfaces: metadata
      ? const [
          PluginDeviceSurface(
            id: 'settings',
            role: 'settings',
            endpoint: 'device-settings',
          ),
        ]
      : const [],
  grinderCapabilities: controls
      ? PluginGrinderCapability.values.toSet()
      : const {},
);

Future<_GrinderFixture> _networkFixture({
  required bool controls,
  bool metadata = false,
}) async {
  final manager = PluginManager(kvStore: FakeKeyValueStoreService());
  final events = <Map<String, dynamic>>[];
  manager.emitStream.listen(events.add);
  Future<void> load() => manager.loadPlugin(
    id: 'network.grinder',
    manifest: testManifest(
      'network.grinder',
      permissions: {
        PluginPermissions.emit,
        if (metadata) PluginPermissions.api,
      },
      drivers: [_driver(controls: controls, metadata: metadata)],
      api: metadata
          ? PluginApi(
              endpoints: [
                ApiEndpoint(
                  id: 'device-settings',
                  type: ApiEndpointType.http,
                  data: {},
                ),
              ],
            )
          : null,
    ),
    settings: const {},
    jsCode: _source(
      id: 'network.grinder',
      controls: controls,
      ble: false,
      metadata: metadata,
    ),
  );
  await load();
  final grinder =
      (await manager.deviceService.devices.firstWhere(
            (devices) => devices.isNotEmpty,
          )).single
          as GrinderDevice;
  return _GrinderFixture(manager, grinder, events, () async {
    await manager.unloadPlugin('network.grinder');
    await load();
    return (await manager.deviceService.devices.firstWhere(
          (devices) => devices.isNotEmpty,
        )).single
        as GrinderDevice;
  });
}

Future<_GrinderFixture> _bleFixture({
  required bool controls,
  bool metadata = false,
}) async {
  final manager = PluginManager(kvStore: FakeKeyValueStoreService());
  final events = <Map<String, dynamic>>[];
  manager.emitStream.listen(events.add);
  final matcher = PluginBleMatcher.fromJson({
    'serviceUuids': ['180f'],
  });
  Future<void> load() => manager.loadPlugin(
    id: 'ble.grinder',
    manifest: testManifest(
      'ble.grinder',
      permissions: {
        PluginPermissions.emit,
        PluginPermissions.transportBle,
        if (metadata) PluginPermissions.api,
      },
      drivers: [_driver(controls: controls, ble: matcher, metadata: metadata)],
      api: metadata
          ? PluginApi(
              endpoints: [
                ApiEndpoint(
                  id: 'device-settings',
                  type: ApiEndpointType.http,
                  data: {},
                ),
              ],
            )
          : null,
    ),
    settings: const {},
    jsCode: _source(
      id: 'ble.grinder',
      controls: controls,
      ble: true,
      metadata: metadata,
    ),
  );
  await load();
  final evidence = BleAdvertisementEvidence(serviceUuids: ['180f']);
  PluginBleFixtureTransport? transport;
  Future<GrinderDevice> create() async =>
      await manager.bleService.createCandidate(
            driver: manager.bleService.registry.decide(evidence).drivers.single,
            physicalId: 'AA:BB',
            evidence: evidence,
            createTransport: () =>
                transport = PluginBleFixtureTransport('AA:BB'),
            admit: () => true,
          )
          as GrinderDevice;
  final grinder = await create();
  return _GrinderFixture(manager, grinder, events, () async {
    await manager.unloadPlugin('ble.grinder');
    await load();
    return create();
  }, currentTransport: () => transport);
}

String _source({
  required String id,
  required bool controls,
  required bool ble,
  bool metadata = false,
}) {
  final handlers =
      '''
    let context;
    return {
      async connect(session) {
        context = session;
        globalThis.currentGrinderContext = session;
        globalThis.oldContext = globalThis.oldContext || session;
        if (globalThis.delayInitialPublication) {
          globalThis.delayInitialPublication = false;
          globalThis.publishInitialPublication = () => session.publish({state: 'idle'});
          return;
        }
        await session.publish({state: 'idle'});
        ${ble && metadata ? '''await session.gatt.subscribe('180f', '2a19', async () => {
          if (globalThis.invalidSnapshot) {
            await context.publish(globalThis.invalidSnapshot);
            return;
          }
          if (!globalThis.failPublication && !globalThis.oversizedInfo) return;
          try {
            if (globalThis.oversizedInfo) {
              await context.publishInfo({controls: {grindSetting: {
                kind: 'enumerated', values: ['x'.repeat(70 * 1024)]
              }}, surfaces: []});
            } else {
              await context.publishInfo({controls: {rpmControl: {kind: 'opaque'}}});
            }
          } catch (error) {
            host.emit('metadataRejected', error.code);
            throw error;
          }
        });''' : ''}
      },
      disconnect() {},
      ${ble ? 'bleEvent() {},' : ''}
      ${controls ? "async start() { host.emit('start', true); await context.publish({state: 'grinding'}); }," : ''}
      ${controls ? "async stop() { await context.publish({state: 'idle', setting: globalThis.setting, rpm: globalThis.rpm}); }," : ''}
      ${controls ? "setGrindSetting(setting) { globalThis.setting = setting; host.emit('setting', setting); }," : ''}
      ${controls ? "setRpm(rpm) { globalThis.rpm = rpm; host.emit('rpm', rpm); }," : ''}
    };
  ''';
  return ble
      ? '''
        function createPlugin(host) {
          return {id: '$id', async onLoad() {
            await host.devices.bindDriver('grinder', {
              create(device) { $handlers }
            });
          }};
        }
      '''
      : '''
        function createPlugin(host) {
          return {id: '$id', async onLoad() {
            await host.devices.register(
              {driverId: 'grinder', instanceId: 'one', name: 'Contract Grinder'},
              (() => { $handlers })()
            );
          }};
        }
      ''';
}

Future<void> _flushJs(PluginManager manager) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
    while (manager.js.executePendingJob() > 0) {}
  }
}
