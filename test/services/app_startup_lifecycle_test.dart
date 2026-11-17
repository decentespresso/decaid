import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
import 'package:reaprime/src/services/foreground_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

class _Storage extends WebUIStorage {
  _Storage() : super(SettingsController(MockSettingsService()));

  final ready = Completer<void>();
  WebUISkin? skin;
  bool? downloadRemote;

  @override
  Future<void> initialize({bool downloadRemote = true}) {
    this.downloadRemote = downloadRemote;
    return ready.future;
  }

  @override
  WebUISkin? get defaultSkin => skin;

  @override
  Future<void> downloadRemoteSkinsAndRescan() async {}
}

class _Server extends WebUIService {
  final paths = <String>[];
  Object? failure;

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    paths.add(path);
    if (failure case final error?) throw error;
  }
}

class _Discovery extends DeviceDiscoveryService {
  _Discovery(this.name, {this.failuresBeforeSuccess = 0});

  final String name;
  int failuresBeforeSuccess;
  int initializeCalls = 0;

  @override
  Stream<List<Device>> get devices => const Stream.empty();

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('$name unavailable');
    }
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;
}

void main() {
  test(
    'real controller recovery reinitializes only the failed discovery service',
    () async {
      final flaky = _Discovery('serial', failuresBeforeSuccess: 1);
      final healthy = _Discovery('ble');
      final controller = DeviceController([
        flaky,
        healthy,
      ], startupRelevance: app.isStartupRelevantDiscoveryService);
      final coordinator = AppStartupCoordinator(
        deviceController: controller,
        initializeWebUI: () async {},
        isAndroid: false,
      );
      addTearDown(() {
        coordinator.dispose();
        controller.dispose();
      });

      await coordinator.ensureInitialized();
      expect(coordinator.status, AppStartupStatus.degraded);
      expect(coordinator.state.discoveryRecoveryRequired, isTrue);
      expect(
        coordinator.state.discoveryRecovery,
        contains('serial unavailable'),
      );

      await coordinator.retry();

      expect(flaky.initializeCalls, 2);
      expect(healthy.initializeCalls, 1);
      expect(coordinator.status, AppStartupStatus.ready);
      expect(coordinator.state.discoveryRecoveryRequired, isFalse);
    },
  );

  test(
    'late optional failure cannot mask failed core or disable retry',
    () async {
      var mode = 0;
      final plugin = Completer<void>();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {
          if (mode == 1) throw StateError('adapter');
        },
        deviceStartupOutcome: () => mode == 0
            ? DeviceStartupOutcome(failures: [StateError('scanner')])
            : const DeviceStartupOutcome(),
        initializeWebUI: () async {},
        initializePlugins: () => plugin.future,
        isAndroid: false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.ensureInitialized();
      mode = 1;
      await expectLater(coordinator.retry(), throwsStateError);
      expect(coordinator.status, AppStartupStatus.failed);
      plugin.completeError(StateError('plugin late'));
      await coordinator.stateStream.firstWhere(
        (state) =>
            state.reasons.any((reason) => reason.contains('plugin late')),
      );
      expect(coordinator.status, AppStartupStatus.failed);
      mode = 2;
      await coordinator.retry();
      expect(coordinator.status, AppStartupStatus.degraded);
      expect(coordinator.reasons, isNot(contains(contains('adapter'))));
    },
  );

  test('published collections cannot be mutated outside coordinator', () async {
    final plugin = Completer<void>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      initializePlugins: () => plugin.future,
      isAndroid: false,
    );
    addTearDown(coordinator.dispose);
    await coordinator.ensureInitialized();
    plugin.completeError(StateError('offline'));
    await coordinator.stateStream.firstWhere(
      (state) => state.status == AppStartupStatus.degraded,
    );
    expect(() => coordinator.state.reasons.clear(), throwsUnsupportedError);
    expect(
      () => coordinator.state.optionalTasks.clear(),
      throwsUnsupportedError,
    );
  });
  test('device and local WebUI initialization overlap', () async {
    final devices = Completer<void>();
    var webUICalls = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () => devices.future,
      initializeWebUI: () async {
        webUICalls++;
      },
      isAndroid: false,
    );
    addTearDown(coordinator.dispose);
    final initialization = coordinator.ensureInitialized();
    expect(webUICalls, 1);
    devices.complete();
    await initialization;
  });

  test(
    'core retry preserves optional failure and pending observations',
    () async {
      var failWebUI = true;
      final plugin = Completer<void>();
      final remote = Completer<void>();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {
          if (failWebUI) throw StateError('local skin');
        },
        initializePlugins: () => plugin.future,
        refreshRemoteSkins: () => remote.future,
        isAndroid: false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.ensureInitialized();
      plugin.completeError(StateError('plugin unavailable'));
      await coordinator.stateStream.firstWhere(
        (state) =>
            state.optionalTasks['plugins'] == AppStartupTaskStatus.failed &&
            state.reasons.any(
              (reason) => reason.contains('plugin unavailable'),
            ),
      );
      failWebUI = false;
      await coordinator.retry();
      expect(coordinator.status, AppStartupStatus.degraded);
      expect(
        coordinator.state.optionalTasks['plugins'],
        AppStartupTaskStatus.failed,
      );
      expect(
        coordinator.state.optionalTasks['remote skins'],
        AppStartupTaskStatus.pending,
      );
      expect(coordinator.reasons, contains(contains('plugin unavailable')));
      remote.complete();
    },
  );

  test('a watcher acquired after disposal is released', () async {
    final acquired = Completer<Object>();
    final watching = Completer<void>();
    final released = <Object>[];
    final token = Object();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      startForeground: () async => true,
      watchForeground: () {
        watching.complete();
        return acquired.future;
      },
      unwatchForeground: released.add,
      isAndroid: true,
    );
    final initialization = coordinator.ensureInitialized();
    await watching.future;
    coordinator.dispose();
    acquired.complete(token);
    await initialization;
    expect(released, [token]);
  });

  test(
    'production WebUI serving is fenced after disposed storage completion',
    () async {
      final storage = _Storage()
        ..skin = WebUISkin(id: 'skin', name: 'Skin', path: '/local');
      final server = _Server();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        webUIStorage: storage,
        webUIService: server,
        isAndroid: false,
      );
      final initialization = coordinator.ensureInitialized();
      await Future<void>.value();
      coordinator.dispose();
      storage.ready.complete();
      await initialization;
      expect(server.paths, isEmpty);
    },
  );

  test(
    'invalid configured path serves local default and records degradation',
    () async {
      final storage = _Storage()
        ..skin = WebUISkin(id: 'skin', name: 'Skin', path: '/local');
      storage.ready.complete();
      final server = _Server()
        ..skinOverride = const SkinOverride.path(
          '/nonexistent-decaid-test-path',
        );
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        webUIStorage: storage,
        webUIService: server,
        isAndroid: false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.ensureInitialized();
      expect(storage.downloadRemote, isFalse);
      expect(server.paths, ['/local']);
      expect(coordinator.status, AppStartupStatus.degraded);
      expect(coordinator.reasons, contains(contains('not readable')));
      await coordinator.retry();
      expect(server.paths, ['/local']);
    },
  );

  test('missing bundled skin does not prevent core completion', () async {
    final storage = _Storage()..ready.complete();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      webUIStorage: storage,
      webUIService: _Server(),
      isAndroid: false,
    );
    addTearDown(coordinator.dispose);
    await coordinator.ensureInitialized();
    expect(coordinator.status, AppStartupStatus.degraded);
    expect(coordinator.reasons, contains(contains('No default skin')));
  });

  test(
    'device failure is recoverable without repeating successful WebUI',
    () async {
      var fail = true;
      var webUICalls = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {
          if (fail) throw StateError('adapter');
        },
        initializeWebUI: () async {
          webUICalls++;
        },
        isAndroid: false,
      );
      addTearDown(coordinator.dispose);
      await expectLater(coordinator.ensureInitialized(), throwsStateError);
      expect(coordinator.status, AppStartupStatus.failed);
      expect(coordinator.reasons, contains(contains('adapter')));
      fail = false;
      await coordinator.retry();
      expect(webUICalls, 1);
      expect(coordinator.status, AppStartupStatus.ready);
    },
  );

  test('foreground start is once and a pending start cannot acquire watch after disposal', () async {
    final started = Completer<bool>();
    final starting = Completer<void>();
    var watches = 0;
    var plugins = 0;
    var starts = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      startForeground: () {
        starts++;
        starting.complete();
        return started.future;
      },
      watchForeground: () {
        watches++;
        return Object();
      },
      initializePlugins: () async {
        plugins++;
      },
      isAndroid: true,
    );
    final initialization = coordinator.ensureInitialized();
    expect(identical(initialization, coordinator.ensureInitialized()), isTrue);
    await starting.future;
    coordinator.dispose();
    started.complete(true);
    await initialization;
    expect(starts, 1);
    expect(watches, 0);
    expect(plugins, 0);
  });

  test(
    'real foreground ownership token preserves replacement subscription',
    () async {
      var firstCancelled = 0;
      var secondCancelled = 0;
      final first = StreamController<dynamic>(
        onCancel: () {
          firstCancelled++;
        },
      );
      final second = StreamController<dynamic>(
        onCancel: () {
          secondCancelled++;
        },
      );
      final oldToken = ForegroundTaskService.watchMachineConnection(
        first.stream,
      );
      final newToken = ForegroundTaskService.watchMachineConnection(
        second.stream,
      );
      ForegroundTaskService.unwatchMachineConnection(oldToken);
      expect(firstCancelled, 1);
      expect(secondCancelled, 0);
      ForegroundTaskService.unwatchMachineConnection(newToken);
      expect(secondCancelled, 1);
      await first.close();
      await second.close();
    },
  );
}
