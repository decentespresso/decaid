import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/simulated_device_service.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/mock_settings_service.dart';

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

class _FakeUpdateCheckService extends Fake implements UpdateCheckService {
  _FakeUpdateCheckService({this.calls});

  final List<String>? calls;
  int resumeCalls = 0;
  int disposeCalls = 0;

  @override
  void onAppResumed() {
    resumeCalls++;
  }

  @override
  void dispose() {
    calls?.add('updates');
    disposeCalls++;
  }
}

class _RecordingUpdater extends AndroidUpdater {
  _RecordingUpdater()
    : super(owner: 'test', repo: 'test', platformIsAndroid: true);

  int checks = 0;
  int disposeCalls = 0;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    return null;
  }

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }
}

class _GatedAutomaticUpdateSettings extends MockSettingsService {
  final gate = Completer<void>();
  int reads = 0;

  @override
  Future<bool> automaticUpdateCheck() async {
    reads++;
    await gate.future;
    return super.automaticUpdateCheck();
  }
}

class _GatedSkinsStorage extends WebUIStorage {
  _GatedSkinsStorage() : super(SettingsController(MockSettingsService()));

  final gate = Completer<void>();
  int updateCalls = 0;

  @override
  Future<void> updateAllSkins() async {
    updateCalls++;
    await gate.future;
  }
}

class _ScriptedSkinsStorage extends WebUIStorage {
  _ScriptedSkinsStorage() : super(SettingsController(MockSettingsService()));

  final gates = <Completer<void>>[];
  int updateCalls = 0;

  @override
  Future<void> updateAllSkins() async {
    updateCalls++;
    if (gates.isNotEmpty) await gates.removeAt(0).future;
  }
}

class _RecordingPluginSourceService extends Fake
    implements PluginSourceService {
  int updateCalls = 0;

  @override
  Future<void> updateAllPlugins() async {
    updateCalls++;
  }
}

class _GatedLastCheckTimeSettings extends MockSettingsService {
  final gate = Completer<void>();
  int reads = 0;

  @override
  Future<DateTime?> lastUpdateCheckTime() async {
    reads++;
    await gate.future;
    return super.lastUpdateCheckTime();
  }
}

class _GatedChannelSettings extends MockSettingsService {
  final gate = Completer<void>();
  int reads = 0;

  @override
  Future<UpdateChannel> updateChannel() async {
    reads++;
    await gate.future;
    return super.updateChannel();
  }
}

class _GatedCheckUpdater extends _RecordingUpdater {
  final gate = Completer<void>();

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    await gate.future;
    return null;
  }
}

UpdateCheckService _sharedUpdateService({
  AndroidUpdater? updater,
  SettingsService? settings,
  WebUIStorage? storage,
  PluginSourceService? pluginSourceService,
  bool externallyManaged = false,
}) => UpdateCheckService(
  settingsService: settings ?? MockSettingsService(),
  webUIStorage:
      storage ?? WebUIStorage(SettingsController(MockSettingsService())),
  pluginSourceService: pluginSourceService,
  updater: updater ?? _RecordingUpdater(),
  platformIsAndroid: true,
  platformIsMacOS: false,
  externallyManaged: externallyManaged,
);

class _GatedSettingsService extends MockSettingsService {
  _GatedSettingsService({this.loadGate, this.failLoad = false});

  final Completer<void>? loadGate;
  final bool failLoad;

