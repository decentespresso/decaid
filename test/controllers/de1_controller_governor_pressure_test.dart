import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/home_feature/forms/hot_water_form.dart';
import 'package:reaprime/src/home_feature/forms/steam_form.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';

final class _PressureDe1 extends TestDe1 {
  _PressureDe1({super.serialNumber});

  final List<double> flushFlows = [];
  final List<double> steamFlows = [];
  final List<double> hotWaterFlows = [];
  final List<De1ShotSettings> shotSettingsWrites = [];
  final List<String> events = [];
  Completer<void>? blockedFlushStarted;
  Completer<void>? blockedFlushRelease;
  double? blockedFlushFlow;
  Completer<void>? firmwareStarted;
  Completer<void>? firmwareRelease;
  int firmwareWrites = 0;
  bool _disposed = false;
  late De1ShotSettings currentSettings;

  @override
  void emitShotSettings(De1ShotSettings settings) {
    currentSettings = settings;
    super.emitShotSettings(settings);
  }

  @override
  Future<void> setFlushFlow(double newFlow) async {
    flushFlows.add(newFlow);
    if (newFlow == blockedFlushFlow) {
      blockedFlushStarted?.complete();
      await blockedFlushRelease?.future;
    }
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    steamFlows.add(newFlow);
  }

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    hotWaterFlows.add(newFlow);
  }

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    shotSettingsWrites.add(newSettings);
    emitShotSettings(newSettings);
  }

  @override
  Future<void> requestState(MachineState newState) async {
    events.add(newState.name);
    await super.requestState(newState);
  }

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {
    firmwareWrites++;
    firmwareStarted?.complete();
    await firmwareRelease?.future;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await super.dispose();
  }
}

final class _BlockingScale extends TestScale {
  final Completer<void> tareStarted = Completer<void>();
  final Completer<void> tareRelease = Completer<void>();

  @override
  Future<void> tare() async {
    tareCallCount++;
    if (!tareStarted.isCompleted) tareStarted.complete();
    await tareRelease.future;
  }
}

De1ShotSettings _shotSettings() => De1ShotSettings(
  steamSetting: 0,
  targetSteamTemp: 150,
  targetSteamDuration: 30,
  targetHotWaterTemp: 75,
  targetHotWaterVolume: 50,
  targetHotWaterDuration: 30,
  targetShotVolume: 36,
  groupTemp: 94,
);

Future<void> _connect(De1Controller controller, _PressureDe1 machine) async {
  await controller.connectToDe1(machine);
  machine.emitShotSettings(_shotSettings());
  await controller.initSettled.firstWhere((generation) => generation != null);
}

Future<void> _settleErrors(Iterable<Future<void>> futures) {
  return Future.wait(futures.map((future) => future.catchError((_) {})));
}

