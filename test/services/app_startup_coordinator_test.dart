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

  for (final failsWithThrow in [false, true]) {
    test(
      'foreground start failure (throw=$failsWithThrow) is nonblocking and one retry registers the watcher',
      () async {
        var starts = 0;
        var watches = 0;
        var devices = 0;
        var webUI = 0;
        final tokens = <Object>[];
        final coordinator = AppStartupCoordinator(
          initializeDevices: () async => devices++,
          initializeWebUI: () async => webUI++,
          startForeground: () async {
            starts++;
            if (starts == 1) {
              if (failsWithThrow) throw StateError('foreground unavailable');
              return false;
            }
            return true;
          },
          watchForeground: () {
            watches++;
            final token = Object();
            tokens.add(token);
            return token;
          },
          unwatchForeground: (_) {},
          isAndroid: true,
        );
        addTearDown(coordinator.dispose);

        await coordinator.ensureInitialized();

        expect(coordinator.status, AppStartupStatus.degraded);
        expect(coordinator.state.foregroundRecoveryRequired, isTrue);
        expect(
          coordinator.state.foregroundRecovery,
          contains('Foreground service'),
        );
        expect(coordinator.state.discoveryRecoveryRequired, isFalse);
        expect(starts, 1);
        expect(watches, 0);
        expect(devices, 1);
        expect(webUI, 1);

        await coordinator.retryForeground();

        expect(starts, 2);
        expect(watches, 1);
        expect(tokens, hasLength(1));
        expect(coordinator.status, AppStartupStatus.ready);
        expect(coordinator.state.foregroundRecoveryRequired, isFalse);
        expect(coordinator.reasons, isEmpty);
        expect(devices, 1);
        expect(webUI, 1);

        await coordinator.retryForeground();

        expect(starts, 2);
        expect(watches, 1);
        expect(devices, 1);
        expect(webUI, 1);
        expect(coordinator.status, AppStartupStatus.ready);
      },
    );
  }

  test('concurrent foreground and core retries share one pending foreground attempt', () async {
    var starts = 0;
    var watches = 0;
    var devices = 0;
    var webUI = 0;
    final retryStart = Completer<bool>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async => devices++,
      initializeWebUI: () async => webUI++,
      startForeground: () {
        starts++;
        return starts == 1 ? Future<bool>.value(false) : retryStart.future;
      },
      watchForeground: () => ++watches,
      unwatchForeground: (_) {},
      isAndroid: true,
    );
    addTearDown(coordinator.dispose);
    await coordinator.ensureInitialized();
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);

    final first = coordinator.retryForeground();
    final second = coordinator.retryForeground();

    expect(identical(first, second), isTrue);
    expect(starts, 2);
    expect(coordinator.state.foregroundRetryPending, isTrue);
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);

    final core = coordinator.retry();
    await Future<void>.value();
    expect(starts, 2);
    expect(watches, 0);

    retryStart.complete(true);
    await first;
    await core;

    expect(starts, 2);
    expect(watches, 1);
    expect(coordinator.state.foregroundRetryPending, isFalse);
    expect(coordinator.state.foregroundRecoveryRequired, isFalse);
    expect(coordinator.status, AppStartupStatus.ready);
    expect(devices, 1);
    expect(webUI, 1);
  });

  test('foreground-only retry leaves coexisting failures and diagnostics untouched', () async {
    var deviceCalls = 0;
    var webUICalls = 0;
    var pluginCalls = 0;
    var starts = 0;
    var watches = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async => deviceCalls++,
      deviceStartupOutcome: () =>
          DeviceStartupOutcome(failures: [StateError('serial unavailable')]),
      initializeWebUI: () async {
        webUICalls++;
        throw StateError('local skin offline');
      },
      initializePlugins: () async {
        pluginCalls++;
        throw StateError('plugin registry offline');
      },
      refreshRemoteSkins: () async =>
          throw StateError('remote skins unreachable'),
      startForeground: () async => ++starts > 1,
      watchForeground: () => ++watches,
      unwatchForeground: (_) {},
      isAndroid: true,
    );
    addTearDown(coordinator.dispose);

    await coordinator.ensureInitialized();
    await coordinator.stateStream.firstWhere(
      (state) => state.optionalTasks['plugins'] == AppStartupTaskStatus.failed,
    );

    expect(coordinator.state.discoveryRecoveryRequired, isTrue);
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);

    await coordinator.retryForeground();

    expect(deviceCalls, 1);
    expect(webUICalls, 1);
    expect(pluginCalls, 1);
    expect(starts, 2);
    expect(watches, 1);
    expect(coordinator.state.foregroundRecoveryRequired, isFalse);
    expect(coordinator.state.discoveryRecoveryRequired, isTrue);
    expect(coordinator.status, AppStartupStatus.degraded);
    expect(
      coordinator.state.optionalTasks['plugins'],
      AppStartupTaskStatus.failed,
    );
    for (final retained in [
      'serial unavailable',
      'local skin offline',
      'plugin registry offline',
      'remote skins unreachable',
    ]) {
      expect(
        coordinator.reasons,
        contains(contains(retained)),
        reason: '$retained should stay as an unrelated diagnostic',
      );
    }
  });

  test(
    'disposal during a pending foreground retry releases a late watcher token',
    () async {
      var starts = 0;
      final acquired = Completer<Object>();
      final watching = Completer<void>();
      final released = <Object>[];
      final token = Object();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {},
        startForeground: () async => ++starts > 1,
        watchForeground: () {
          watching.complete();
          return acquired.future;
        },
        unwatchForeground: released.add,
        isAndroid: true,
      );

      await coordinator.ensureInitialized();
      final retried = coordinator.retryForeground();
      await watching.future;
      coordinator.dispose();
      acquired.complete(token);
      await retried;

      expect(starts, 2);
      expect(released, [token]);
    },
  );

  test(
    'a foreground retry that fails again stays explicitly recoverable',
    () async {
      var starts = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {},
        startForeground: () async => ++starts > 3,
        watchForeground: () => Object(),
        unwatchForeground: (_) {},
        isAndroid: true,
      );
      addTearDown(coordinator.dispose);

      await coordinator.ensureInitialized();
      expect(coordinator.state.foregroundRecoveryRequired, isTrue);
      expect(coordinator.state.foregroundRetryPending, isFalse);

      await coordinator.retryForeground();

      expect(starts, 2);
      expect(coordinator.state.foregroundRetryPending, isFalse);
      expect(coordinator.state.foregroundRecoveryRequired, isTrue);
      expect(coordinator.status, AppStartupStatus.degraded);

      await coordinator.retryForeground();
      await coordinator.retryForeground();

      expect(starts, 4);
      expect(coordinator.state.foregroundRecoveryRequired, isFalse);
      expect(coordinator.status, AppStartupStatus.ready);
    },
  );

  test('foreground retry never starts before the startup boundary or after a failed core', () async {
    var starts = 0;
    var devices = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {
        devices++;
        throw StateError('adapter');
      },
      initializeWebUI: () async {},
      startForeground: () async => ++starts > 0,
      watchForeground: () => Object(),
      unwatchForeground: (_) {},
      isAndroid: true,
    );
    addTearDown(coordinator.dispose);

    await coordinator.retryForeground();
    expect(starts, 0);

    await expectLater(coordinator.ensureInitialized(), throwsStateError);
    expect(coordinator.status, AppStartupStatus.failed);

    await coordinator.retryForeground();

    expect(starts, 0);
    expect(coordinator.status, AppStartupStatus.failed);
    expect(coordinator.reasons, contains(contains('adapter')));
    expect(devices, 1);
  });

  test('foreground-only recovery clears retry eligibility and keeps the initialization future stable', () async {
    var starts = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () async {},
      startForeground: () async => ++starts > 1,
      watchForeground: () => Object(),
      unwatchForeground: (_) {},
      isAndroid: true,
    );
    addTearDown(coordinator.dispose);

    final initial = coordinator.ensureInitialized();
    await initial;
    expect(coordinator.status, AppStartupStatus.degraded);
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);

    await coordinator.retryForeground();

    expect(coordinator.status, AppStartupStatus.ready);
    expect(coordinator.state.foregroundRecoveryRequired, isFalse);

    final emissions = <AppStartupStatus>[];
    final subscription = coordinator.stateStream.listen(
      (state) => emissions.add(state.status),
    );
    addTearDown(subscription.cancel);

    final repeated = coordinator.retry();

    expect(identical(initial, repeated), isTrue);
    await repeated;
    await Future<void>.value();
    expect(emissions, isNot(contains(AppStartupStatus.initializing)));
    expect(starts, 2);
  });

  for (final recovers in [true, false]) {
    test(
      'foreground retry finishing while a core retry is pending preserves the core status (recovers=$recovers)',
      () async {
        var deviceCalls = 0;
        var starts = 0;
        final devices = Completer<void>();
        final retryStart = Completer<bool>();
        final coordinator = AppStartupCoordinator(
          initializeDevices: () {
            deviceCalls++;
            return deviceCalls == 1 ? Future<void>.value() : devices.future;
          },
          deviceStartupOutcome: () => deviceCalls == 1
              ? DeviceStartupOutcome(
                  failures: [StateError('serial unavailable')],
                )
              : const DeviceStartupOutcome(),
          initializeWebUI: () async {},
          startForeground: () {
            starts++;
            return starts == 1 ? Future<bool>.value(false) : retryStart.future;
          },
          watchForeground: () => Object(),
          unwatchForeground: (_) {},
          isAndroid: true,
        );
        addTearDown(coordinator.dispose);

        await coordinator.ensureInitialized();
        expect(coordinator.status, AppStartupStatus.degraded);
        expect(coordinator.state.discoveryRecoveryRequired, isTrue);
        expect(coordinator.state.foregroundRecoveryRequired, isTrue);

        final foreground = coordinator.retryForeground();
        final core = coordinator.retry();

        expect(coordinator.status, AppStartupStatus.initializing);
        expect(starts, 2);

        retryStart.complete(recovers);
        await foreground;

        expect(coordinator.status, AppStartupStatus.initializing);
        expect(coordinator.state.foregroundRetryPending, isFalse);
        expect(coordinator.state.foregroundRecoveryRequired, !recovers);

        devices.complete();
        await core;

        expect(coordinator.state.foregroundRetryPending, isFalse);
        expect(coordinator.state.foregroundRecoveryRequired, !recovers);
        expect(
          coordinator.status,
          recovers ? AppStartupStatus.ready : AppStartupStatus.degraded,
        );
      },
    );

    test(
      'foreground retry finishing while core recovery waits on WebUI keeps the core attempt pending (recovers=$recovers)',
      () async {
        var deviceCalls = 0;
        var webUICalls = 0;
        var starts = 0;
        var watches = 0;
        final webUIHeld = Completer<void>();
        final webUIEntered = Completer<void>();
        final retryStart = Completer<bool>();
        final coordinator = AppStartupCoordinator(
          initializeDevices: () async {
            deviceCalls++;
          },
          deviceStartupOutcome: () => deviceCalls == 1
              ? DeviceStartupOutcome(
                  failures: [StateError('serial unavailable')],
                )
              : const DeviceStartupOutcome(),
          initializeWebUI: () {
            webUICalls++;
            if (webUICalls == 1) throw StateError('webUI unavailable');
            webUIEntered.complete();
            return webUIHeld.future;
          },
          startForeground: () {
            starts++;
            return starts == 1 ? Future<bool>.value(false) : retryStart.future;
          },
          watchForeground: () => ++watches,
          unwatchForeground: (_) {},
          isAndroid: true,
        );
        addTearDown(coordinator.dispose);

        await coordinator.ensureInitialized();
        expect(deviceCalls, 1);
        expect(webUICalls, 1);
        expect(starts, 1);
        expect(watches, 0);
        expect(coordinator.status, AppStartupStatus.degraded);
        expect(coordinator.state.discoveryRecoveryRequired, isTrue);
        expect(coordinator.state.foregroundRecoveryRequired, isTrue);

        final core = coordinator.retry();
        await webUIEntered.future;

        expect(deviceCalls, 2);
        expect(webUICalls, 2);
        expect(starts, 1);
        expect(coordinator.status, AppStartupStatus.initializing);

        final foreground = coordinator.retryForeground();

        expect(starts, 2);
        retryStart.complete(recovers);
        await foreground;

        final pendingStatus = coordinator.status;
        final pendingRetry = coordinator.state.foregroundRetryPending;
        final pendingRecovery = coordinator.state.foregroundRecoveryRequired;

        webUIHeld.complete();
        await core;

        expect(pendingStatus, AppStartupStatus.initializing);
        expect(pendingRetry, isFalse);
        expect(pendingRecovery, !recovers);
        expect(starts, 2);
        expect(watches, recovers ? 1 : 0);
        expect(deviceCalls, 2);
        expect(webUICalls, 2);
        expect(coordinator.state.foregroundRetryPending, isFalse);
        expect(coordinator.state.foregroundRecoveryRequired, !recovers);
        expect(coordinator.state.discoveryRecoveryRequired, isFalse);
        expect(
          coordinator.status,
          recovers ? AppStartupStatus.ready : AppStartupStatus.degraded,
        );
        expect(
          coordinator.reasons,
          recovers ? isEmpty : ['Foreground service failed to start'],
        );
        expect(
          coordinator.state.optionalTasks.values,
          isNot(contains(AppStartupTaskStatus.failed)),
        );
      },
    );

    test(
      'foreground retry finishing before a core retry is rejoined rather than replayed (recovers=$recovers)',
      () async {
        var deviceCalls = 0;
        var starts = 0;
        final devices = Completer<void>();
        final coordinator = AppStartupCoordinator(
          initializeDevices: () {
            deviceCalls++;
            return deviceCalls == 1 ? Future<void>.value() : devices.future;
          },
          deviceStartupOutcome: () => deviceCalls == 1
              ? DeviceStartupOutcome(
                  failures: [StateError('serial unavailable')],
                )
              : const DeviceStartupOutcome(),
          initializeWebUI: () async {},
          startForeground: () async {
            starts++;
            return recovers && starts > 1;
          },
          watchForeground: () => Object(),
          unwatchForeground: (_) {},
          isAndroid: true,
        );
        addTearDown(coordinator.dispose);

        await coordinator.ensureInitialized();
        expect(starts, 1);

        await coordinator.retryForeground();
        expect(starts, 2);
        expect(coordinator.state.foregroundRecoveryRequired, !recovers);

        final core = coordinator.retry();
        expect(coordinator.status, AppStartupStatus.initializing);

        devices.complete();
        await core;

        expect(starts, 2);
        expect(deviceCalls, 2);
        expect(coordinator.state.foregroundRecoveryRequired, !recovers);
        expect(
          coordinator.status,
          recovers ? AppStartupStatus.ready : AppStartupStatus.degraded,
        );
      },
    );
  }

  test(
    'disposal during a pending foreground retry start fences the late work',
    () async {
      var starts = 0;
      var watches = 0;
      final pendingStart = Completer<bool>();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {},
        startForeground: () {
          starts++;
          return starts == 1 ? Future<bool>.value(false) : pendingStart.future;
        },
        watchForeground: () => ++watches,
        unwatchForeground: (_) {},
        isAndroid: true,
      );

      await coordinator.ensureInitialized();
      final retried = coordinator.retryForeground();
      expect(coordinator.state.foregroundRetryPending, isTrue);
      expect(starts, 2);

      coordinator.dispose();
      pendingStart.complete(true);
      await retried;

      expect(starts, 2);
      expect(watches, 0);
    },
  );

  test(
    'watcher failure retries only the watcher and never the started service',
    () async {
      var starts = 0;
      var watches = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {},
        initializeWebUI: () async {},
        startForeground: () async {
          starts++;
          return true;
        },
        watchForeground: () {
          watches++;
          if (watches == 1) throw StateError('watcher unavailable');
          return Object();
        },
        unwatchForeground: (_) {},
        isAndroid: true,
      );
      addTearDown(coordinator.dispose);

      await coordinator.ensureInitialized();

      expect(starts, 1);
      expect(watches, 1);
      expect(coordinator.status, AppStartupStatus.degraded);
      expect(coordinator.state.foregroundRecoveryRequired, isTrue);

      await coordinator.retryForeground();

      expect(starts, 1);
      expect(watches, 2);
      expect(coordinator.state.foregroundRecoveryRequired, isFalse);
      expect(coordinator.status, AppStartupStatus.ready);
    },
  );

  test('a core failure during a foreground retry keeps explicit foreground recovery available', () async {
    var deviceCalls = 0;
    var starts = 0;
    var watches = 0;
    final foregroundStart = Completer<bool>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {
        deviceCalls++;
        if (deviceCalls == 2) throw StateError('adapter');
      },
      deviceStartupOutcome: () => deviceCalls == 1
          ? DeviceStartupOutcome(failures: [StateError('serial unavailable')])
          : const DeviceStartupOutcome(),
      initializeWebUI: () async {},
      startForeground: () {
        starts++;
        if (starts == 1) return Future<bool>.value(false);
        if (starts == 2) return foregroundStart.future;
        return Future<bool>.value(true);
      },
      watchForeground: () => ++watches,
      unwatchForeground: (_) {},
      isAndroid: true,
    );
    addTearDown(coordinator.dispose);

    await coordinator.ensureInitialized();
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);
    expect(coordinator.state.discoveryRecoveryRequired, isTrue);

    final foreground = coordinator.retryForeground();
    final core = coordinator.retry();
    await expectLater(core, throwsStateError);
    expect(coordinator.status, AppStartupStatus.failed);

    foregroundStart.complete(false);
    await foreground;

    expect(starts, 2);
    expect(coordinator.status, AppStartupStatus.failed);
    expect(coordinator.state.foregroundRecoveryRequired, isTrue);

    await coordinator.retryForeground();

    expect(starts, 3);
    expect(watches, 1);
    expect(deviceCalls, 2);
    expect(coordinator.state.foregroundRecoveryRequired, isFalse);
    expect(coordinator.status, AppStartupStatus.failed);
  });
}
