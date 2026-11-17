import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('resume after detach cannot repeat plugin cleanup', (
    tester,
  ) async {
    final loader = _FakePluginLoaderService();
    final observer = app.AppLifecycleObserver(pluginLoaderService: loader);
    loader.disposed.complete();

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(loader.disposeCalls, 1);
  });
}
