import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_device_scanner.dart';
import '../../helpers/mock_scale_controller.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

class _GatedDiscoveryService implements DeviceDiscoveryService {
  final _devices = BehaviorSubject<List<Device>>.seeded(const []);
  final scanStarted = Completer<void>();
  final scanFinished = Completer<void>();
  Completer<void>? _gate;
  int initializeCount = 0;
  int scanCallCount = 0;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  void holdScans() => _gate = Completer<void>();

  void releaseScans() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> initialize() async {
    initializeCount++;
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    scanCallCount++;
    if (!scanStarted.isCompleted) scanStarted.complete();
    final gate = _gate;
    if (gate != null) await gate.future;
    if (!scanFinished.isCompleted) scanFinished.complete();
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  void dispose() => _devices.close();
}

class _ConnectedMachine implements De1Interface {
  @override
  String get deviceId => 'connected-machine';
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late MockDeviceScanner scanner;
  late MockScaleController scales;
  late DeviceController devices;
  late ConnectionManager manager;
  late DevicesHandler handler;
  late HttpServer server;

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Condition did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    scanner = MockDeviceScanner();
    scales = MockScaleController();
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    final machines = MockDe1Controller(controller: devices);
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    await settings.setPreferredScaleId('preferred-scale');
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: machines,
      scaleController: scales,
      settingsController: settings,
    );
    machines.de1Subject.add(_ConnectedMachine());
    await Future<void>.delayed(Duration.zero);
    scanner.scanCompleter = Completer<void>();
    handler = DevicesHandler(controller: devices, connectionManager: manager);
    final router = Router().plus;
    handler.addRoutes(router);
    server = await shelf_io.serve(router.call, InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    if (scanner.scanCompleter?.isCompleted == false) scanner.completeScan();
    await server.close(force: true);
    handler.dispose();
    await manager.dispose();
    scanner.dispose();
    devices.dispose();
  });

  for (final option in [null, false, true]) {
    for (final quick in [false, true]) {
      test('REST option=$option quick=$quick selects only the opted-in shortcut', () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final query =
            '?connect=true&quick=$quick${option == null ? '' : '&connectPreferredScaleEarly=$option'}';
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/api/v1/devices/scan$query',
          ),
        );
        final response = request.close();
        await waitFor(() => scanner.scanCallCount == 1);
        final scale = TestScale(deviceId: 'preferred-scale');
        scanner.addDevice(scale);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scanner.stopScanCallCount, option == true ? 1 : 0);
        expect(scales.connectCalls, isEmpty);
        scanner.completeScan();
        expect((await response).statusCode, 200);
        await waitFor(() => scales.connectCalls.isNotEmpty);
        expect(scales.connectCalls, [same(scale)]);
      });
    }

    test(
      'WebSocket option=$option selects only the opted-in shortcut',
      () async {
        final socket = IOWebSocketChannel.connect(
          'ws://127.0.0.1:${server.port}/ws/v1/devices',
        );
        await socket.ready;
        final subscription = socket.stream.listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await socket.sink.close();
        });
        socket.sink.add(
          jsonEncode({
            'command': 'scan',
            'connect': true,
            'connectPreferredScaleEarly': ?option,
          }),
        );
        await waitFor(() => scanner.scanCallCount == 1);
        final scale = TestScale(deviceId: 'preferred-scale');
        scanner.addDevice(scale);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scanner.stopScanCallCount, option == true ? 1 : 0);
        expect(scales.connectCalls, isEmpty);
        scanner.completeScan();
        await waitFor(() => scales.connectCalls.isNotEmpty);
        expect(scales.connectCalls, [same(scale)]);
      },
    );
  }

  test('REST discovery-only ignores the shortcut', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${server.port}/api/v1/devices/scan?connect=false&connectPreferredScaleEarly=true',
      ),
    );
    expect((await request.close()).statusCode, 200);
    expect(scanner.scanCallCount, 0);
    expect(scanner.stopScanCallCount, 0);
    expect(scales.connectCalls, isEmpty);
  });

  group('external scan before startup core readiness', () {
    late _GatedDiscoveryService discovery;
    late DeviceController controller;
    late ConnectionManager externalManager;
    late DevicesHandler externalHandler;
    late HttpServer externalServer;
    late AppStartupCoordinator coordinator;
    late HttpClient client;
    late int webUIInitializations;

    setUp(() async {
      discovery = _GatedDiscoveryService()..holdScans();
      controller = DeviceController([discovery]);
      final machines = MockDe1Controller(controller: controller);
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      externalManager = ConnectionManager(
        deviceScanner: controller,
        de1Controller: machines,
        scaleController: MockScaleController(),
        settingsController: settings,
      );
      externalHandler = DevicesHandler(
        controller: controller,
        connectionManager: externalManager,
      );
      final router = Router().plus;
      externalHandler.addRoutes(router);
      externalServer = await shelf_io.serve(
        router.call,
        InternetAddress.loopbackIPv4,
        0,
      );
      webUIInitializations = 0;
      coordinator = AppStartupCoordinator(
        deviceController: controller,
        initializeWebUI: () async => webUIInitializations++,
        isAndroid: false,
      );
      client = HttpClient();
    });

    tearDown(() async {
      discovery.releaseScans();
      client.close(force: true);
      coordinator.dispose();
      await externalServer.close(force: true);
      externalHandler.dispose();
      await externalManager.dispose();
      discovery.dispose();
      controller.dispose();
    });

    void expectStartupCoreUntouched() {
      expect(
        discovery.initializeCount,
        0,
        reason: 'external scan must not initialize discovery services',
      );
      expect(
        webUIInitializations,
        0,
        reason: 'external scan must not start WebUI startup',
      );
      expect(
        coordinator.initializationFuture,
        isNull,
        reason: 'external scan must not call ensureInitialized',
      );
      expect(coordinator.status, AppStartupStatus.idle);
      expect(
        controller.currentAdapterState,
        AdapterState.unknown,
        reason: 'external scan must not start BLE adapter/permission work',
      );
    }

    Future<IOWebSocketChannel> connectDevicesSocket(
      List<Map<String, dynamic>> messages,
      Completer<void> firstSnapshot,
    ) async {
      final socket = IOWebSocketChannel.connect(
        'ws://127.0.0.1:${externalServer.port}/ws/v1/devices',
      );
      await socket.ready;
      final subscription = socket.stream.listen((message) {
        messages.add(jsonDecode(message.toString()) as Map<String, dynamic>);
        if (!firstSnapshot.isCompleted) firstSnapshot.complete();
      });
      addTearDown(() async {
        await subscription.cancel();
        await socket.sink.close();
      });
      return socket;
    }

    Future<void> awaitScanStart() {
      return discovery.scanStarted.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('external scan never reached discovery services'),
      );
    }

    Future<void> waitForPostScanSnapshot(
      List<Map<String, dynamic>> messages,
      int seenBeforeRelease,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!messages
          .skip(seenBeforeRelease)
          .any((snapshot) => snapshot['scanning'] == false)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('devices socket never reported a settled scan');
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('REST discovery-only scans with startup core still idle', () async {
      final request = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${externalServer.port}/api/v1/devices/scan?connect=false',
        ),
      );
      final pending = request.close();

      await awaitScanStart();
      expect(discovery.scanCallCount, 1);
      expectStartupCoreUntouched();

      discovery.releaseScans();
      final response = await pending;
      expect(response.statusCode, 200);
      final body = await response.transform(utf8.decoder).join();
      expect(jsonDecode(body), isEmpty);
      expect(controller.isScanning, isFalse);
      expectStartupCoreUntouched();
    });

    test(
      'REST default connect=true scans with startup core still idle',
      () async {
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${externalServer.port}/api/v1/devices/scan',
          ),
        );
        final pending = request.close();

        await awaitScanStart();
        expect(discovery.scanCallCount, 1);
        expectStartupCoreUntouched();

        discovery.releaseScans();
        final response = await pending;
        expect(response.statusCode, 200);
        expect(externalManager.lastScanReport, isNotNull);
        expect(discovery.initializeCount, 0);
        expectStartupCoreUntouched();
      },
    );

    test(
      'devices-WebSocket discovery-only scan runs with startup core idle',
      () async {
        final messages = <Map<String, dynamic>>[];
        final firstSnapshot = Completer<void>();
        final socket = await connectDevicesSocket(messages, firstSnapshot);
        await firstSnapshot.future;

        socket.sink.add(jsonEncode({'command': 'scan', 'connect': false}));
        await awaitScanStart();
        expect(discovery.scanCallCount, 1);
        expectStartupCoreUntouched();

        final seenBeforeRelease = messages.length;
        discovery.releaseScans();
        await discovery.scanFinished.future;
        await waitForPostScanSnapshot(messages, seenBeforeRelease);
        expect(discovery.initializeCount, 0);
        expectStartupCoreUntouched();
      },
    );

    test(
      'devices-WebSocket default scan connects with startup core idle',
      () async {
        final messages = <Map<String, dynamic>>[];
        final firstSnapshot = Completer<void>();
        final socket = await connectDevicesSocket(messages, firstSnapshot);
        await firstSnapshot.future;
        final report = externalManager.scanReportStream.first;

        socket.sink.add(jsonEncode({'command': 'scan'}));
        await awaitScanStart();
        expect(discovery.scanCallCount, 1);
        expectStartupCoreUntouched();

        discovery.releaseScans();
        await report.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('devices-WebSocket connect scan never reported'),
        );
        expect(discovery.initializeCount, 0);
        expectStartupCoreUntouched();
      },
    );
  });
}
