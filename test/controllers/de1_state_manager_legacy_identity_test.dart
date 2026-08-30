import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/registered_decent_machine.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';

class _IdentityTestDe1Controller extends De1Controller {
  final BehaviorSubject<De1Interface?> de1Subject = BehaviorSubject.seeded(
    null,
  );
  De1Interface? current;
  int _generation = 0;

  _IdentityTestDe1Controller({required super.controller});

  @override
  Stream<De1Interface?> get de1 => de1Subject.stream;

  @override
  De1Interface connectedDe1() {
    final de1 = current;
    if (de1 == null) throw 'no de1 connected';
    return de1;
  }

  @override
  De1Interface? get connectedDe1OrNull => current;

  @override
  int get connectionGeneration => _generation;

  void connect(De1Interface de1) {
    _generation++;
    current = de1;
    de1Subject.add(de1);
  }

  void disconnect() {
    _generation++;
    current = null;
    de1Subject.add(null);
  }
}

class _FakeCredentialStore implements CredentialStore {
  final Map<String, String> _store = {};
  Completer<void>? emailReadStarted;
  Completer<void>? emailReadRelease;
  String? failingReadKey;

  @override
  Future<String?> read({required String key}) async {
    if (key == failingReadKey) throw StateError('read failed: $key');
    final release = emailReadRelease;
    if (key == 'email' && release != null) {
      emailReadStarted?.complete();
      await release.future;
      if (identical(emailReadRelease, release)) {
        emailReadStarted = null;
        emailReadRelease = null;
      }
    }
    return _store[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}

class _EmptyStorageService implements StorageService {
  @override
  Future<void> storeShot(ShotRecord record) async {}
  @override
  Future<void> updateShot(ShotRecord record) async {}
  @override
  Future<void> deleteShot(String id) async {}
  @override
  Future<List<String>> getShotIds() async => [];
  @override
  Future<List<ShotRecord>> getAllShots() async => [];
  @override
  Future<ShotRecord?> getShot(String id) async => null;
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}
  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;
  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async => [];
  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
  }) async => 0;
  @override
  Future<ShotRecord?> getLatestShot() async => null;
  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;
  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

class _FakeBleTransportWithId extends FakeBleTransport {
  _FakeBleTransportWithId(this.customId);

  final String customId;

  @override
  String get id => customId;
}

class _SequencedMappingAccountService extends DecentAccountService {
  _SequencedMappingAccountService(CredentialStore store)
    : super(
        httpClient: http_testing.MockClient(
          (_) async => http.Response('', 200),
        ),
        credentialStore: store,
      );

  final firstLookupStarted = Completer<void>();
  final firstLookupRelease = Completer<void>();
  int lookupCount = 0;

  final List<RegisteredDecentMachine> machines = [
    RegisteredDecentMachine.fromJson(const {
      'serial': '1337',
      'sku': 'DE-DE1220V-00001',
      'model': 'DE1',
    }),
    RegisteredDecentMachine.fromJson(const {
      'serial': '1338',
      'sku': 'DE-DE1PRO220V7-00533',
      'model': 'DE1Pro',
    }),
  ];

  @override
  Future<void> get accountReady => Future.value();

  @override
  Future<bool> isAuthKnownInvalid() async => false;

  @override
  List<RegisteredDecentMachine> get usableRegisteredMachines => machines;