void main() {
  late DeviceController devices;
  late De1Controller controller;
  late _PressureDe1 machine;
  late List<_PressureDe1> machines;

  setUp(() async {
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = De1Controller(controller: devices, maxPendingDeviceWrites: 4);
    machine = _PressureDe1();
    machines = [machine];
    await _connect(controller, machine);
  });

  tearDown(() async {
    await controller.dispose();
    for (final connected in machines) {
      await connected.dispose();
    }
  });

  Future<_PressureDe1> replace({required String serialNumber}) async {
    final replacement = _PressureDe1(serialNumber: serialNumber);
    machines.add(replacement);
    await _connect(controller, replacement);
    machine = replacement;
    return replacement;
  }

  test('1000 rinse updates retain one pending final value', () async {
    final activeStarted = Completer<void>();
    final activeRelease = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      activeStarted.complete();
      await activeRelease.future;
    });
    await activeStarted.future;

    var superseded = 0;
    final outcomes = <Future<void>>[];
    Future<void>? latest;
    for (var i = 0; i < 1000; i++) {
      final previous = latest;
      latest = controller.updateFlushSettings(
        RinseData(targetTemperature: 90, duration: 5, flow: i.toDouble()),
      );
      if (previous != null) {
        outcomes.add(
          previous.then(
            (_) => fail('superseded rinse write completed successfully'),
            onError: (Object error) {
              expect(error, isA<De1WriteSupersededException>());
              superseded++;
            },
          ),
        );
      }
    }

    expect(controller.pendingDeviceWriteCount, 1);
    expect(controller.pendingDeviceWriteCount, lessThanOrEqualTo(4));
    expect(machine.flushFlows, isEmpty);
    activeRelease.complete();
    await Future.wait([active, latest!, ...outcomes]);

    expect(superseded, 999);
    expect(machine.flushFlows, [999]);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('three replaceable keys coalesce independently', () async {
    final activeStarted = Completer<void>();
    final activeRelease = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      activeStarted.complete();
      await activeRelease.future;
    });
    await activeStarted.future;

    final superseded = <Future<void>>[];
    Future<void>? rinse;
    Future<void>? steam;
    Future<void>? hotWater;
    for (var i = 0; i < 100; i++) {
      if (rinse != null) superseded.add(rinse.catchError((_) {}));
      if (steam != null) superseded.add(steam.catchError((_) {}));
      if (hotWater != null) superseded.add(hotWater.catchError((_) {}));
      rinse = controller.updateFlushSettings(
        RinseData(targetTemperature: 91, duration: 6, flow: i.toDouble()),
      );
      steam = controller.updateSteamSettings(
        SteamFormSettings(
          steamEnabled: true,
          targetTemp: 151,
          targetDuration: i,
          targetFlow: i.toDouble(),
        ),
      );
      hotWater = controller.updateHotWaterSettings(
        HotWaterFormSettings(
          targetTemperature: 76,
          flow: i.toDouble(),
          volume: i,
          duration: i,
        ),
      );
    }

    expect(controller.pendingDeviceWriteCount, 3);
    activeRelease.complete();
    await Future.wait([active, rinse!, steam!, hotWater!, ...superseded]);

    expect(machine.flushFlows, [99]);
    expect(machine.steamFlows, [99]);
    expect(machine.hotWaterFlows, [99]);
    expect(machine.currentSettings.targetSteamDuration, 99);
    expect(machine.currentSettings.targetHotWaterVolume, 99);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('caller timeout leaves physical serialization occupied', () async {
    final events = <String>[];
    final started = Completer<void>();
    final release = Completer<void>();
    final first = controller.runDeviceWrite((_) async {
      events.add('first-start');
      started.complete();
      await release.future;
      events.add('first-end');
    });
    await started.future;
    final second = controller.runDeviceWrite((_) async {
      events.add('second');
    });

    await expectLater(
      first.timeout(const Duration(milliseconds: 10)),
      throwsA(isA<TimeoutException>()),
    );
    expect(events, ['first-start']);
    release.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second']);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('same-machine reconnect reconciles only the pending setting', () async {
    final original = machine;
    final started = Completer<void>();
    final release = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final activeResult = active.catchError((_) {});
    final pending = controller.updateFlushSettings(
      RinseData(targetTemperature: 92, duration: 7, flow: 4.5),
    );

    original.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = await replace(serialNumber: original.serialNumber);
    release.complete();
    await Future.wait([activeResult, pending]);

    expect(original.flushFlows, isEmpty);
    expect(replacement.flushFlows, [4.5]);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('different-machine replacement receives no queued work', () async {
    final original = machine;
    final started = Completer<void>();
    final release = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final activeResult = active.catchError((_) {});
    final imperative = controller.setFlushFlow(7);
    final replaceable = controller.updateFlushSettings(
      RinseData(targetTemperature: 92, duration: 7, flow: 8),
    );
    final imperativeResult = expectLater(
      imperative,
      throwsA(isA<StateError>()),
    );
    final replaceableResult = expectLater(
      replaceable,
      throwsA(isA<StateError>()),
    );

    original.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = await replace(serialNumber: 'different');
    release.complete();
    await Future.wait([activeResult, imperativeResult, replaceableResult]);

    expect(replacement.flushFlows, isEmpty);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('stale completion cannot publish into a new generation', () async {
    final original = machine;
    original.blockedFlushFlow = 6;
    original.blockedFlushStarted = Completer<void>();
    original.blockedFlushRelease = Completer<void>();
    final stale = controller.setFlushFlow(6).catchError((_) {});
    await original.blockedFlushStarted!.future;

    original.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = await replace(serialNumber: original.serialNumber);
    original.blockedFlushRelease!.complete();
    await stale;

    expect(replacement.flushFlows, isEmpty);
    expect((await controller.rinseData.first).flow, isNot(6));
    await controller.setFlushFlow(7);
    expect(replacement.flushFlows, [7]);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('deterministic connection flapping terminates every future', () async {
    final first = machine;
    final started = Completer<void>();
    final release = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final futures = <Future<void>>[
      active,
      controller.setFlushFlow(1),
      controller.updateFlushSettings(
        RinseData(targetTemperature: 90, duration: 5, flow: 2),
      ),
      controller.updateSteamSettings(
        SteamFormSettings(
          steamEnabled: true,
          targetTemp: 150,
          targetDuration: 20,
          targetFlow: 3,
        ),
      ),
    ];

    first.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final second = await replace(serialNumber: first.serialNumber);
    second.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    await replace(serialNumber: first.serialNumber);
    release.complete();
    await _settleErrors(futures).timeout(const Duration(seconds: 2));

    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('idle bypasses a saturated ordinary queue', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      machine.events.add('ordinary-start');
      started.complete();
      await release.future;
    });
    await started.future;
    final pending = List.generate(
      controller.maxPendingDeviceWrites,
      (_) => controller.runDeviceWrite((_) async {}),
    );
    expect(controller.pendingDeviceWriteCount, 4);

    await controller.requestMachineState(MachineState.idle);
    expect(machine.events, ['ordinary-start', 'idle']);
    release.complete();
    await Future.wait([active, ...pending]);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('firmware is exclusive and never replays after disconnect', () async {
    machine.firmwareStarted = Completer<void>();
    machine.firmwareRelease = Completer<void>();
    final firmware = controller
        .updateFirmware(Uint8List(1), onProgress: (_) {})
        .catchError((_) {});
    await machine.firmwareStarted!.future;
    var ordinaryStarted = false;
    final ordinary = controller.runDeviceWrite((_) async {
      ordinaryStarted = true;
    });
    expect(ordinaryStarted, isFalse);

    final original = machine;
    original.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = await replace(serialNumber: original.serialNumber);
    original.firmwareRelease!.complete();
    await firmware;
    await ordinary.catchError((_) {});

    expect(replacement.firmwareWrites, 0);
    expect(ordinaryStarted, isFalse);
    await controller.setFlushFlow(9);
    expect(replacement.flushFlows, [9]);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('DE1 and scale operations remain independent', () async {
    final scale = _BlockingScale();
    final scaleController = ScaleController();
    await scaleController.connectToScale(scale);
    addTearDown(() {
      scaleController.dispose();
      scale.dispose();
    });

    final stalledScale = scaleController.tare();
    await scale.tareStarted.future;
    await controller.setFlushFlow(10);
    expect(machine.flushFlows, [10]);
    scale.tareRelease.complete();
    await stalledScale;

    final de1Started = Completer<void>();
    final de1Release = Completer<void>();
    final stalledDe1 = controller.runDeviceWrite((_) async {
      de1Started.complete();
      await de1Release.future;
    });
    await de1Started.future;
    await scaleController.tare();
    expect(scale.tareCallCount, 2);
    de1Release.complete();
    await stalledDe1;
    expect(controller.pendingDeviceWriteCount, 0);
  });
}
