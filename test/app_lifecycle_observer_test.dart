import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/test_de1.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {
  _FakePluginLoaderService({this.calls});

  final List<String>? calls;
  final disposed = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    calls?.add('plugins');
    disposeCalls += 1;
    return disposed.future;
  }
}

class _FakeConnectionManager extends Fake implements ConnectionManager {
  _FakeConnectionManager({
    required this.calls,
    Future<void> Function()? shutdown,
  }) : _shutdown = shutdown ?? _complete;

  final List<String> calls;
  final Future<void> Function() _shutdown;

  static Future<void> _complete() async {}

  @override
  Future<void> shutdown() async {
    calls.add('connections');
    await _shutdown();
  }
}

class _FakeCredentialStore extends Fake implements CredentialStore {}

Future<AppLogUploadService> _createAppLogUploadService() async {
  SharedPreferences.setMockInitialValues({});
  final credentials = _FakeCredentialStore();
  return AppLogUploadService(
    accountService: DecentAccountService(
      httpClient: http_testing.MockClient(
        (_) async => http.Response('ok', 200),
      ),
      credentialStore: credentials,
    ),
    consentStore: AccountConsentStore(credentialStore: credentials),
    preferences: await SharedPreferences.getInstance(),
    logFilePath: 'unused.log',
    machineIdentity: () => null,
  );
}

class _StreamDe1Controller extends De1Controller {
  _StreamDe1Controller(this.machineStream)
    : super(controller: DeviceController(const []));

  final Stream<De1Interface?> machineStream;

  @override
  Stream<De1Interface?> get de1 => machineStream;
}

class _SlowCancelDe1 extends TestDe1 {
  _SlowCancelDe1(this.releaseCancellation);

  final Completer<void> releaseCancellation;
  late final StreamController<MachineSnapshot> snapshots =
      StreamController<MachineSnapshot>(
        onCancel: () => releaseCancellation.future,
      );

  @override
  Stream<MachineSnapshot> get currentSnapshot => snapshots.stream;

  @override
  Future<void> dispose() async {
    await snapshots.close();
    await super.dispose();
  }
}

void main() {
  testWidgets('desktop exit preserves terminal cleanup order', (tester) async {
    final calls = <String>[];
    final connectionsShutdown = Completer<void>();
    final loader = _FakePluginLoaderService(calls: calls);
    final connectionManager = _FakeConnectionManager(
      calls: calls,
      shutdown: () => connectionsShutdown.future,
    );
    final appLogUploadService = await _createAppLogUploadService();
    final observer = app.AppLifecycleObserver(
      connectionManager: connectionManager,
      pluginLoaderService: loader,
      appLogUploadService: appLogUploadService,
    );
    void listener() {}
    var exitCompleted = false;

    final exit = observer.didRequestAppExit();
    unawaited(exit.then((_) => exitCompleted = true));
    await tester.pump();

    expect(calls, ['connections']);
    expect(loader.disposeCalls, 0);
    expect(exitCompleted, isFalse);

    connectionsShutdown.complete();
    await tester.pump();
    expect(calls, ['connections', 'plugins']);
    expect(loader.disposeCalls, 1);
    expect(exitCompleted, isFalse);
    appLogUploadService.addListener(listener);
    appLogUploadService.removeListener(listener);

    loader.disposed.complete();
    await expectLater(exit, completion(AppExitResponse.exit));
    expect(() => appLogUploadService.addListener(listener), throwsFlutterError);

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(calls, ['connections', 'plugins']);
    expect(loader.disposeCalls, 1);
  });

  testWidgets('desktop exit ignores background states and isolates failures', (
    tester,
  ) async {
    final calls = <String>[];
    final loader = _FakePluginLoaderService(calls: calls);
    final connectionManager = _FakeConnectionManager(
      calls: calls,
      shutdown: () => Future.error(StateError('shutdown failed')),
    );
    final observer = app.AppLifecycleObserver(
      connectionManager: connectionManager,
      pluginLoaderService: loader,
    );

    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    expect(calls, isEmpty);
    expect(loader.disposeCalls, 0);

    final exit = observer.didRequestAppExit();
    await tester.pump();
    expect(calls, ['connections', 'plugins']);
    expect(loader.disposeCalls, 1);

    loader.disposed.complete();
    await expectLater(exit, completion(AppExitResponse.exit));

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(calls, ['connections', 'plugins']);
  });

  testWidgets('detached cannot install a replacement state subscription', (
    tester,
  ) async {
    final loader = _FakePluginLoaderService();
    final releaseCancellation = Completer<void>();
    final firstMachine = _SlowCancelDe1(releaseCancellation);
    final secondMachine = TestDe1(deviceId: 'second');
    final machines = StreamController<De1Interface?>.broadcast(sync: true);
    final controller = _StreamDe1Controller(machines.stream);
    final observer = app.AppLifecycleObserver(
      de1Controller: controller,
      pluginLoaderService: loader,
    );

    machines.add(firstMachine);
    expect(firstMachine.snapshots.hasListener, isTrue);
    loader.disposed.complete();

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    machines.add(secondMachine);
    releaseCancellation.complete();
    await tester.pump();
    await tester.pump();

    expect(secondMachine.snapshotSubject.hasListener, isFalse);

    await machines.close();
    await controller.dispose();
    await firstMachine.dispose();
    await secondMachine.dispose();
  });
}
