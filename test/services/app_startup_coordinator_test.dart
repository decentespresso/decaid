import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';

void main() {
  test(
    'constructor is inert and concurrent initialization is coalesced',
    () async {
      var deviceCalls = 0;
      final deviceReady = Completer<void>();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () {
          deviceCalls++;
          return deviceReady.future;
        },
        initializeWebUI: () async {},
        isAndroid: false,
      );

      expect(coordinator.state.status, AppStartupStatus.idle);
      final first = coordinator.ensureInitialized();
      final second = coordinator.ensureInitialized();
      expect(identical(first, second), isTrue);
      expect(deviceCalls, 1);

      deviceReady.complete();
      await first;
      expect(coordinator.state.status, AppStartupStatus.ready);
      coordinator.dispose();
    },
  );

  test('disposal fences foreground side effects after core awaits', () async {
    final devicesReady = Completer<void>();
    var foregroundStarts = 0;
    var watches = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () => devicesReady.future,
      initializeWebUI: () async {},
      startForeground: () async {
        foregroundStarts++;
        return true;
      },
      watchForeground: () {
        watches++;
        return null;
      },
      isAndroid: true,
    );

    final initialization = coordinator.ensureInitialized();
    coordinator.dispose();
    devicesReady.complete();
    await initialization;

    expect(foregroundStarts, 0);
    expect(watches, 0);
  });

  test('retry repeats only failed core work', () async {
    var deviceCalls = 0;
    var webUICalls = 0;
    var failWebUI = true;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async => deviceCalls++,
      initializeWebUI: () async {
        webUICalls++;
        if (failWebUI) throw StateError('web unavailable');
      },
      isAndroid: false,
    );

    await coordinator.ensureInitialized();
    expect(coordinator.status, AppStartupStatus.degraded);
    failWebUI = false;
    await coordinator.retry();

    expect(deviceCalls, 1);
    expect(webUICalls, 2);
    expect(coordinator.status, AppStartupStatus.ready);
    coordinator.dispose();
  });

  test('desktop startup never starts foreground service', () async {
    var starts = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      startForeground: () async {
        starts++;
        return true;
      },
      isAndroid: false,
    );

    await coordinator.ensureInitialized();
    expect(starts, 0);
    coordinator.dispose();
  });

  test(
    'coordinator releases its foreground watcher token on disposal',
    () async {
      var token = 0;
      var unwatchCalls = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {},
        startForeground: () async => true,
        watchForeground: () => ++token,
        unwatchForeground: (_) => unwatchCalls++,
        isAndroid: true,
      );

      await coordinator.ensureInitialized();
      final replacement = token;
      coordinator.dispose();

      expect(replacement, 1);
      expect(unwatchCalls, 1);
    },
  );

  test('optional startup work does not gate core readiness and failures are observable', () async {
    final pluginReady = Completer<void>();
    final remoteReady = Completer<void>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      initializePlugins: () => pluginReady.future,
      refreshRemoteSkins: () => remoteReady.future,
      isAndroid: false,
    );

    await coordinator.ensureInitialized();
    expect(coordinator.state.status, AppStartupStatus.ready);
    expect(
      coordinator.state.optionalTasks['plugins'],
      AppStartupTaskStatus.pending,
    );

    pluginReady.completeError(StateError('plugin offline'));
    remoteReady.completeError(StateError('skin feed offline'));
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.state.status, AppStartupStatus.degraded);
    expect(coordinator.state.reasons, contains(contains('plugin')));
    expect(coordinator.state.reasons, contains(contains('remote')));
    expect(coordinator.state.discoveryRecoveryRequired, isFalse);
    coordinator.dispose();
  });

  test('blocking discovery failure keeps explicit recovery', () async {
    var blocked = true;
    var deviceCalls = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async => deviceCalls++,
      deviceStartupOutcome: () => blocked
          ? DeviceStartupOutcome(
              failures: [StateError('serial unavailable')],
              blocking: true,
            )
          : const DeviceStartupOutcome(),
      initializeWebUI: () async {},
      isAndroid: false,
    );

    await expectLater(
      coordinator.ensureInitialized(),
      throwsA(isA<DeviceDiscoveryStartupFailed>()),
    );
    expect(coordinator.status, AppStartupStatus.failed);
    expect(coordinator.reasons, contains(contains('serial unavailable')));

    blocked = false;
    await coordinator.retry();

    expect(deviceCalls, 2);
    expect(coordinator.status, AppStartupStatus.ready);
    expect(coordinator.state.discoveryRecoveryRequired, isFalse);
    coordinator.dispose();
  });

  test('partial discovery failure stays recoverable and keeps optional diagnostics', () async {
    var failDiscovery = true;
    var deviceCalls = 0;
    final plugin = Completer<void>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async => deviceCalls++,
      deviceStartupOutcome: () => failDiscovery
          ? DeviceStartupOutcome(failures: [StateError('serial unavailable')])
          : const DeviceStartupOutcome(),
      initializeWebUI: () async {},
      initializePlugins: () => plugin.future,
      isAndroid: false,
    );
    addTearDown(coordinator.dispose);

    await coordinator.ensureInitialized();
    expect(coordinator.status, AppStartupStatus.degraded);
    expect(coordinator.state.discoveryRecoveryRequired, isTrue);
    expect(coordinator.state.discoveryRecovery, contains('serial unavailable'));

    plugin.completeError(StateError('plugin offline'));
    await coordinator.stateStream.firstWhere(
      (state) => state.optionalTasks['plugins'] == AppStartupTaskStatus.failed,
    );

    failDiscovery = false;
    await coordinator.retry();

    expect(deviceCalls, 2);
    expect(coordinator.status, AppStartupStatus.degraded);
    expect(coordinator.state.discoveryRecoveryRequired, isFalse);
    expect(coordinator.reasons, contains(contains('plugin offline')));
  });

  test('retry while initialization is pending shares the attempt', () async {
    final devices = Completer<void>();
    var deviceCalls = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () {
        deviceCalls++;
        return devices.future;
      },
      initializeWebUI: () async {},
      isAndroid: false,
    );

    final first = coordinator.ensureInitialized();
    final retried = coordinator.retry();

    expect(identical(first, retried), isTrue);
    expect(deviceCalls, 1);
    devices.complete();
    await first;
    expect(coordinator.status, AppStartupStatus.ready);
    coordinator.dispose();
  });
}
