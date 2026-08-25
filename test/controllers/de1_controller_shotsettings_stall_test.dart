import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

class _SilentShotSettingsDe1 extends TestDe1 {
  _SilentShotSettingsDe1() : super(deviceId: 'silent-de1', name: 'SilentDe1');

  final _silent = StreamController<De1ShotSettings>.broadcast();

  int setSteamFlowCalls = 0;
  int setFlushFlowCalls = 0;

  @override
  Stream<De1ShotSettings> get shotSettings => _silent.stream;

  @override
  Future<void> setSteamFlow(double value) async {
    setSteamFlowCalls++;
  }

  @override
  Future<void> setFlushFlow(double value) async {
    setFlushFlowCalls++;
  }

  @override
  Future<void> setFlushTimeout(double value) async {}

  @override
  Future<void> setFlushTemperature(double value) async {}

  @override
  Future<void> dispose() async {
    await _silent.close();
    await super.dispose();
  }
}

Profile _profile() => Profile(
  version: '2',
  title: 'test',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  steps: const [],
  targetVolumeCountStart: 0,
  tankTemperature: 0,
);

Workflow _workflow({required int steamDuration}) => Workflow(
  id: 'wf',
  name: 'wf',
  profile: _profile(),
  steamSettings: SteamSettings(
    targetTemperature: 150,
    duration: steamDuration,
    flow: 1.0,
  ),
  hotWaterData: HotWaterData(
    targetTemperature: 75,
    duration: 30,
    volume: 50,
    flow: 2.0,
  ),
  rinseData: RinseData(targetTemperature: 90, duration: 5, flow: 2.5),
);

class _LateShotSettingsDe1 extends TestDe1 {
  _LateShotSettingsDe1() : super(deviceId: 'late-de1', name: 'LateDe1');

  int fanThresholdCalls = 0;
  final List<String> calls = [];
  Completer<void>? flushGate;

  @override
  Future<void> setFanThreshhold(int temp) async {
    fanThresholdCalls++;
    calls.add('fan');
  }

  @override
  Future<void> setSteamFlow(double value) async {}

  @override
  Future<void> setHotWaterFlow(double value) async {}

  @override
  Future<void> setFlushFlow(double value) async {
    calls.add('flush');
    final gate = flushGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> setFlushTimeout(double value) async {}

  @override
  Future<void> setFlushTemperature(double value) async {}

  @override
  Future<void> updateShotSettings(De1ShotSettings settings) async {}
}

class _QuietSerialDe1 extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final input = StreamController<String>.broadcast(sync: true);
  final writes = <String>[];

  @override
  String get id => 'quiet-serial-de1';

  @override
  String get name => 'QuietSerialDe1';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Stream<String> get readStream => input.stream;

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    if (!input.isClosed) await input.close();
    if (!_connState.isClosed) await _connState.close();
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {
    writes.add(command);
    if (command.startsWith('<E>')) {
      final request = _hexBytes(command.substring(3));
      final response = Uint8List(20);
      response[0] = 20;
      response[1] = request[1];
      response[2] = request[2];
      response[3] = request[3];
      scheduleMicrotask(() => input.add('[E]${_hexString(response)}\n'));
    }
  }
}

Uint8List _hexBytes(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
  }
  return bytes;
}

