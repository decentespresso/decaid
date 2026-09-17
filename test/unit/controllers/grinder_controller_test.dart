import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_grinder.dart';

void main() {
  test('connects one grinder and proxies operations', () async {
    final controller = GrinderController();
    final grinder = TestGrinder(deviceId: 'one');
    addTearDown(controller.dispose);

    await controller.connectToGrinder(grinder);
    grinder.emit(GrinderState.grinding, setting: '12.3', rpm: 1200);
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    await controller.setGrindSetting('13');
    await controller.setRpm(900);

    expect(controller.connectedGrinder(), same(grinder));
    expect(controller.currentSnapshot!.state, GrinderState.grinding);
    expect(grinder.operations, ['stop', 'setting:13', 'rpm:900']);
  });

  test(
    'replacement disconnects the old instance and ignores stale frames',
    () async {
      final controller = GrinderController();
      final old = TestGrinder(deviceId: 'stable');
      final replacement = TestGrinder(deviceId: 'stable');
      final frames = <GrinderSnapshot>[];
      final subscription = controller.snapshots.listen(frames.add);
      addTearDown(() async {
        await subscription.cancel();
        await controller.dispose();
      });

      await controller.connectToGrinder(old);
      old.emit(GrinderState.idle);
      await controller.adoptGrinder(replacement..connect());
      replacement.emit(GrinderState.grinding);
      old.emit(GrinderState.error);
      await Future<void>.delayed(Duration.zero);

      expect(old.disconnectCalls, 1);
      expect(controller.connectedGrinder(), same(replacement));
      expect(controller.currentSnapshot!.state, GrinderState.grinding);
      expect(frames.last.state, GrinderState.grinding);
    },
  );

  test('disconnect clears selection and snapshot', () async {
    final controller = GrinderController();
    final grinder = TestGrinder(deviceId: 'one');
    addTearDown(controller.dispose);
    await controller.connectToGrinder(grinder);
    grinder.emit(GrinderState.idle);
    await Future<void>.delayed(Duration.zero);

    await controller.disconnect();

    expect(controller.currentSnapshot, isNull);
    expect(controller.currentConnectionState, ConnectionState.disconnected);
    expect(
      controller.connectedGrinder,
      throwsA(
        isA<DeviceNotConnectedException>().having(
          (error) => error.kind,
          'kind',
          DeviceKind.grinder,
        ),
      ),
    );
  });

  test(
    'replacement cancels a pending grinder and does not report success',
    () async {
      final controller = GrinderController();
      final gate = Completer<void>();
      final pending = TestGrinder(deviceId: 'pending', connectGate: gate);
      final replacement = TestGrinder(deviceId: 'replacement');
      addTearDown(controller.dispose);

      final pendingConnection = controller.connectToGrinder(pending);
      final pendingFailure = expectLater(pendingConnection, throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      await controller.connectToGrinder(replacement);
      gate.complete();
      await pendingFailure;

      expect(pending.disconnectCalls, greaterThanOrEqualTo(1));
      expect(controller.connectedGrinder(), same(replacement));
    },
  );

  test('disconnect cancels a grinder waiting for readiness', () async {
    final controller = GrinderController();
    final gate = Completer<void>();
    final grinder = TestGrinder(deviceId: 'pending', connectGate: gate);
    addTearDown(controller.dispose);

    final connection = controller.connectToGrinder(grinder);
    final failure = expectLater(connection, throwsA(anything));
    await Future<void>.delayed(Duration.zero);
    await controller.disconnect();
    gate.complete();
    await failure;

    expect(grinder.disconnectCalls, greaterThanOrEqualTo(1));
    expect(
      controller.connectedGrinder,
      throwsA(isA<DeviceNotConnectedException>()),
    );
  });

  test(
    'repeated requests for the same pending grinder share one connection',
    () async {
      final controller = GrinderController();
      final gate = Completer<void>();
      final grinder = TestGrinder(deviceId: 'pending', connectGate: gate);
      addTearDown(controller.dispose);

      final first = controller.connectToGrinder(grinder);
      final second = controller.connectToGrinder(grinder);

      expect(identical(first, second), isTrue);
      gate.complete();
      await Future.wait([first, second]);
      expect(grinder.onConnectCalls, 1);
    },
  );

  test(
    'failed same-adapter reconnect does not replay an old snapshot',
    () async {
      final controller = GrinderController();
      final reconnectGate = Completer<void>();
      late PluginGrinder grinder;
      var connections = 0;
      grinder = PluginGrinder(
        deviceId: 'plugin-grinder',
        name: 'Plugin grinder',
        capabilities: const {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            connections++;
            if (connections == 1) {
              grinder.publish({
                'state': 'grinding',
              }, session: payload['session'] as String);
            } else {
              await reconnectGate.future;
              throw const PluginDeviceException('reconnect failed');
            }
          }
          return const {};
        },
      );
      final frames = <GrinderSnapshot>[];
      final subscription = controller.snapshots.listen(frames.add);
      addTearDown(() async {
        await subscription.cancel();
        await controller.dispose();
        await grinder.dispose();
      });

      await controller.connectToGrinder(grinder);
      await Future<void>.delayed(Duration.zero);
      expect(frames.map((frame) => frame.state), [GrinderState.grinding]);
      await controller.disconnect();

      final reconnect = controller.connectToGrinder(grinder);
      final failure = expectLater(
        reconnect,
        throwsA(isA<PluginDeviceException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(frames.map((frame) => frame.state), [GrinderState.grinding]);
      expect(controller.currentSnapshot, isNull);

      reconnectGate.complete();
      await failure;
      expect(controller.currentSnapshot, isNull);
      expect(
        controller.connectedGrinder,
        throwsA(isA<DeviceNotConnectedException>()),
      );
    },
  );

  test(
    'adopts the current PluginGrinder snapshot without a new frame',
    () async {
      late PluginGrinder grinder;
      grinder = PluginGrinder(
        deviceId: 'adopted',
        name: 'Adopted grinder',
        capabilities: const {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            grinder.publish({
              'state': 'idle',
            }, session: payload['session'] as String);
          }
          return const {};
        },
      );
      final controller = GrinderController();
      addTearDown(() async {
        await controller.dispose();
        await grinder.dispose();
      });

      await grinder.onConnect();
      await controller.adoptGrinder(grinder);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentSnapshot?.state, GrinderState.idle);
    },
  );

  test('old disconnect completion cannot overwrite a replacement', () async {
    final disconnectGate = Completer<void>();
    final old = TestGrinder(deviceId: 'old', disconnectGate: disconnectGate);
    final replacement = TestGrinder(deviceId: 'replacement');
    final controller = GrinderController();
    addTearDown(() async {
      await controller.dispose();
      await old.dispose();
      await replacement.dispose();
    });
    await controller.connectToGrinder(old);

    final disconnect = controller.disconnect();
    await Future<void>.delayed(Duration.zero);
    await controller.connectToGrinder(replacement);
    replacement.emit(GrinderState.grinding, rpm: 1000);
    await Future<void>.delayed(Duration.zero);
    disconnectGate.complete();
    await disconnect;
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentConnectionState, ConnectionState.connected);
    expect(controller.connectedGrinder(), same(replacement));
    expect(controller.currentSnapshot?.state, GrinderState.grinding);
    await controller.stop();
    expect(replacement.operations, ['stop']);
  });

  test('dispose rejects a new selection as soon as teardown begins', () async {
    final disconnectGate = Completer<void>();
    final selected = TestGrinder(
      deviceId: 'selected',
      disconnectGate: disconnectGate,
    );
    final replacement = TestGrinder(deviceId: 'replacement');
    final controller = GrinderController();
    addTearDown(() async {
      await selected.dispose();
      await replacement.dispose();
    });
    await controller.connectToGrinder(selected);

    final disposal = controller.dispose();
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      controller.connectToGrinder(replacement),
      throwsA(isA<StateError>()),
    );
    disconnectGate.complete();
    await disposal;
  });

  test('stale cleanup cannot disconnect a reselected instance', () async {
    final connectGate = Completer<void>();
    final disconnectGate = Completer<void>();
    final grinder = TestGrinder(
      deviceId: 'same',
      connectGate: connectGate,
      disconnectGate: disconnectGate,
    );
    final controller = GrinderController();
    addTearDown(() async {
      await controller.dispose();
      await grinder.dispose();
    });

    final firstConnection = controller.connectToGrinder(grinder);
    final firstFailure = expectLater(firstConnection, throwsA(anything));
    await Future<void>.delayed(Duration.zero);
    final disconnect = controller.disconnect();
    await Future<void>.delayed(Duration.zero);
    final reconnect = controller.connectToGrinder(grinder);

    disconnectGate.complete();
    await disconnect;
    connectGate.complete();
    await firstFailure;
    await reconnect;

    expect(grinder.disconnectCalls, 1);
    expect(controller.currentConnectionState, ConnectionState.connected);
    expect(controller.connectedGrinder(), same(grinder));
  });

  test('superseded manager connection cannot overwrite the winner', () async {
    final fixture = await _managerFixture();
    final gate = Completer<void>();
    final first = TestGrinder(deviceId: 'first', connectGate: gate);
    final second = TestGrinder(deviceId: 'second');
    addTearDown(() async {
      await fixture.dispose();
      await first.dispose();
      await second.dispose();
    });

    final firstConnection = fixture.manager.connectGrinder(first);
    await Future<void>.delayed(Duration.zero);
    final secondResult = await fixture.manager.connectGrinder(second);
    gate.complete();
    final firstResult = await firstConnection;

    expect(firstResult.outcome, ConnectionOutcome.failed);
    expect(secondResult.outcome, ConnectionOutcome.connected);
    expect(fixture.settings.preferredGrinderDeviceId, second.deviceId);
    expect(fixture.manager.grinderController.connectedGrinder(), same(second));
  });

  test(
    'manager timeout cancels late completion without persisting it',
    () async {
      final fixture = await _managerFixture(
        connectTimeout: const Duration(milliseconds: 10),
      );
      final gate = Completer<void>();
      final grinder = TestGrinder(deviceId: 'late', connectGate: gate);
      addTearDown(() async {
        await fixture.dispose();
        await grinder.dispose();
      });

      final result = await fixture.manager.connectGrinder(grinder);
      expect(result.outcome, ConnectionOutcome.timedOut);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fixture.settings.preferredGrinderDeviceId, isNull);
      expect(grinder.disconnectCalls, greaterThanOrEqualTo(1));
      expect(
        fixture.manager.grinderController.connectedGrinder,
        throwsA(isA<DeviceNotConnectedException>()),
      );
    },
  );

  test('preferred scan preserves an occupied grinder slot', () async {
    final fixture = await _managerFixture();
    final selected = TestGrinder(deviceId: 'selected');
    final preferred = TestGrinder(deviceId: 'preferred');
    addTearDown(() async {
      await fixture.dispose();
      await selected.dispose();
      await preferred.dispose();
    });
    fixture.discovery.addDevice(selected);
    fixture.discovery.addDevice(preferred);
    await Future<void>.delayed(Duration.zero);
    expect((await fixture.manager.connectGrinder(selected)).success, isTrue);
    await fixture.settings.setPreferredGrinderDeviceId(preferred.deviceId);

    await fixture.manager.connect();

    expect(preferred.onConnectCalls, 0);
    expect(selected.disconnectCalls, 0);
    expect(
      fixture.manager.grinderController.connectedGrinder(),
      same(selected),
    );
  });
}

Future<
  ({
    ConnectionManager manager,
    DeviceController devices,
    MockDeviceDiscoveryService discovery,
    SettingsController settings,
    Future<void> Function() dispose,
  })
>
_managerFixture({Duration? connectTimeout}) async {
  final discovery = MockDeviceDiscoveryService();
  final devices = DeviceController([discovery]);
  await devices.initialize();
  final settings = SettingsController(MockSettingsService());
  await settings.loadSettings();
  final manager = ConnectionManager(
    deviceScanner: devices,
    de1Controller: De1Controller(controller: devices),
    scaleController: ScaleController(),
    grinderController: GrinderController(),
    settingsController: settings,
    connectTimeout: connectTimeout,
  );
  return (
    manager: manager,
    devices: devices,
    discovery: discovery,
    settings: settings,
    dispose: () async {
      await manager.dispose();
      devices.dispose();
      discovery.dispose();
      settings.dispose();
    },
  );
}