  @override
  Future<RegisteredDecentMachine?> lookupMapping({
    required String transportType,
    required String deviceId,
  }) async {
    final index = lookupCount++;
    if (index == 0) {
      firstLookupStarted.complete();
      await firstLookupRelease.future;
    }
    return machines[index];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _IdentityTestDe1Controller de1Controller;
  late _FakeCredentialStore store;
  late De1StateManager manager;
  late GlobalKey<NavigatorState> navigatorKey;
  late DeviceController deviceController;

  http_testing.MockClient machinesClient(
    List<Map<String, dynamic>> machines, {
    List<String> emailRequests = const [],
  }) {
    return http_testing.MockClient((request) async {
      final path = request.url.path;
      if (path == '/support/api/login_test') {
        return http.Response('cryptpw_abc123\n', 200);
      }
      if (path == '/support/api/sn') {
        return http.Response(
          '${[for (final m in machines) '${m['serial']} ${m['sku']}'].join('\n')}\n',
          200,
        );
      }
      if (path == '/support/api/email') {
        (emailRequests as List).add(request.url.toString());
        return http.Response('1', 200);
      }
      return http.Response('0\n', 200);
    });
  }

  Future<void> seedAccount(
    List<Map<String, dynamic>> machines, {
    bool withCredentials = true,
  }) async {
    if (withCredentials) {
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw_abc123');
    }
    await store.write(
      key: 'registered_machines',
      value: jsonEncode({
        'account': withCredentials ? 'user@example.com' : null,
        'machines': machines,
      }),
    );
  }

  Future<DecentAccountService> seededService(
    List<Map<String, dynamic>> machines, {
    bool withCredentials = true,
    List<String> emailRequests = const [],
  }) async {
    final service = DecentAccountService(
      httpClient: machinesClient(machines, emailRequests: emailRequests),
      credentialStore: store,
    );
    await seedAccount(machines, withCredentials: withCredentials);
    await service.initialize();
    return service;
  }

  Future<void> mountTestApp(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('home')),
        onGenerateRoute: (settings) {
          if (settings.name == AccountPage.routeName) {
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('AccountPage stub')),
            );
          }
          return null;
        },
      ),
    );
  }

  Future<De1StateManager> createManager(
    WidgetTester tester, {
    DecentAccountService? accountService,
    bool mountNavigator = true,
  }) async {
    final scaleController = ScaleController();
    final settingsService = MockSettingsService();
    await settingsService.updateGatewayMode(GatewayMode.tracking);
    final settingsController = SettingsController(settingsService);
    await settingsController.loadSettings();
    final connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );
    navigatorKey = GlobalKey<NavigatorState>();
    manager = De1StateManager(
      de1Controller: de1Controller,
      scaleController: scaleController,
      workflowController: WorkflowController(),
      persistenceController: PersistenceController(
        storageService: _EmptyStorageService(),
      ),
      settingsController: settingsController,
      connectionManager: connectionManager,
      accountService: accountService,
      navigatorKey: navigatorKey,
    );
    if (mountNavigator) await mountTestApp(tester);
    return manager;
  }

  Future<UnifiedDe1> connectMachine(
    WidgetTester tester, {
    int v13Model = 0,
    int serialN = 0,
    String deviceId = 'fake-ble',
  }) async {
    final transport = _FakeBleTransportWithId(deviceId)
      ..queueOnConnectResponses(v13Model: v13Model, serialN: serialN);
    final de1 = UnifiedDe1(transport: transport);
    // MMR reads use timer-based timeouts, so connect outside the FakeAsync
    // test zone.
    await tester.runAsync(() => de1.onConnect());
    de1Controller.connect(de1);
    return de1;
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    await action();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Disconnects the machine inside the test body so ConnectionManager's
  /// snapshot-staleness watchdog is cancelled before the widget tree is
  /// disposed (the pending-timer invariant).
  Future<void> disconnectAndSettle(WidgetTester tester) async {
    de1Controller.disconnect();
    await tester.pump();
  }

  setUp(() async {
    store = _FakeCredentialStore();
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = _IdentityTestDe1Controller(controller: deviceController);
  });

  tearDown(() async {
    manager.dispose();
    de1Controller.disconnect();
  });

  testWidgets('exact nonzero serial match applies the effective identity', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 4, serialN: 1338);
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    // API model overrides the conflicting raw v13Model=4 (DE1XL).
    expect(de1.machineInfo.model, 'DE1Pro');
    expect(de1.rawMachineInfo.serialNumber, '1338');
    expect(de1Controller.seenSerials, contains('1338'));
    await disconnectAndSettle(tester);
  });

  testWidgets('unknown SKU retains the raw model on exact serial match', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1338', 'sku': 'DE-SOMETHINGELSE'},
    ]);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 3, serialN: 1338);
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    expect(de1.machineInfo.model, 'DE1Pro');
    await disconnectAndSettle(tester);
  });

  testWidgets('serial 0 with a single legacy candidate resolves without a '
      'dialog', (tester) async {
    final accountService = await seededService(const [
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    expect(de1.machineInfo.model, 'DE1Pro');
    expect(find.text('Select your machine'), findsNothing);
    await disconnectAndSettle(tester);
  });

  testWidgets(
    'ambiguous candidates show the selection dialog and manual choice '
    'persists a mapping',
    (tester) async {
      final accountService = await seededService(const [
        {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
      ]);
      await createManager(tester, accountService: accountService);

      final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
      await pumpUntil(tester, () async {});

      expect(find.text('Select your machine'), findsOneWidget);

      await tester.tap(find.textContaining('1338 · DE1Pro'));
      await pumpUntil(tester, () async {});

      expect(de1.machineInfo.serialNumber, '1338');
      final mapped = await accountService.lookupMapping(
        transportType: 'ble',
        deviceId: de1.deviceId,
      );
      expect(mapped?.serial, '1338');
      await disconnectAndSettle(tester);
    },
  );

  testWidgets('disconnect dismisses an active identity selection dialog', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Select your machine'), findsOneWidget);

    await disconnectAndSettle(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Select your machine'), findsNothing);
  });

  testWidgets('disconnect removes only its identity dialog', (tester) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});
    expect(find.text('Select your machine'), findsOneWidget);

    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other route')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Other route'), findsOneWidget);

    de1Controller.disconnect();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Other route'), findsOneWidget);
    navigatorKey.currentState!.pop();
    await tester.pump();
    expect(find.text('Select your machine'), findsNothing);
  });

  testWidgets('disconnect during account lookup does not open a stale dialog', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await accountService.accountReady;
    await createManager(tester, accountService: accountService);
    final readStarted = Completer<void>();
    final readRelease = Completer<void>();
    store.emailReadStarted = readStarted;
    store.emailReadRelease = readRelease;

    await connectMachine(tester, v13Model: 0, serialN: 0);
    await readStarted.future;
    de1Controller.disconnect();
    readRelease.complete();
    await pumpUntil(tester, () async {});

    expect(find.text('Select your machine'), findsNothing);
    expect(find.text('Link your Decent account'), findsNothing);
  });

  testWidgets('same machine reconnect rejects the prior generation lookup', (
    tester,
  ) async {
    final accountService = _SequencedMappingAccountService(store);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await accountService.firstLookupStarted.future;

    de1Controller.disconnect();
    de1Controller.connect(de1);
    await tester.pump();

    accountService.firstLookupRelease.complete();
    await pumpUntil(tester, () async {});

    expect(accountService.lookupCount, 2);
    expect(de1.machineInfo.serialNumber, '1338');
    await disconnectAndSettle(tester);
  });

  testWidgets('a persisted mapping is reused on reconnect without a dialog', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await accountService.saveMapping(
      transportType: 'ble',
      deviceId: 'fake-ble',
      serial: '1338',
    );
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    expect(find.text('Select your machine'), findsNothing);
    await disconnectAndSettle(tester);
  });

  testWidgets('account replacement revokes and resolves effective identity', (
    tester,
  ) async {
    final machines = <Map<String, dynamic>>[
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
    ];
    final accountService = await seededService(machines);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});
    expect(de1.machineInfo.serialNumber, '1337');

    await accountService.logout();
    await pumpUntil(tester, () async {});
    expect(de1.machineInfo.serialNumber, '0');

    machines
      ..clear()
      ..add({
        'serial': '1338',
        'sku': 'DE-DE1PRO220V7-00533',
        'model': 'DE1Pro',
      });
    expect(await accountService.login('new@example.com', 'password'), isTrue);
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    expect(de1.machineInfo.model, 'DE1Pro');
    await disconnectAndSettle(tester);
  });

  testWidgets('a changed device id falls back to normal matching', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    // Mapping was recorded against a previous device id.
    await accountService.saveMapping(
      transportType: 'ble',
      deviceId: 'old-device-id',
      serial: '1338',
    );
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(
      tester,
      v13Model: 0,
      serialN: 0,
      deviceId: 'new-device-id',
    );
    await pumpUntil(tester, () async {});

    // Mapping missed; ambiguous candidates fall back to the dialog.
    expect(find.text('Select your machine'), findsOneWidget);
    expect(de1.machineInfo.serialNumber, '0');
    await disconnectAndSettle(tester);
  });

  testWidgets('dismissing the selection dialog leaves raw identity untouched', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    await tester.tap(find.text('Cancel'));
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    await disconnectAndSettle(tester);
  });

  testWidgets('no linked account prompts to link but dismissal keeps the '
      'machine usable', (tester) async {
    final accountService = await seededService(
      const [],
      withCredentials: false,
    );
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsNothing);
    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    await disconnectAndSettle(tester);
  });

  testWidgets('a preconnected machine prompts after the navigator mounts', (
    tester,
  ) async {
    final accountService = await seededService(
      const [],
      withCredentials: false,
    );
    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await createManager(
      tester,
      accountService: accountService,
      mountNavigator: false,
    );
    await tester.pump();

    expect(de1.machineInfo.serialNumber, '0');

    await tester.pump(const Duration(milliseconds: 600));
    await mountTestApp(tester);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Link your Decent account'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await pumpUntil(tester, () async {});
    await disconnectAndSettle(tester);
  });

  testWidgets('accepting the link prompt navigates to AccountPage and retries '
      'resolution once', (tester) async {
    // The mock account starts with no machines; after linking, the account
    // lists the connected machine so the post-link refresh can resolve it.
    final machines = <Map<String, dynamic>>[];
    final accountService = await seededService(
      machines,
      withCredentials: false,
    );
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    await tester.tap(find.text('Link account'));
    await pumpUntil(tester, () async {});

    expect(find.text('AccountPage stub'), findsOneWidget);

    // User links an account that lists the machine, then returns.
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    machines.add({
      'serial': '1338',
      'sku': 'DE-DE1PRO220V7-00533',
      'model': 'DE1Pro',
    });
    await accountService.initialize();

    navigatorKey.currentState!.pop();
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '1338');
    expect(de1.machineInfo.model, 'DE1Pro');
    await disconnectAndSettle(tester);
  });

  testWidgets(
    'after linking, an account with two candidates shows the selection dialog',
    (tester) async {
      final machines = <Map<String, dynamic>>[];
      final accountService = await seededService(
        machines,
        withCredentials: false,
      );
      await createManager(tester, accountService: accountService);

      final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
      await pumpUntil(tester, () async {});

      await tester.tap(find.text('Link account'));
      await pumpUntil(tester, () async {});

      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw_abc123');
      machines.add({
        'serial': '1337',
        'sku': 'DE-DE1220V-00001',
        'model': 'DE1',
      });
      machines.add({
        'serial': '1338',
        'sku': 'DE-DE1PRO220V7-00533',
        'model': 'DE1Pro',
      });
      await accountService.initialize();

      navigatorKey.currentState!.pop();
      await pumpUntil(tester, () async {});

      expect(find.text('Select your machine'), findsOneWidget);
      expect(find.textContaining('1337'), findsOneWidget);
      expect(find.textContaining('1338'), findsOneWidget);

      await tester.tap(find.textContaining('1338'));
      await pumpUntil(tester, () async {});

      expect(de1.machineInfo.serialNumber, '1338');
      expect(de1.machineInfo.model, 'DE1Pro');
      await disconnectAndSettle(tester);
    },
  );

  testWidgets('cancelling the account page does not re-prompt to link', (
    tester,
  ) async {
    final accountService = await seededService(
      const [],
      withCredentials: false,
    );
    await createManager(tester, accountService: accountService);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsOneWidget);

    await tester.tap(find.text('Link account'));
    await pumpUntil(tester, () async {});

    expect(find.text('AccountPage stub'), findsOneWidget);

    // Back out of the account flow without linking anything.
    navigatorKey.currentState!.pop();
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsNothing);
    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    await disconnectAndSettle(tester);
  });

  testWidgets('a machine connected before the navigator mounts still prompts '
      'once navigation is ready', (tester) async {
    final accountService = await seededService(
      const [],
      withCredentials: false,
    );
    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);

    // The manager subscribes to the replaying DE1 stream before the widget
    // tree (and thus the navigator context) exists.
    await createManager(tester, accountService: accountService);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    await disconnectAndSettle(tester);
  });

  testWidgets('disconnecting dismisses an open selection dialog', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Select your machine'), findsOneWidget);

    de1Controller.disconnect();
    await pumpUntil(tester, () async {});

    expect(find.text('Select your machine'), findsNothing);
    expect(find.text('Link your Decent account'), findsNothing);
    await tester.pumpWidget(Container());
  });

  testWidgets('credential read errors do not escape identity resolution', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await accountService.accountReady;
    await createManager(tester, accountService: accountService);
    store.failingReadKey = 'email';

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(tester.takeException(), isNull);
    expect(de1.machineInfo.serialNumber, '0');
    expect(find.text('Select your machine'), findsNothing);
    store.failingReadKey = null;
    await disconnectAndSettle(tester);
  });

  testWidgets(
    'a real nonzero serial not on the account still reports the mismatch',
    (tester) async {
      final emailRequests = <String>[];
      final accountService = await seededService(const [
        {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
      ], emailRequests: emailRequests);
      await createManager(tester, accountService: accountService);

      await connectMachine(tester, v13Model: 3, serialN: 9999);
      await pumpUntil(tester, () async {});
      await pumpUntil(tester, () async {});

      expect(
        emailRequests.any((url) => url.contains('/support/api/email')),
        isTrue,
      );
      expect(emailRequests.first, contains('9999'));
      await disconnectAndSettle(tester);
    },
  );

  testWidgets('no prompt or resolution applies for mock or Bengle machines', (
    tester,
  ) async {
    final accountService = await seededService(const [
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    // MockDe1 reports implementation unifiedDe1 but is not a UnifiedDe1.
    final mockDe1 = MockDe1();
    de1Controller.connect(mockDe1);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsNothing);
    expect(find.text('Select your machine'), findsNothing);
    await mockDe1.dispose();
    await disconnectAndSettle(tester);
  });

  testWidgets(
    'a UnifiedDe1 reporting a Bengle model value never enters identity '
    'resolution',
    (tester) async {
      final accountService = await seededService(const [
        {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
      ]);
      await createManager(tester, accountService: accountService);

      final de1 = await connectMachine(tester, v13Model: 129, serialN: 0);
      await pumpUntil(tester, () async {});

      expect(de1.machineInfo.serialNumber, '0');
      expect(de1.machineInfo.model, 'Bengle');
      expect(de1Controller.seenSerials, isNot(contains('1338')));
      expect(find.text('Link your Decent account'), findsNothing);
      expect(find.text('Select your machine'), findsNothing);
      await disconnectAndSettle(tester);
    },
  );

  testWidgets(
    'a Bengle UnifiedDe1 with a real nonzero serial still runs serial '
    'ownership verification without identity resolution',
    (tester) async {
      final emailRequests = <String>[];
      final accountService = await seededService(const [
        {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
      ], emailRequests: emailRequests);
      await createManager(tester, accountService: accountService);

      final de1 = await connectMachine(tester, v13Model: 129, serialN: 9999);
      await pumpUntil(tester, () async {});
      await pumpUntil(tester, () async {});

      expect(de1.machineInfo.serialNumber, '9999');
      expect(de1.machineInfo.model, 'Bengle');
      expect(
        emailRequests.any((url) => url.contains('/support/api/email')),
        isTrue,
      );
      expect(emailRequests.first, contains('9999'));
      expect(find.text('Link your Decent account'), findsNothing);
      expect(find.text('Select your machine'), findsNothing);
      await disconnectAndSettle(tester);
    },
  );

  testWidgets(
    'a machine connecting during the startup refresh resolves once the '
    'refresh completes',
    (tester) async {
      final snGate = Completer<void>();
      final client = http_testing.MockClient((request) async {
        if (request.url.path == '/support/api/login_test') {
          return http.Response('cryptpw_abc123\n', 200);
        }
        if (request.url.path == '/support/api/sn') {
          await snGate.future;
          return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
        }
        return http.Response('0\n', 200);
      });
      final service = DecentAccountService(
        httpClient: client,
        credentialStore: store,
      );
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw_abc123');
      await service.initialize();
      await createManager(tester, accountService: service);

      final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
      await pumpUntil(tester, () async {});

      // Refresh still pending: resolution must wait, not resolve empty.
      expect(de1.machineInfo.serialNumber, '0');

      snGate.complete();
      await pumpUntil(tester, () async {});

      expect(de1.machineInfo.serialNumber, '1338');
      expect(de1.machineInfo.model, 'DE1Pro');
      await disconnectAndSettle(tester);
    },
  );

  testWidgets(
    'a machine replaced while the startup refresh is pending is not mutated',
    (tester) async {
      final snGate = Completer<void>();
      final client = http_testing.MockClient((request) async {
        if (request.url.path == '/support/api/login_test') {
          return http.Response('cryptpw_abc123\n', 200);
        }
        if (request.url.path == '/support/api/sn') {
          await snGate.future;
          return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
        }
        return http.Response('0\n', 200);
      });
      final service = DecentAccountService(
        httpClient: client,
        credentialStore: store,
      );
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw_abc123');
      await service.initialize();
      await createManager(tester, accountService: service);

      final first = await connectMachine(tester, v13Model: 0, serialN: 0);
      await pumpUntil(tester, () async {});

      // Replace the machine while the refresh is still pending.
      final second = await connectMachine(tester, v13Model: 0, serialN: 0);
      await pumpUntil(tester, () async {});

      snGate.complete();
      await pumpUntil(tester, () async {});

      // The stale machine must never be mutated.
      expect(first.machineInfo.serialNumber, '0');
      expect(first.machineInfo.model, 'Unknown');
      expect(second.machineInfo.serialNumber, '1338');
      await disconnectAndSettle(tester);
    },
  );

  testWidgets('a linked account with a transient refresh failure keeps the raw '
      'identity and does not prompt to link again', (tester) async {
    final client = http_testing.MockClient((request) async {
      if (request.url.path == '/support/api/login_test') {
        return http.Response('cryptpw_abc123\n', 200);
      }
      if (request.url.path == '/support/api/sn') {
        throw Exception('timeout');
      }
      return http.Response('0\n', 200);
    });
    final service = DecentAccountService(
      httpClient: client,
      credentialStore: store,
    );
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    await service.initialize();
    await createManager(tester, accountService: service);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsNothing);
    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    await disconnectAndSettle(tester);
  });

  testWidgets('a definitively rejected account still gets the nonblocking '
      'link prompt', (tester) async {
    final client = http_testing.MockClient((request) async {
      return http.Response('0\n', 200);
    });
    final service = DecentAccountService(
      httpClient: client,
      credentialStore: store,
    );
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'stale_cryptpw');
    await service.initialize();
    await createManager(tester, accountService: service);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '0');
    await disconnectAndSettle(tester);
  });

  testWidgets('an account rejection arriving during resolution still prompts '
      'to link', (tester) async {
    final validationStarted = Completer<void>();
    final validationRelease = Completer<void>();
    final client = http_testing.MockClient((request) async {
      if (request.url.path == '/support/api/login_test') {
        validationStarted.complete();
        await validationRelease.future;
      }
      return http.Response('0\n', 200);
    });
    final service = DecentAccountService(
      httpClient: client,
      credentialStore: store,
    );
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'stale_cryptpw');
    await service.initialize();
    await validationStarted.future;
    await createManager(tester, accountService: service);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    validationRelease.complete();
    await pumpUntil(tester, () async {});

    expect(find.text('Link your Decent account'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await pumpUntil(tester, () async {});

    expect(de1.machineInfo.serialNumber, '0');
    await disconnectAndSettle(tester);
  });

  testWidgets('identity prompts skipped while backgrounded are retried on '
      'resume', (tester) async {
    final accountService = await seededService(const [
      {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
      {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
    ]);
    await createManager(tester, accountService: accountService);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    // Prompt suppressed while backgrounded.
    expect(find.text('Select your machine'), findsNothing);
    expect(de1.machineInfo.serialNumber, '0');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpUntil(tester, () async {});

    expect(find.text('Select your machine'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpUntil(tester, () async {});
    await disconnectAndSettle(tester);
  });

  testWidgets(
    'a model-only link prompt skipped in background retries on resume',
    (tester) async {
      final accountService = await seededService(
        const [],
        withCredentials: false,
      );
      await createManager(tester, accountService: accountService);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      await connectMachine(tester, v13Model: 0, serialN: 1338);
      await pumpUntil(tester, () async {});

      expect(find.text('Link your Decent account'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntil(tester, () async {});

      expect(find.text('Link your Decent account'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await pumpUntil(tester, () async {});
      await disconnectAndSettle(tester);
    },
  );

  testWidgets('disposing while the startup refresh is pending leaves the '
      'machine untouched', (tester) async {
    final snGate = Completer<void>();
    final client = http_testing.MockClient((request) async {
      if (request.url.path == '/support/api/login_test') {
        return http.Response('cryptpw_abc123\n', 200);
      }
      if (request.url.path == '/support/api/sn') {
        await snGate.future;
        return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
      }
      return http.Response('0\n', 200);
    });
    final service = DecentAccountService(
      httpClient: client,
      credentialStore: store,
    );
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    await service.initialize();
    await createManager(tester, accountService: service);

    final de1 = await connectMachine(tester, v13Model: 0, serialN: 0);
    await pumpUntil(tester, () async {});

    manager.dispose();
    await tester.pump();

    snGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(de1.machineInfo.serialNumber, '0');
    expect(de1.machineInfo.model, 'Unknown');
    expect(find.text('Select your machine'), findsNothing);
    expect(find.text('Link your Decent account'), findsNothing);
    de1Controller.disconnect();
    await tester.pump();
  });
}