String _hexString(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<void> waitFor(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late _SilentShotSettingsDe1 de1;

  setUp(() async {
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    de1 = _SilentShotSettingsDe1();
    await de1Controller.connectToDe1(de1);
  });

  tearDown(() async {
    await de1.dispose();
  });

  test('startup defaults still run when shot settings arrive late', () async {
    final controller = De1Controller(controller: deviceController);
    controller.defaultWorkflow = _workflow(steamDuration: 16);
    final lateDe1 = _LateShotSettingsDe1();

    await controller.connectToDe1(lateDe1);
    await Future<void>.delayed(
      ConnectionTimings.initialShotSettingsTimeout +
          const Duration(milliseconds: 200),
    );
    expect(
      lateDe1.fanThresholdCalls,
      0,
      reason: 'the initial shot-settings read must have timed out',
    );

    lateDe1.emitShotSettings(
      De1ShotSettings(
        steamSetting: 0,
        targetSteamTemp: 150,
        targetSteamDuration: 30,
        targetHotWaterTemp: 75,
        targetHotWaterVolume: 50,
        targetHotWaterDuration: 30,
        targetShotVolume: 36,
        groupTemp: 94.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(lateDe1.fanThresholdCalls, 1);
    await lateDe1.dispose();
  });

  test('deferred startup defaults do not overlap an in-flight write', () async {
    final controller = De1Controller(controller: deviceController);
    controller.defaultWorkflow = _workflow(steamDuration: 16);
    final lateDe1 = _LateShotSettingsDe1();
    lateDe1.flushGate = Completer<void>();

    await controller.connectToDe1(lateDe1);
    await Future<void>.delayed(
      ConnectionTimings.initialShotSettingsTimeout +
          const Duration(milliseconds: 200),
    );
    expect(lateDe1.fanThresholdCalls, 0);

    final pendingWrite = controller.updateFlushSettings(
      RinseData(targetTemperature: 92, duration: 6, flow: 2.5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(lateDe1.calls, ['flush']);

    lateDe1.emitShotSettings(
      De1ShotSettings(
        steamSetting: 0,
        targetSteamTemp: 150,
        targetSteamDuration: 30,
        targetHotWaterTemp: 75,
        targetHotWaterVolume: 50,
        targetHotWaterDuration: 30,
        targetShotVolume: 36,
        groupTemp: 94.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      lateDe1.fanThresholdCalls,
      0,
      reason: 'late startup defaults must wait for the device write queue',
    );

    lateDe1.flushGate!.complete();
    await pendingWrite;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(lateDe1.fanThresholdCalls, 1);
    expect(lateDe1.calls.first, 'flush');
    expect(lateDe1.calls.indexOf('fan'), greaterThan(0));
    await lateDe1.dispose();
  });

  test(
    'steam write fails fast when the DE1 never reports shot settings',
    () async {
      await expectLater(
        de1Controller.updateWorkflowSettings(
          _workflow(steamDuration: 30),
          _workflow(steamDuration: 16),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'a stalled shot-settings read does not wedge the device write queue',
    () async {
      await expectLater(
        de1Controller.updateWorkflowSettings(
          _workflow(steamDuration: 30),
          _workflow(steamDuration: 16),
        ),
        throwsA(isA<TimeoutException>()),
      );

      await de1Controller
          .updateFlushSettings(
            RinseData(targetTemperature: 92, duration: 6, flow: 2.5),
          )
          .timeout(const Duration(seconds: 5));

      expect(de1.setFlushFlowCalls, 1);
    },
  );

  test('serial defaults and steam writes work without a K push', () async {
    final controller = De1Controller(controller: deviceController);
    controller.defaultWorkflow = _workflow(steamDuration: 16);
    final serial = _QuietSerialDe1();
    final de1 = UnifiedDe1(transport: serial);
    addTearDown(de1.dispose);

    // A serial machine never pushes K; the transport seeds the subject
    // from its local mirror, so the controller can write defaults and
    // steam settings without any machine cooperation.
    await controller.connectToDe1(de1);

    await waitFor(
      () => serial.writes.any((w) => w.startsWith('<K>009610')),
      'the mirror-seeded defaults to write configured steam duration 16',
    );

    expect(
      serial.writes.where((w) => w == '<-K>'),
      isEmpty,
      reason:
          'no re-arm may be issued (the connect-time <+K> subscribe is expected)',
    );
    final steamIndex = serial.writes.indexWhere(
      (w) => w.startsWith('<K>009610'),
    );
    final fanIndex = serial.writes.indexWhere(
      (w) => w.startsWith('<F>04803808'),
    );
    expect(
      fanIndex,
      isNonNegative,
      reason: 'startup defaults start with the fan-threshold write',
    );
    expect(
      steamIndex,
      greaterThan(fanIndex),
      reason: 'device writes stay serialized: fan before steam',
    );
  });
}