  @override
  Future<String> logLevel() async {
    final gate = loadGate;
    if (gate != null) await gate.future;
    if (failLoad) throw StateError('settings load failed');
    return super.logLevel();
  }
}

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
  testWidgets('update service receives only resumed lifecycle events', (
    tester,
  ) async {
    final updates = _FakeUpdateCheckService();
    final observer = app.AppLifecycleObserver(updateCheckService: updates);
    addTearDown(observer.dispose);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      observer.didChangeAppLifecycleState(state);
    }
    expect(updates.resumeCalls, 0);

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(updates.resumeCalls, 1);
    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(updates.resumeCalls, 1);
  });

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

  testWidgets('terminal cleanup releases the shared update service first', (
    tester,
  ) async {
    final calls = <String>[];
    final connectionsShutdown = Completer<void>();
    final updates = _FakeUpdateCheckService(calls: calls);
    final loader = _FakePluginLoaderService(calls: calls);
    final connectionManager = _FakeConnectionManager(
      calls: calls,
      shutdown: () => connectionsShutdown.future,
    );
    final observer = app.AppLifecycleObserver(
      connectionManager: connectionManager,
      pluginLoaderService: loader,
      updateCheckService: updates,
    );

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();

    expect(calls, ['updates', 'connections']);
    expect(updates.disposeCalls, 1);
    expect(loader.disposeCalls, 0);

    connectionsShutdown.complete();
    await tester.pump();

    expect(calls, ['updates', 'connections', 'plugins']);
    expect(loader.disposeCalls, 1);
  });

  testWidgets('repeated terminal cleanup releases the update service once', (
    tester,
  ) async {
    final updates = _FakeUpdateCheckService();
    final observer = app.AppLifecycleObserver(updateCheckService: updates);

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    final exit = observer.didRequestAppExit();
    await tester.pump();

    expect(updates.disposeCalls, 1);
    await expectLater(exit, completion(AppExitResponse.exit));
    expect(updates.disposeCalls, 1);
    expect(updates.resumeCalls, 0);
  });

  testWidgets('removing the lifecycle observer keeps the update service', (
    tester,
  ) async {
    final updates = _FakeUpdateCheckService();
    final observer = app.AppLifecycleObserver(updateCheckService: updates);

    observer.dispose();

    expect(updates.disposeCalls, 0);
  });

  testWidgets('terminal cleanup cancels the scheduled update initialization', (
    tester,
  ) async {
    final updater = _RecordingUpdater();
    final service = _sharedUpdateService(updater: updater);
    final observer = app.AppLifecycleObserver(updateCheckService: service);
    addTearDown(observer.dispose);

    service.scheduleInitialize();
    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump(const Duration(minutes: 1));

    expect(updater.disposeCalls, 1);
    expect(updater.checks, 0);
  });

  testWidgets('an initialization that finishes after disposal starts nothing', (
    tester,
  ) async {
    final settings = _GatedAutomaticUpdateSettings();
    final updater = _RecordingUpdater();
    final service = _sharedUpdateService(updater: updater, settings: settings);

    final initializing = service.initialize();
    await tester.pump();
    expect(settings.reads, 1);

    service.dispose();
    settings.gate.complete();
    await initializing;

    expect(updater.checks, 0);
    expect(updater.disposeCalls, 1);
  });

  testWidgets('managed content finishing after disposal starts no timer', (
    tester,
  ) async {
    final storage = _GatedSkinsStorage();
    final service = _sharedUpdateService(
      storage: storage,
      externallyManaged: true,
    );

    final initializing = service.initialize();
    await tester.pump();
    expect(storage.updateCalls, 1);

    service.dispose();
    storage.gate.complete();
    await initializing;
    await tester.pump(const Duration(hours: 13));

    expect(storage.updateCalls, 1);
  });

  group('shared update service disposal fences', () {
    testWidgets(
      'disposal during the timestamp lookup starts no check or content update',
      (tester) async {
        final settings = _GatedLastCheckTimeSettings();
        final updater = _RecordingUpdater();
        final storage = _ScriptedSkinsStorage();
        final plugins = _RecordingPluginSourceService();
        final service = _sharedUpdateService(
          settings: settings,
          updater: updater,
          storage: storage,
          pluginSourceService: plugins,
        );

        final initializing = service.initialize();
        await tester.pump();
        expect(settings.reads, 1);

        service.dispose();
        settings.gate.complete();
        await initializing;
        await tester.pump(const Duration(hours: 13));

        expect(updater.checks, 0);
        expect(storage.updateCalls, 0);
        expect(plugins.updateCalls, 0);
      },
    );

    testWidgets('disposal during the channel lookup aborts the check', (
      tester,
    ) async {
      final settings = _GatedChannelSettings();
      final updater = _RecordingUpdater();
      final service = _sharedUpdateService(
        settings: settings,
        updater: updater,
      );

      final checking = service.checkForUpdate(quiet: true);
      await tester.pump();
      expect(settings.reads, 1);

      service.dispose();
      settings.gate.complete();
      await checking;

      expect(updater.checks, 0);
    });

    testWidgets('a check finishing after disposal starts no content update', (
      tester,
    ) async {
      final updater = _GatedCheckUpdater();
      final storage = _ScriptedSkinsStorage();
      final plugins = _RecordingPluginSourceService();
      final service = _sharedUpdateService(
        updater: updater,
        storage: storage,
        pluginSourceService: plugins,
      );

      final initializing = service.initialize();
      await tester.pump();
      expect(updater.checks, 1);

      service.dispose();
      updater.gate.complete();
      await initializing;
      await tester.pump(const Duration(hours: 13));

      expect(updater.checks, 1);
      expect(storage.updateCalls, 0);
      expect(plugins.updateCalls, 0);
    });

    testWidgets('skins finishing after disposal start no plugin update', (
      tester,
    ) async {
      final storage = _ScriptedSkinsStorage();
      final plugins = _RecordingPluginSourceService();
      final service = _sharedUpdateService(
        storage: storage,
        pluginSourceService: plugins,
        externallyManaged: true,
      );
      final gate = Completer<void>();
      storage.gates.add(gate);

      final initializing = service.initialize();
      await tester.pump();
      expect(storage.updateCalls, 1);

      service.dispose();
      gate.complete();
      await initializing;

      expect(plugins.updateCalls, 0);
    });

    testWidgets('a periodic callback already running at disposal is fenced', (
      tester,
    ) async {
      final storage = _ScriptedSkinsStorage();
      final plugins = _RecordingPluginSourceService();
      final service = _sharedUpdateService(
        storage: storage,
        pluginSourceService: plugins,
        externallyManaged: true,
      );

      await service.enableAutomaticChecks();
      expect(storage.updateCalls, 1);
      expect(plugins.updateCalls, 1);

      final gate = Completer<void>();
      storage.gates.add(gate);
      await tester.pump(const Duration(hours: 13));
      await tester.pump();
      expect(storage.updateCalls, 2);

      service.dispose();
      gate.complete();
      await tester.pump();

      expect(storage.updateCalls, 2);
      expect(plugins.updateCalls, 1);
    });

    testWidgets('disposed services cannot start checks or timers again', (
      tester,
    ) async {
      final updater = _RecordingUpdater();
      final storage = _ScriptedSkinsStorage();
      final service = _sharedUpdateService(updater: updater, storage: storage);

      service.dispose();
      service.scheduleInitialize(delay: Duration.zero);
      await service.enableAutomaticChecks();
      await service.checkForUpdate();
      await tester.pump(const Duration(hours: 13));
      await tester.pump();

      expect(updater.checks, 0);
      expect(storage.updateCalls, 0);
    });
  });

  testWidgets('resume refreshes the extension management policy', (
    tester,
  ) async {
    final service = MockSettingsService();
    final controller = SettingsController(service);
    await controller.loadSettings();
    expect(controller.requireExtensionManagementAuthorization, isFalse);
    final observer = app.AppLifecycleObserver(settingsController: controller);

    await service.setRequireExtensionManagementAuthorization(true);
    expect(controller.requireExtensionManagementAuthorization, isFalse);

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(controller.requireExtensionManagementAuthorization, isTrue);
    observer.dispose();
  });

  testWidgets('requests after resume use the current persisted policy', (
    tester,
  ) async {
    final service = MockSettingsService();
    final controller = SettingsController(service);
    await controller.loadSettings();
    final observer = app.AppLifecycleObserver(settingsController: controller);
    final handler = const Pipeline()
        .addMiddleware(
          extensionManagementAuthMiddleware(
            null,
            requireExtensionManagementAuthorization: () =>
                controller.currentRequireExtensionManagementAuthorization(),
          ),
        )
        .addHandler((request) => Response.ok('inner'));

    Request install() =>
        Request('POST', Uri.parse('http://localhost/api/v1/plugins/install'));

    expect((await handler(install())).statusCode, 200);

    await service.setRequireExtensionManagementAuthorization(true);
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(controller.requireExtensionManagementAuthorization, isTrue);
    expect((await handler(install())).statusCode, 401);
    observer.dispose();
  });

  group('startup settings order', () {
    testWidgets('the API starts only after the settings load completes', (
      tester,
    ) async {
      final loadGate = Completer<void>();
      final service = _GatedSettingsService(loadGate: loadGate);
      final controller = SettingsController(service);
      final devices = SimulatedDeviceService();
      final started = <String>[];

      final boot = app.loadSettingsBeforeWebServer(
        settingsController: controller,
        simulatedDevicesService: devices,
        startWebServer: () async {
          started.add('api');
        },
      );
      await tester.pump();

      expect(started, isEmpty, reason: 'the API must wait for the settings');
      expect(controller.requireExtensionManagementAuthorization, isFalse);

      loadGate.complete();
      await boot;

      expect(started, ['api']);
    });

    testWidgets('a failed settings load never starts the API', (tester) async {
      final service = _GatedSettingsService(failLoad: true);
      final controller = SettingsController(service);
      final started = <String>[];

      final boot = app.loadSettingsBeforeWebServer(
        settingsController: controller,
        simulatedDevicesService: SimulatedDeviceService(),
        startWebServer: () async {
          started.add('api');
        },
      );

      await expectLater(boot, throwsA(isA<StateError>()));
      await tester.pump();

      expect(started, isEmpty);
    });

    testWidgets('startup keeps the simulate preference listener live', (
      tester,
    ) async {
      final service = MockSettingsService();
      await service.setSimulatedDevices({SimulatedDevicesTypes.scale});
      final controller = SettingsController(service);
      final devices = SimulatedDeviceService();

      await app.loadSettingsBeforeWebServer(
        settingsController: controller,
        simulatedDevicesService: devices,
        startWebServer: () async {},
      );

      expect(devices.enabledDevices, {SimulatedDevicesTypes.scale});

      await controller.setSimulatedDevices({SimulatedDevicesTypes.machine});

      expect(devices.enabledDevices, {SimulatedDevicesTypes.machine});
    });
  });
}
