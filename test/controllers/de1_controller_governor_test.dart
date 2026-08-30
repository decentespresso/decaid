import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/home_feature/forms/steam_form.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

final class _GovernorTestDe1 extends TestDe1 {
  _GovernorTestDe1({super.deviceId, super.serialNumber});

  String _resolvedSerial = '';

  void resolveSerial(String serial) {
    _resolvedSerial = serial;
  }

  @override
  MachineInfo get machineInfo {
    final info = super.machineInfo;
    if (_resolvedSerial.isEmpty) return info;
    return MachineInfo(
      version: info.version,
      model: info.model,
      serialNumber: _resolvedSerial,
      groupHeadControllerPresent: info.groupHeadControllerPresent,
      extra: info.extra,
    );
  }

  final List<double> flushFlows = [];
  final List<double> steamFlows = [];
  final List<String> events = [];
  De1ShotSettings? writtenShotSettings;
  Completer<void>? firmwareStarted;
  Completer<void>? firmwareRelease;
  var firmwareCancelCalls = 0;
  var userPresentCalls = 0;

  @override
  Future<void> setFlushFlow(double newFlow) async {
    flushFlows.add(newFlow);
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    steamFlows.add(newFlow);
  }

  @override
  Future<void> requestState(MachineState newState) async {
    events.add(newState.name);
    await super.requestState(newState);
  }

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    writtenShotSettings = newSettings;
  }

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {
    firmwareStarted?.complete();
    await firmwareRelease?.future;
  }

  @override
  Future<void> cancelFirmwareUpload() async {
    firmwareCancelCalls++;
    firmwareRelease?.complete();
  }

  @override
  Future<void> sendUserPresent() async {
    userPresentCalls++;
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

Future<void> _connect(
  De1Controller controller,
  _GovernorTestDe1 machine,
) async {
  await controller.connectToDe1(machine);
  machine.emitShotSettings(_shotSettings());
  await controller.initSettled.firstWhere((generation) => generation != null);
}

void main() {
  late DeviceController devices;
  late De1Controller controller;
  late _GovernorTestDe1 machine;

  setUp(() async {
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = De1Controller(controller: devices, maxPendingDeviceWrites: 2);
    machine = _GovernorTestDe1();
    await _connect(controller, machine);
  });

  tearDown(() async {
    await controller.dispose();
  });

  test('bounds pending writes and preserves FIFO order', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final active = controller.runDeviceWrite((_) async {
      calls.add('active');
      started.complete();
      await release.future;
    });
    await started.future;

    final first = controller.runDeviceWrite((_) async => calls.add('first'));
    final second = controller.runDeviceWrite((_) async => calls.add('second'));
    final rejected = controller.runDeviceWrite((_) async => calls.add('third'));

    expect(controller.pendingDeviceWriteCount, 2);
    await expectLater(rejected, throwsA(isA<De1WriteQueueFullException>()));
    release.complete();
    await Future.wait([active, first, second]);

    expect(calls, ['active', 'first', 'second']);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('failed active write does not stall the next write', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final active = controller.runDeviceWrite((_) async {
      calls.add('active');
      started.complete();
      await release.future;
      throw StateError('failed');
    });
    await started.future;
    final activeResult = expectLater(active, throwsA(isA<StateError>()));
    final next = controller.runDeviceWrite((_) async => calls.add('next'));

    release.complete();
    await Future.wait([activeResult, next]);

    expect(calls, ['active', 'next']);
    expect(controller.pendingDeviceWriteCount, 0);
  });

  test('user-present writes wait behind the active machine write', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final presence = controller.sendUserPresent();
    await Future<void>.delayed(Duration.zero);
    expect(machine.userPresentCalls, 0);

    release.complete();
    await Future.wait([active, presence]);
    expect(machine.userPresentCalls, 1);
  });

  test(
    'steam extension reads and writes settings inside its queue turn',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;

      final extension = controller.extendSteamDuration(10);
      machine.emitShotSettings(
        _shotSettings().copyWith(
          targetSteamTemp: 160,
          targetSteamDuration: 40,
          targetHotWaterTemp: 82,
        ),
      );
      release.complete();
      await active;

      expect(await extension, 50);
      expect(machine.writtenShotSettings?.targetSteamDuration, 50);
      expect(machine.writtenShotSettings?.targetSteamTemp, 160);
      expect(machine.writtenShotSettings?.targetHotWaterTemp, 82);
    },
  );

  test(
    'coalesces pending rinse writes and applies only the final value',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;

      Future<void>? latest;
      final superseded = <Future<void>>[];
      for (var i = 0; i < 100; i++) {
        final previous = latest;
        latest = controller.updateFlushSettings(
          RinseData(targetTemperature: 90, duration: 5, flow: i.toDouble()),
        );
        if (previous != null) {
          superseded.add(
            expectLater(previous, throwsA(isA<De1WriteSupersededException>())),
          );
        }
      }

      expect(controller.pendingDeviceWriteCount, 1);
      release.complete();
      await active;
      await latest;
      await Future.wait(superseded);

      expect(machine.flushFlows, [99]);
      expect(controller.pendingDeviceWriteCount, 0);
    },
  );

  test('coalesces rinse and steam independently', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final rinse1 = controller.updateFlushSettings(
      RinseData(targetTemperature: 90, duration: 5, flow: 1),
    );
    final steam1 = controller.updateSteamSettings(
      SteamFormSettings(
        steamEnabled: true,
        targetTemp: 150,
        targetDuration: 20,
        targetFlow: 1,
      ),
    );
    final rinse1Result = expectLater(
      rinse1,
      throwsA(isA<De1WriteSupersededException>()),
    );
    final steam1Result = expectLater(
      steam1,
      throwsA(isA<De1WriteSupersededException>()),
    );
    final rinse2 = controller.updateFlushSettings(
      RinseData(targetTemperature: 91, duration: 6, flow: 2),
    );
    final steam2 = controller.updateSteamSettings(
      SteamFormSettings(
        steamEnabled: true,
        targetTemp: 151,
        targetDuration: 21,
        targetFlow: 2,
      ),
    );

    expect(controller.pendingDeviceWriteCount, 2);
    release.complete();
    await Future.wait([active, rinse2, steam2, rinse1Result, steam1Result]);

    expect(machine.flushFlows, [2]);
    expect(machine.steamFlows, [2]);
  });

  test('coalescing preserves the pending queue position', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final first = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (_) async => calls.add('first rinse'),
    );
    final firstResult = expectLater(
      first,
      throwsA(isA<De1WriteSupersededException>()),
    );
    final imperative = controller.runDeviceWrite(
      (_) async => calls.add('imperative'),
    );
    final replacement = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (_) async => calls.add('replacement rinse'),
    );

    release.complete();
    await Future.wait([active, firstResult, imperative, replacement]);

    expect(calls, ['replacement rinse', 'imperative']);
  });

  test('coalescing succeeds while the pending queue is full', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final first = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (_) async {},
    );
    final firstResult = expectLater(
      first,
      throwsA(isA<De1WriteSupersededException>()),
    );
    final imperative = controller.runDeviceWrite((_) async {});
    expect(controller.pendingDeviceWriteCount, 2);

    final replacement = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (_) async {},
    );
    expect(controller.pendingDeviceWriteCount, 2);

    release.complete();
    await Future.wait([active, firstResult, imperative, replacement]);
  });

  test('caller timeout does not release the active write', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    var secondStarted = false;
    final second = controller.runDeviceWrite((_) async {
      secondStarted = true;
    });
    await expectLater(
      active.timeout(const Duration(milliseconds: 10)),
      throwsA(isA<TimeoutException>()),
    );
    expect(secondStarted, isFalse);

    release.complete();
    await Future.wait([active, second]);
    expect(secondStarted, isTrue);
  });

  test(
    'pending imperative write does not move to a different machine',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;
      final activeResult = expectLater(active, throwsA(isA<StateError>()));

      var replacementWrites = 0;
      final pending = controller.runDeviceWrite((device) async {
        if (!identical(device, machine)) replacementWrites++;
      });
      final pendingResult = expectLater(pending, throwsA(isA<StateError>()));
      machine.setConnectionState(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      final replacement = _GovernorTestDe1(serialNumber: '2');
      await _connect(controller, replacement);

      release.complete();
      await Future.wait([activeResult, pendingResult]);
      expect(replacementWrites, 0);
      await machine.dispose();
      machine = replacement;
    },
  );

  test(
    'replaceable write may reconcile on the same machine identity',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;
      final activeResult = expectLater(active, throwsA(isA<StateError>()));

      _GovernorTestDe1? writtenDevice;
      final pending = controller.runReplaceableDeviceWrite(
        'workflow.rinse',
        (device) async => writtenDevice = device as _GovernorTestDe1,
      );
      machine.setConnectionState(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      final replacement = _GovernorTestDe1(serialNumber: machine.serialNumber);
      await _connect(controller, replacement);

      release.complete();
      await Future.wait([activeResult, pending]);
      expect(writtenDevice, same(replacement));
      await machine.dispose();
      machine = replacement;
    },
  );

  test('replaceable write does not move to a different machine', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final activeResult = expectLater(active, throwsA(isA<StateError>()));

    var replacementWrites = 0;
    final pending = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (_) async => replacementWrites++,
    );
    final pendingResult = expectLater(pending, throwsA(isA<StateError>()));
    machine.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = _GovernorTestDe1(serialNumber: '2');
    await _connect(controller, replacement);

    release.complete();
    await Future.wait([activeResult, pendingResult]);
    expect(replacementWrites, 0);
    await machine.dispose();
    machine = replacement;
  });

  test('machine identity falls back to device ID', () async {
    await controller.dispose();
    machine = _GovernorTestDe1(deviceId: 'fallback-id', serialNumber: '0');
    controller = De1Controller(controller: devices, maxPendingDeviceWrites: 2);
    await _connect(controller, machine);

    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;
    final activeResult = expectLater(active, throwsA(isA<StateError>()));

    _GovernorTestDe1? writtenDevice;
    final pending = controller.runReplaceableDeviceWrite(
      'workflow.rinse',
      (device) async => writtenDevice = device as _GovernorTestDe1,
    );
    machine.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    final replacement = _GovernorTestDe1(
      deviceId: 'fallback-id',
      serialNumber: '',
    );
    await _connect(controller, replacement);

    release.complete();
    await Future.wait([activeResult, pending]);
    expect(writtenDevice, same(replacement));
    await machine.dispose();
    machine = replacement;
  });

  test('writes queued before serial resolution still drain', () async {
    await controller.dispose();
    machine = _GovernorTestDe1(deviceId: 'legacy-de1', serialNumber: '0');
    controller = De1Controller(controller: devices, maxPendingDeviceWrites: 2);
    await _connect(controller, machine);

    final release = Completer<void>();
    final started = Completer<void>();
    controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    var drained = 0;
    final pending = controller.runDeviceWrite((device) async {
      drained++;
    });
    final pendingResult = expectLater(pending, completes);

    machine.resolveSerial('1338');

    release.complete();
    await pendingResult;
    expect(drained, 1);
    await machine.dispose();
  });

  test(
    'imperative write does not replay on the same machine identity',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;
      final activeResult = expectLater(active, throwsA(isA<StateError>()));

      var replacementWrites = 0;
      final pending = controller.runDeviceWrite((device) async {
        if (!identical(device, machine)) replacementWrites++;
      });
      final pendingResult = expectLater(pending, throwsA(isA<StateError>()));
      machine.setConnectionState(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      final replacement = _GovernorTestDe1(serialNumber: machine.serialNumber);
      await _connect(controller, replacement);

      release.complete();
      await Future.wait([activeResult, pendingResult]);
      expect(replacementWrites, 0);
      await machine.dispose();
      machine = replacement;
    },
  );

  test('idle bypasses an active ordinary write', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      machine.events.add('ordinary');
      started.complete();
      await release.future;
    });
    await started.future;

    await controller.requestMachineState(MachineState.idle);
    expect(machine.events, ['ordinary', 'idle']);

    release.complete();
    await active;
  });

  test('idle bypasses a full pending queue', () async {
    final release = Completer<void>();
    final started = Completer<void>();
    final active = controller.runDeviceWrite((_) async {
      machine.events.add('ordinary');
      started.complete();
      await release.future;
    });
    await started.future;
    final pending = List.generate(
      controller.maxPendingDeviceWrites,
      (_) => controller.runDeviceWrite((_) async {}),
    );
    expect(controller.pendingDeviceWriteCount, 2);

    await controller.requestMachineState(MachineState.idle);
    expect(machine.events, ['ordinary', 'idle']);

    release.complete();
    await Future.wait([active, ...pending]);
  });

  test('firmware excludes earlier and later ordinary writes', () async {
    final ordinaryRelease = Completer<void>();
    final ordinaryStarted = Completer<void>();
    final ordinary = controller.runDeviceWrite((_) async {
      ordinaryStarted.complete();
      await ordinaryRelease.future;
    });
    await ordinaryStarted.future;

    machine.firmwareStarted = Completer<void>();
    machine.firmwareRelease = Completer<void>();
    final firmware = controller.updateFirmware(
      Uint8List(1),
      onProgress: (_) {},
    );
    var laterStarted = false;
    final later = controller.runDeviceWrite((_) async {
      laterStarted = true;
    });
    expect(machine.firmwareStarted!.isCompleted, isFalse);

    ordinaryRelease.complete();
    await ordinary;
    await machine.firmwareStarted!.future;
    expect(laterStarted, isFalse);

    machine.firmwareRelease!.complete();
    await Future.wait([firmware, later]);
    expect(laterStarted, isTrue);
  });

  test('pending firmware can be cancelled before it starts', () async {
    final ordinaryRelease = Completer<void>();
    final ordinaryStarted = Completer<void>();
    final ordinary = controller.runDeviceWrite((_) async {
      ordinaryStarted.complete();
      await ordinaryRelease.future;
    });
    await ordinaryStarted.future;

    machine.firmwareStarted = Completer<void>();
    final firmware = controller.updateFirmware(
      Uint8List(1),
      onProgress: (_) {},
    );

    await controller.cancelFirmwareUpload();
    await expectLater(
      firmware,
      throwsA(isA<FirmwareUpdateCancelledException>()),
    );
    expect(controller.pendingDeviceWriteCount, 0);
    expect(machine.firmwareCancelCalls, 0);

    ordinaryRelease.complete();
    await ordinary;
    expect(machine.firmwareStarted!.isCompleted, isFalse);
  });

  test(
    'active firmware can be cancelled before initialization settles',
    () async {
      await controller.dispose();
      controller = De1Controller(
        controller: devices,
        maxPendingDeviceWrites: 2,
      );
      machine = _GovernorTestDe1();
      await controller.connectToDe1(machine);
      machine.firmwareStarted = Completer<void>();

      final firmware = controller.updateFirmware(
        Uint8List(1),
        onProgress: (_) {},
      );
      expect(controller.pendingDeviceWriteCount, 0);

      await controller.cancelFirmwareUpload();
      machine.emitShotSettings(_shotSettings());

      await expectLater(
        firmware,
        throwsA(isA<FirmwareUpdateCancelledException>()),
      );
      expect(machine.firmwareStarted!.isCompleted, isFalse);
      expect(machine.firmwareCancelCalls, 0);
    },
  );

  test('cancelling queued firmware preserves the following write', () async {
    final ordinaryRelease = Completer<void>();
    final ordinaryStarted = Completer<void>();
    final events = <String>[];
    final ordinary = controller.runDeviceWrite((_) async {
      ordinaryStarted.complete();
      await ordinaryRelease.future;
    });
    await ordinaryStarted.future;

    machine.firmwareStarted = Completer<void>();
    final firmware = controller.updateFirmware(
      Uint8List(1),
      onProgress: (_) {},
    );
    final firmwareResult = expectLater(
      firmware,
      throwsA(isA<FirmwareUpdateCancelledException>()),
    );
    final later = controller.runDeviceWrite((_) async => events.add('later'));

    await controller.cancelFirmwareUpload();
    ordinaryRelease.complete();
    await Future.wait([ordinary, firmwareResult, later]);

    expect(machine.firmwareStarted!.isCompleted, isFalse);
    expect(events, ['later']);
  });

  test('active firmware cancellation reaches the machine', () async {
    machine.firmwareStarted = Completer<void>();
    machine.firmwareRelease = Completer<void>();
    final firmware = controller.updateFirmware(
      Uint8List(1),
      onProgress: (_) {},
    );
    await machine.firmwareStarted!.future;

    await controller.cancelFirmwareUpload();
    await firmware;

    expect(machine.firmwareCancelCalls, 1);
  });
}
