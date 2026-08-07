import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/controllers/workflow_device_sync.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';
import '../helpers/test_scale_controller.dart';

class SpyDe1 implements De1Interface {
  SpyDe1({De1ShotSettings? seed, bool readyState = true}) {
    _shotSettings = BehaviorSubject.seeded(
      seed ??
          De1ShotSettings(
            steamSetting: 0,
            targetSteamTemp: 150,
            targetSteamDuration: 50,
            targetHotWaterTemp: 75,
            targetHotWaterVolume: 50,
            targetHotWaterDuration: 30,
            targetShotVolume: 36,
            groupTemp: 94.0,
          ),
    );
    _ready = BehaviorSubject.seeded(readyState);
  }

  late final BehaviorSubject<De1ShotSettings> _shotSettings;
  late final BehaviorSubject<bool> _ready;

  final List<De1ShotSettings> updateShotSettingsCalls = [];
  final List<Profile> setProfileCalls = [];
  final List<double> setSteamFlowCalls = [];
  final List<double> setHotWaterFlowCalls = [];
  final List<double> setFlushFlowCalls = [];
  final List<double> setFlushTimeoutCalls = [];
  final List<double> setFlushTemperatureCalls = [];
  final List<int> setFanThreshholdCalls = [];
  final List<double> setHeaterIdleTempCalls = [];
  final List<double> setHeaterPhase1FlowCalls = [];
  final List<double> setHeaterPhase2FlowCalls = [];
  final List<double> setHeaterPhase2TimeoutCalls = [];
  final List<double> setFlowEstimationCalls = [];
  final List<int> setSteamPurgeModeCalls = [];
  final List<De1RefillKitSettings> setRefillKitSettingsCalls = [];
  final List<double> steamFlowEntryOrder = [];
  final List<double> steamFlowCompletionOrder = [];

  final List<String> writeOrder = [];

  double? blockedSteamFlow;
  Completer<void>? steamFlowEntered;
  Completer<void>? steamFlowRelease;
  double? failSteamFlow;
  double? blockedHeaterPhase2Flow;
  Completer<void>? heaterPhase2FlowEntered;
  Completer<void>? heaterPhase2FlowRelease;
  double? failHeaterPhase2Flow;

  final List<De1ShotSettings> emittedShotSettings = [];

  @override
  Stream<De1ShotSettings> get shotSettings => _shotSettings.stream.map((e) {
    emittedShotSettings.add(e);
    return e;
  });

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    updateShotSettingsCalls.add(newSettings);
    _shotSettings.add(newSettings);
  }

  @override
  Future<void> setProfile(Profile profile) async {
    setProfileCalls.add(profile);
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    steamFlowEntryOrder.add(newFlow);
    setSteamFlowCalls.add(newFlow);
    writeOrder.add('steam:$newFlow');
    if (newFlow == blockedSteamFlow) {
      if (!(steamFlowEntered?.isCompleted ?? true)) {
        steamFlowEntered!.complete();
      }
      await steamFlowRelease!.future;
    }
    if (newFlow == failSteamFlow) {
      failSteamFlow = null;
      throw StateError('selected steam write failed');
    }
    steamFlowCompletionOrder.add(newFlow);
  }

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    setHotWaterFlowCalls.add(newFlow);
    writeOrder.add('hotWater:$newFlow');
  }

  @override
  Future<void> setFlushFlow(double newFlow) async {
    setFlushFlowCalls.add(newFlow);
    writeOrder.add('flush:$newFlow');
  }

  @override
  Future<void> setFlushTimeout(double newTimeout) async {
    setFlushTimeoutCalls.add(newTimeout);
    writeOrder.add('flushTimeout:$newTimeout');
  }

  @override
  Future<void> setFlushTemperature(double newTemp) async {
    setFlushTemperatureCalls.add(newTemp);
    writeOrder.add('flushTemp:$newTemp');
  }

  void setConnectionState(ConnectionState state) {
    _connectionState.add(state);
  }

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.connected);
  final BehaviorSubject<MachineSnapshot> _snapshot = BehaviorSubject.seeded(
    MachineSnapshot(
      timestamp: DateTime(2026, 1, 1),
      state: const MachineStateSnapshot(
        state: MachineState.idle,
        substate: MachineSubstate.idle,
      ),
      flow: 0,
      pressure: 0,
      targetFlow: 0,
      targetPressure: 0,
      mixTemperature: 0,
      groupTemperature: 0,
      targetMixTemperature: 0,
      targetGroupTemperature: 0,
      profileFrame: 0,
      steamTemperature: 0,
    ),
  );

  @override
  Future<void> dispose() async {
    _shotSettings.close();
    _ready.close();
    _connectionState.close();
    _snapshot.close();
  }

  void setReady(bool ready) => _ready.add(ready);

  @override
  String get deviceId => 'spy-de1';
  @override
  String get name => 'SpyDe1';
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;
  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1',
    model: '1',
    serialNumber: '1',
    groupHeadControllerPresent: false,
    extra: {},
  );
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;
  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshot.stream;
  @override
  Future<void> requestState(MachineState newState) async {}
  @override
  Stream<bool> get ready => _ready.stream;
  @override
  Stream<De1WaterLevels> get waterLevels => const Stream.empty();
  @override
  Future<void> setRefillLevel(int newRefillLevel) async {}
  @override
  Future<void> setFanThreshhold(int temp) async {
    setFanThreshholdCalls.add(temp);
    writeOrder.add('fan:$temp');
  }

  @override
  Future<int> getFanThreshhold() async => 55;
  @override
  Future<int> getTankTempThreshold() async => 0;
  @override
  Future<void> setTankTempThreshold(int temp) async {}
  @override
  Future<double> getSteamFlow() async =>
      setSteamFlowCalls.isEmpty ? 2.1 : setSteamFlowCalls.last;
  @override
  Future<double> getHotWaterFlow() async =>
      setHotWaterFlowCalls.isEmpty ? 10.0 : setHotWaterFlowCalls.last;
  @override
  Future<double> getFlushFlow() async =>
      setFlushFlowCalls.isEmpty ? 6.0 : setFlushFlowCalls.last;
  @override
  Future<double> getFlushTimeout() async =>
      setFlushTimeoutCalls.isEmpty ? 10.0 : setFlushTimeoutCalls.last;
  @override
  Future<double> getFlushTemperature() async =>
      setFlushTemperatureCalls.isEmpty ? 90.0 : setFlushTemperatureCalls.last;
  @override
  Future<double> getFlowEstimation() async => 1.0;
  @override
  double? get cachedFlowEstimation => 1.0;
  @override
  Future<void> setFlowEstimation(double multiplier) async {
    setFlowEstimationCalls.add(multiplier);
    writeOrder.add('flowEstimation:$multiplier');
  }

  @override
  Future<bool> getUsbChargerMode() async => false;
  @override
  Future<void> setUsbChargerMode(bool t) async {}
  @override
  Future<void> setSteamPurgeMode(int mode) async {
    setSteamPurgeModeCalls.add(mode);
    writeOrder.add('steamPurgeMode:$mode');
  }

  @override
  Future<int> getSteamPurgeMode() async => 0;
  @override
  Future<void> enableUserPresenceFeature() async {}
  @override
  Future<void> sendUserPresent() async {}
  @override
  Stream<De1RawMessage> get rawOutStream => const Stream.empty();
  @override
  void sendRawMessage(De1RawMessage message) {}
  @override
  Future<double> getHeaterPhase1Flow() async => 0;
  @override
  Future<void> setHeaterPhase1Flow(double val) async {
    setHeaterPhase1FlowCalls.add(val);
    writeOrder.add('heaterPh1:$val');
  }

  @override
  Future<double> getHeaterPhase2Flow() async => 0;
  @override
  Future<void> setHeaterPhase2Flow(double val) async {
    setHeaterPhase2FlowCalls.add(val);
    writeOrder.add('heaterPh2:$val');
    if (val == blockedHeaterPhase2Flow) {
      if (!(heaterPhase2FlowEntered?.isCompleted ?? true)) {
        heaterPhase2FlowEntered!.complete();
      }
      await heaterPhase2FlowRelease!.future;
    }
    if (val == failHeaterPhase2Flow) {
      failHeaterPhase2Flow = null;
      throw StateError('selected heater phase-2 flow write failed');
    }
  }

  @override
  Future<double> getHeaterPhase2Timeout() async => 0;
  @override
  Future<void> setHeaterPhase2Timeout(double val) async {
    setHeaterPhase2TimeoutCalls.add(val);
    writeOrder.add('heaterPh2Timeout:$val');
  }

  @override
  Future<double> getHeaterIdleTemp() async => 0;
  @override
  Future<void> setHeaterIdleTemp(double val) async {
    setHeaterIdleTempCalls.add(val);
    writeOrder.add('heaterIdleTemp:$val');
  }

  @override
  FirmwareUpdateState get firmwareUpdateState => FirmwareUpdateState.idle;
  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {}
  @override
  Future<void> cancelFirmwareUpload() async {}
  @override
  Future<De1HeaterVoltage> getHeaterVoltage() async => .v110;
  @override
  Future<De1RefillKitSettings> getRefillKitSettings() async => .auto;
  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {}
  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {
    setRefillKitSettingsCalls.add(settings);
    writeOrder.add('refillKit:$settings');
  }
}

Future<void> _settleHandler(SpyDe1 spy) async {
  while (spy.setFanThreshholdCalls.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late SpyDe1 spy;
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late WorkflowController workflowController;
  late Handler handler;

  setUp(() async {
    spy = SpyDe1();
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    await de1Controller.connectToDe1(spy);
    workflowController = WorkflowController();

    final workflowHandler = WorkflowHandler(
      controller: workflowController,
      de1controller: de1Controller,
    );
    final app = Router().plus;
    workflowHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() {
    spy.dispose();
  });

  Future<Response> put(
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/workflow'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json', ...headers},
      ),
    );
  }

  Future<Response> putRaw(String body) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/workflow'),
        body: body,
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  group('PUT /api/v1/workflow — redundant writes', () {
    test('steam-only PUT does not trigger hot-water or flush writes', () async {
      await _settleHandler(spy);
      spy.updateShotSettingsCalls.clear();
      spy.setSteamFlowCalls.clear();
      spy.setHotWaterFlowCalls.clear();
      spy.setFlushFlowCalls.clear();
      spy.setFlushTimeoutCalls.clear();
      spy.setFlushTemperatureCalls.clear();
      spy.setProfileCalls.clear();
      spy.emittedShotSettings.clear();

      unawaited(
        put({
          'steamSettings': {'duration': 30},
        }),
      );
      await _settleHandler(spy);

      expect(
        spy.setHotWaterFlowCalls,
        isEmpty,
        reason:
            'hot-water settings did not change; setHotWaterFlow '
            'must not be invoked',
      );
      expect(
        spy.setFlushFlowCalls,
        isEmpty,
        reason:
            'rinse settings did not change; setFlushFlow must not '
            'be invoked',
      );
      expect(
        spy.setFlushTimeoutCalls,
        isEmpty,
        reason:
            'rinse settings did not change; setFlushTimeout must '
            'not be invoked',
      );
      expect(
        spy.setFlushTemperatureCalls,
        isEmpty,
        reason:
            'rinse settings did not change; setFlushTemperature '
            'must not be invoked',
      );
      expect(
        spy.updateShotSettingsCalls.length,
        equals(1),
        reason:
            'exactly one shot-settings write should be issued per '
            'steam-only change',
      );
      expect(
        spy.updateShotSettingsCalls.single.targetSteamDuration,
        equals(30),
      );
    });

    test('no-op PUT (same values) issues no DE1 writes', () async {
      await _settleHandler(spy);
      final snapshot = workflowController.currentWorkflow;
      spy.updateShotSettingsCalls.clear();
      spy.setSteamFlowCalls.clear();
      spy.setHotWaterFlowCalls.clear();
      spy.setFlushFlowCalls.clear();
      spy.setFlushTimeoutCalls.clear();
      spy.setFlushTemperatureCalls.clear();
      spy.setProfileCalls.clear();

      unawaited(
        put({
          'steamSettings': snapshot.steamSettings.toJson(),
          'hotWaterData': snapshot.hotWaterData.toJson(),
          'rinseData': snapshot.rinseData.toJson(),
        }),
      );
      await _settleHandler(spy);

      expect(spy.updateShotSettingsCalls, isEmpty);
      expect(spy.setSteamFlowCalls, isEmpty);
      expect(spy.setHotWaterFlowCalls, isEmpty);
      expect(spy.setFlushFlowCalls, isEmpty);
      expect(
        spy.setProfileCalls,
        isEmpty,
        reason: 'identical profile must not be re-sent',
      );
    });
  });

  group('PUT /api/v1/workflow — parse errors (issue #338)', () {
    test('invalid ExitType returns 400 instead of hanging forever', () async {
      await _settleHandler(spy);

      final future = put({
        'profile': {
          'steps': [
            {
              'name': 'p',
              'pump': 'flow',
              'transition': 'fast',
              'flow': 2,
              'temperature': 93,
              'sensor': 'coffee',
              'seconds': 10,
              'volume': 0,
              'exit': {'type': 'weight', 'condition': 'over', 'value': 36},
            },
          ],
        },
      });

      await _settleHandler(spy);

      final response = await future;
      expect(response.statusCode, equals(400));
      final body = jsonDecode(await response.readAsString());
      expect(body, isA<Map<String, dynamic>>());
      expect(body['error'], equals('Invalid request'));
      expect(body['message'], isNotNull);
    });

    test(
      'after a failed parse, a subsequent valid PUT succeeds normally',
      () async {
        await _settleHandler(spy);

        final badFuture = put({
          'profile': {
            'steps': [
              {
                'name': 'p',
                'pump': 'flow',
                'transition': 'fast',
                'flow': 2,
                'temperature': 93,
                'sensor': 'coffee',
                'seconds': 10,
                'volume': 0,
                'exit': {'type': 'weight', 'condition': 'over', 'value': 36},
              },
            ],
          },
        });
        await _settleHandler(spy);
        final badResponse = await badFuture;
        expect(badResponse.statusCode, equals(400));

        final goodFuture = put({
          'steamSettings': {'duration': 25},
        });
        await _settleHandler(spy);
        final goodResponse = await goodFuture;
        expect(goodResponse.statusCode, equals(200));
        final goodBody = jsonDecode(await goodResponse.readAsString());
        expect(goodBody['steamSettings']['duration'], equals(25));
      },
    );

    test(
      'empty profile title (Profile.fromJson ArgumentError) returns 400',
      () async {
        await _settleHandler(spy);

        final future = put({
          'profile': {'title': ''},
        });
        await _settleHandler(spy);

        final response = await future;
        expect(response.statusCode, equals(400));
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], equals('Invalid request'));
        expect(body['message'], isNotNull);
      },
    );
  });

  group('PUT /api/v1/workflow — read-modify-write race', () {
    test(
      'multi-field PUT: final shot-settings write reflects BOTH changes',
      () async {
        await _settleHandler(spy);
        spy.updateShotSettingsCalls.clear();
        spy.emittedShotSettings.clear();

        unawaited(
          put({
            'steamSettings': {'duration': 44},
            'hotWaterData': {'duration': 55},
          }),
        );
        await _settleHandler(spy);

        expect(
          spy.updateShotSettingsCalls,
          isNotEmpty,
          reason:
              'steam + hot-water change must produce at least one '
              'shot-settings write',
        );
        final last = spy.updateShotSettingsCalls.last;
        expect(
          last.targetSteamDuration,
          equals(44),
          reason:
              'last updateShotSettings must carry the new steam '
              'duration (lost-write race if stale)',
        );
        expect(
          last.targetHotWaterDuration,
          equals(55),
          reason:
              'last updateShotSettings must carry the new hot-water '
              'duration',
        );
      },
    );

    test(
      'WebSocket-observable stream: final emit reflects BOTH changes',
      () async {
        await _settleHandler(spy);
        spy.emittedShotSettings.clear();

        unawaited(
          put({
            'steamSettings': {'duration': 44},
            'hotWaterData': {'duration': 55},
          }),
        );
        await _settleHandler(spy);

        expect(
          spy.emittedShotSettings,
          isNotEmpty,
          reason: 'handler must produce at least one shotSettings emit',
        );
        final last = spy.emittedShotSettings.last;
        expect(last.targetSteamDuration, equals(44));
        expect(last.targetHotWaterDuration, equals(55));
      },
    );
  });

  group('PUT /api/v1/workflow — request isolation', () {
    test('rapid PUTs from separate clients are not merged', () async {
      await _settleHandler(spy);
      final initial = workflowController.currentWorkflow;
      final firstName = 'First request';
      final secondDescription = 'Second request';

      final firstFuture = put(
        {'name': firstName},
        headers: {'x-test-client': 'first'},
      );
      final secondFuture = put(
        {'description': secondDescription},
        headers: {'x-test-client': 'second'},
      );

      final responses = await Future.wait([firstFuture, secondFuture]);
      expect(responses[0].statusCode, 200);
      expect(responses[1].statusCode, 200);

      final firstBody = jsonDecode(await responses[0].readAsString());
      final secondBody = jsonDecode(await responses[1].readAsString());
      expect(firstBody['name'], firstName);
      expect(firstBody['description'], initial.description);
      expect(secondBody['name'], firstName);
      expect(secondBody['description'], secondDescription);
      expect(firstBody, isNot(equals(secondBody)));
      expect(workflowController.currentWorkflow.name, firstName);
      expect(workflowController.currentWorkflow.description, secondDescription);
    });

    test(
      'continuous PUT traffic does not wait for an inactivity window',
      () async {
        await _settleHandler(spy);
        final trafficStarted = Completer<void>();
        final laterFutures = <Future<Response>>[];
        final firstFuture = put({'name': 'first'});
        final trafficFuture = () async {
          for (var i = 0; i < 4; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            if (!trafficStarted.isCompleted) {
              trafficStarted.complete();
            }
            laterFutures.add(put({'name': 'later-$i'}));
          }
        }();

        late final Response firstResponse;
        try {
          await trafficStarted.future.timeout(const Duration(seconds: 1));
          firstResponse = await firstFuture.timeout(
            const Duration(milliseconds: 250),
          );
        } finally {
          await trafficFuture;
        }

        expect(firstResponse.statusCode, 200);
        final firstBody = jsonDecode(await firstResponse.readAsString());
        expect(firstBody['name'], 'first');
        final laterResponses = await Future.wait(laterFutures);
        expect(
          laterResponses.every((response) => response.statusCode == 200),
          isTrue,
        );
        expect(workflowController.currentWorkflow.name, 'later-3');
      },
    );

    test(
      'a later workflow PUT cannot overtake an in-flight device apply',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final firstFlow = initial.steamSettings.flow + 1;
        final secondFlow = initial.steamSettings.flow + 2;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = firstFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final firstFuture = put({
          'steamSettings': {'flow': firstFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));
        final secondFuture = put({
          'steamSettings': {'flow': secondFlow},
        });
        var secondCompleted = false;
        unawaited(secondFuture.then((_) => secondCompleted = true));

        try {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(spy.steamFlowEntryOrder, [firstFlow]);
          expect(secondCompleted, isFalse);
        } finally {
          release.complete();
        }

        final responses = await Future.wait([
          firstFuture.timeout(const Duration(seconds: 2)),
          secondFuture.timeout(const Duration(seconds: 2)),
        ]);
        expect(responses[0].statusCode, 200);
        expect(responses[1].statusCode, 200);
        expect(spy.steamFlowEntryOrder, [firstFlow, secondFlow]);
        expect(spy.steamFlowCompletionOrder, [firstFlow, secondFlow]);
        expect(spy.setSteamFlowCalls.last, secondFlow);
        expect(
          workflowController.currentWorkflow.steamSettings.flow,
          secondFlow,
        );
      },
    );

    test(
      'a workflow PUT retries on a replacement attached after a disconnected gap',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final defaultFlow = initial.steamSettings.flow;
        final nextFlow = defaultFlow + 1;
        de1Controller.defaultWorkflow = initial;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = nextFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final future = put({
          'steamSettings': {'flow': nextFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        spy.setConnectionState(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.connectedDe1OrNull, isNull);

        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        var completed = false;
        unawaited(future.then((_) => completed = true));
        expect(completed, isFalse);

        final replacement = SpyDe1(readyState: false);
        await de1Controller.connectToDe1(replacement);
        expect(completed, isFalse);
        expect(replacement.setSteamFlowCalls, isEmpty);

        replacement.setReady(true);

        final response = await future.timeout(const Duration(seconds: 2));
        expect(response.statusCode, 200);
        expect(replacement.setSteamFlowCalls, [defaultFlow, nextFlow]);
        expect(replacement.steamFlowCompletionOrder, [defaultFlow, nextFlow]);
        expect(workflowController.currentWorkflow.steamSettings.flow, nextFlow);
        await replacement.dispose();
      },
    );

    test('profile sync waits behind a workflow device write', () async {
      await _settleHandler(spy);
      final sync = WorkflowDeviceSync(
        workflowController: workflowController,
        de1Controller: de1Controller,
      );
      addTearDown(sync.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      spy.setProfileCalls.clear();
      final nextFlow =
          workflowController.currentWorkflow.steamSettings.flow + 1;
      final entered = Completer<void>();
      final release = Completer<void>();
      spy.blockedSteamFlow = nextFlow;
      spy.steamFlowEntered = entered;
      spy.steamFlowRelease = release;

      final future = put({
        'steamSettings': {'flow': nextFlow},
      });
      await entered.future.timeout(const Duration(seconds: 2));
      final initial = workflowController.currentWorkflow;
      final profile = Profile.fromJson({
        ...initial.profile.toJson(),
        'title': 'Queued profile',
      });
      workflowController.setWorkflow(initial.copyWith(profile: profile));
      await Future<void>.delayed(Duration.zero);
      expect(spy.setProfileCalls, isEmpty);

      release.complete();
      expect((await future).statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spy.setProfileCalls, [profile]);
    });

    test('a failed workflow PUT does not poison later queue entries', () async {
      await _settleHandler(spy);
      final initial = workflowController.currentWorkflow;
      final failedFlow = initial.steamSettings.flow + 1;
      final laterFlow = initial.steamSettings.flow + 2;
      final entered = Completer<void>();
      spy.failSteamFlow = failedFlow;
      spy.blockedSteamFlow = failedFlow;
      spy.steamFlowEntered = entered;
      spy.steamFlowRelease = Completer<void>()..complete();

      final failedFuture = put({
        'steamSettings': {'flow': failedFlow},
      });
      await entered.future.timeout(const Duration(seconds: 2));
      final laterFuture = put({
        'steamSettings': {'flow': laterFlow},
      });

      final responses = await Future.wait([
        failedFuture.timeout(const Duration(seconds: 2)),
        laterFuture.timeout(const Duration(seconds: 2)),
      ]);
      expect(responses[0].statusCode, 500);
      expect(responses[1].statusCode, 200);
      expect(spy.setSteamFlowCalls.last, laterFlow);
      expect(workflowController.currentWorkflow.steamSettings.flow, laterFlow);
    });

    test(
      'an identical retry re-applies a failed workflow device write',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final failedFlow = initial.steamSettings.flow + 1;
        spy.failSteamFlow = failedFlow;

        final failedResponse = await put({
          'steamSettings': {'flow': failedFlow},
        });
        expect(failedResponse.statusCode, 500);
        expect(
          workflowController.currentWorkflow.steamSettings.flow,
          initial.steamSettings.flow,
        );

        final retryResponse = await put({
          'steamSettings': {'flow': failedFlow},
        });
        expect(retryResponse.statusCode, 200);
        expect(spy.setSteamFlowCalls, [failedFlow, failedFlow]);
        expect(
          workflowController.currentWorkflow.steamSettings.flow,
          failedFlow,
        );
      },
    );

    test(
      'a concurrent controller mutation survives a blocked REST apply',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final nextFlow = initial.steamSettings.flow + 1;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = nextFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final future = put({
          'steamSettings': {'flow': nextFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        workflowController.setWorkflow(
          initial.copyWith(name: 'Concurrent workflow'),
        );
        release.complete();

        final response = await future.timeout(const Duration(seconds: 2));
        expect(response.statusCode, 200);
        expect(workflowController.currentWorkflow.name, 'Concurrent workflow');
        expect(workflowController.currentWorkflow.steamSettings.flow, nextFlow);
        expect(spy.setSteamFlowCalls, [nextFlow, nextFlow]);
      },
    );

    test(
      'request order is reserved before a streamed body completes',
      () async {
        await _settleHandler(spy);
        final body = StreamController<List<int>>();
        final firstFuture = Future<Response>.sync(
          () => handler(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/v1/workflow'),
              body: body.stream,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        final secondFuture = put({'name': 'second'});
        var secondCompleted = false;
        unawaited(secondFuture.then((_) => secondCompleted = true));

        await Future<void>.delayed(Duration.zero);
        expect(secondCompleted, isFalse);

        body.add(utf8.encode(jsonEncode({'name': 'first'})));
        await body.close();

        final responses = await Future.wait([firstFuture, secondFuture]);
        expect(responses[0].statusCode, 200);
        expect(responses[1].statusCode, 200);
        final firstBody = jsonDecode(await responses[0].readAsString());
        final secondBody = jsonDecode(await responses[1].readAsString());
        expect(firstBody['name'], 'first');
        expect(secondBody['name'], 'second');
        expect(workflowController.currentWorkflow.name, 'second');
      },
    );

    test(
      'a queued body-read failure is observed without poisoning the queue',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final blockedFlow = initial.steamSettings.flow + 1;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = blockedFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final firstFuture = put({
          'steamSettings': {'flow': blockedFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        final body = StreamController<List<int>>();
        final failedFuture = Future<Response>.sync(
          () => handler(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/v1/workflow'),
              body: body.stream,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        body.addError(StateError('body read failed'));
        await body.close();
        await Future<void>.delayed(Duration.zero);
        release.complete();

        final responses = await Future.wait([
          firstFuture.timeout(const Duration(seconds: 2)),
          failedFuture.timeout(const Duration(seconds: 2)),
        ]);
        expect(responses[0].statusCode, 200);
        expect(responses[1].statusCode, 500);
        final nextResponse = await put({'name': 'after body failure'});
        expect(nextResponse.statusCode, 200);
      },
    );

    test(
      'a stalled body cannot hold the workflow queue indefinitely',
      () async {
        await _settleHandler(spy);
        final timeoutHandler = WorkflowHandler(
          controller: workflowController,
          de1controller: de1Controller,
          bodyReadTimeout: const Duration(milliseconds: 20),
        );
        final timeoutApp = Router().plus;
        timeoutHandler.addRoutes(timeoutApp);
        final cancelled = Completer<void>();
        final body = StreamController<List<int>>(
          onCancel: () {
            if (!cancelled.isCompleted) cancelled.complete();
          },
        );
        final stalledFuture = Future<Response>.sync(
          () => timeoutApp.call(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/v1/workflow'),
              body: body.stream,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );

        final stalledResponse = await stalledFuture.timeout(
          const Duration(seconds: 2),
        );
        expect(stalledResponse.statusCode, 408);
        await cancelled.future.timeout(const Duration(seconds: 2));
        expect(body.hasListener, isFalse);
        final nextResponse = await put({'name': 'after body timeout'});
        expect(nextResponse.statusCode, 200);
        await body.close();
      },
    );

    test('an oversized workflow body returns 413', () async {
      final limitedHandler = WorkflowHandler(
        controller: workflowController,
        de1controller: de1Controller,
        maxBodyBytes: 16,
      );
      final limitedApp = Router().plus;
      limitedHandler.addRoutes(limitedApp);

      final response = await limitedApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/workflow'),
          body: jsonEncode({'name': 'this body is too large'}),
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(response.statusCode, 413);
    });

    test('workflow queue rejects excess requests with 429', () async {
      final limitedHandler = WorkflowHandler(
        controller: workflowController,
        de1controller: de1Controller,
        maxPendingRequests: 1,
      );
      final limitedApp = Router().plus;
      limitedHandler.addRoutes(limitedApp);
      final body = StreamController<List<int>>();
      final first = limitedApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/workflow'),
          body: body.stream,
          headers: {'content-type': 'application/json'},
        ),
      );

      final rejected = await limitedApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/workflow'),
          body: jsonEncode({'name': 'rejected'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(rejected.statusCode, 429);

      body.add(utf8.encode(jsonEncode({'name': 'accepted'})));
      await body.close();
      expect((await first).statusCode, 200);
    });

    test('an expired queued workflow PUT is skipped with 503', () async {
      final limitedHandler = WorkflowHandler(
        controller: workflowController,
        de1controller: de1Controller,
        queueWaitTimeout: const Duration(milliseconds: 20),
      );
      final limitedApp = Router().plus;
      limitedHandler.addRoutes(limitedApp);
      final initial = workflowController.currentWorkflow;
      final blockedFlow = initial.steamSettings.flow + 1;
      final entered = Completer<void>();
      final release = Completer<void>();
      spy.blockedSteamFlow = blockedFlow;
      spy.steamFlowEntered = entered;
      spy.steamFlowRelease = release;

      final first = limitedApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/workflow'),
          body: jsonEncode({
            'steamSettings': {'flow': blockedFlow},
          }),
          headers: {'content-type': 'application/json'},
        ),
      );
      await entered.future.timeout(const Duration(seconds: 2));
      final expired = await limitedApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/workflow'),
          body: jsonEncode({'name': 'expired'}),
          headers: {'content-type': 'application/json'},
        ),
      );

      expect(expired.statusCode, 503);
      release.complete();
      expect((await first).statusCode, 200);
      await Future<void>.delayed(Duration.zero);
      expect(workflowController.currentWorkflow.name, initial.name);
    });

    test(
      'malformed or non-object JSON returns 400 without poisoning the queue',
      () async {
        await _settleHandler(spy);

        final malformedResponse = await putRaw('{');
        expect(malformedResponse.statusCode, 400);

        final badResponse = await putRaw('[]');
        expect(badResponse.statusCode, 400);

        final goodResponse = await put({'name': 'after invalid shape'});
        expect(goodResponse.statusCode, 200);
        expect(workflowController.currentWorkflow.name, 'after invalid shape');
      },
    );

    test(
      'an expired 503 request releases admission capacity while an earlier write remains blocked',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final blockedFlow = initial.steamSettings.flow + 1;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = blockedFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final expiringHandler = WorkflowHandler(
          controller: workflowController,
          de1controller: de1Controller,
          queueWaitTimeout: const Duration(milliseconds: 100),
        );
        final expiringApp = Router().plus;
        expiringHandler.addRoutes(expiringApp);
        final expiringCall = expiringApp.call;
        Future<Response> expPut(Map<String, dynamic> body) async {
          return await expiringCall(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/v1/workflow'),
              body: jsonEncode(body),
              headers: {'content-type': 'application/json'},
            ),
          );
        }

        final firstFuture = expPut({
          'steamSettings': {'flow': blockedFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        final expiredResponse = await expPut({
          'steamSettings': {'flow': blockedFlow + 1},
        });
        expect(expiredResponse.statusCode, 503);

        for (var i = 0; i < 7; i++) {
          final response = await expPut({
            'steamSettings': {'flow': blockedFlow + 2 + i},
          });
          expect(response.statusCode, 503, reason: 'request $i must not 429');
        }

        release.complete();
        expect((await firstFuture).statusCode, 200);
      },
    );

    test(
      'a workflow PUT returns 503 when no replacement appears within the bounded wait',
      () async {
        final shortSpy = SpyDe1();
        final shortWaitController = De1Controller(
          controller: deviceController,
          machineReplacementTimeout: const Duration(milliseconds: 100),
        );
        await shortWaitController.connectToDe1(shortSpy);
        final shortWorkflowController = WorkflowController();
        final shortHandler = WorkflowHandler(
          controller: shortWorkflowController,
          de1controller: shortWaitController,
        );
        final shortApp = Router().plus;
        shortHandler.addRoutes(shortApp);
        final shortCall = shortApp.call;

        final initial = shortWorkflowController.currentWorkflow;
        final nextFlow = initial.steamSettings.flow + 1;
        final entered = Completer<void>();
        final release = Completer<void>();
        shortSpy.blockedSteamFlow = nextFlow;
        shortSpy.steamFlowEntered = entered;
        shortSpy.steamFlowRelease = release;

        final future = () async {
          return await shortCall(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/v1/workflow'),
              body: jsonEncode({
                'steamSettings': {'flow': nextFlow},
              }),
              headers: {'content-type': 'application/json'},
            ),
          );
        }();
        await entered.future.timeout(const Duration(seconds: 2));

        shortSpy.setConnectionState(ConnectionState.disconnected);
        release.complete();

        final response = await future.timeout(const Duration(seconds: 5));
        expect(response.statusCode, 503);
        expect(
          shortWorkflowController.currentWorkflow.steamSettings.flow,
          initial.steamSettings.flow,
          reason: 'workflow must not be committed without a machine',
        );
        await shortWaitController.dispose();
        await shortSpy.dispose();
      },
    );
  });

  group('PUT /api/v1/workflow — stop-at-temperature guarantee', () {
    test(
      'a stopAtTemperature-only PUT causes no DE1 steam-setting write while preserving the workflow value',
      () async {
        await _settleHandler(spy);
        spy.updateShotSettingsCalls.clear();
        spy.setSteamFlowCalls.clear();
        spy.setHotWaterFlowCalls.clear();
        spy.setFlushFlowCalls.clear();
        spy.setFlushTimeoutCalls.clear();
        spy.setFlushTemperatureCalls.clear();

        final response = await put({
          'steamSettings': {'stopAtTemperature': 60},
        });

        expect(response.statusCode, 200);
        expect(
          workflowController.currentWorkflow.steamSettings.stopAtTemperature,
          60,
        );
        expect(spy.updateShotSettingsCalls, isEmpty);
        expect(spy.setSteamFlowCalls, isEmpty);
        expect(spy.setHotWaterFlowCalls, isEmpty);
        expect(spy.setFlushFlowCalls, isEmpty);
        expect(spy.setFlushTimeoutCalls, isEmpty);
        expect(spy.setFlushTemperatureCalls, isEmpty);
      },
    );

    test(
      'a stopAtTemperature-only PUT commits while no machine is connected',
      () async {
        final isolatedSpy = SpyDe1();
        final isolatedController = De1Controller(controller: deviceController);
        await isolatedController.connectToDe1(isolatedSpy);
        await isolatedController.dispose();
        final isolatedWorkflowController = WorkflowController();
        final isolatedHandler = WorkflowHandler(
          controller: isolatedWorkflowController,
          de1controller: isolatedController,
        );
        final isolatedApp = Router().plus;
        isolatedHandler.addRoutes(isolatedApp);

        final response = await isolatedApp.call(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/v1/workflow'),
            body: jsonEncode({
              'steamSettings': {'stopAtTemperature': 65},
            }),
            headers: {'content-type': 'application/json'},
          ),
        );

        expect(response.statusCode, 200);
        expect(
          isolatedWorkflowController
              .currentWorkflow
              .steamSettings
              .stopAtTemperature,
          65,
        );
        expect(isolatedSpy.updateShotSettingsCalls, isEmpty);
        await isolatedSpy.dispose();
      },
    );
  });

  group('POST /api/v1/machine/settings — shared write queue', () {
    late Handler settingsHandler;

    setUp(() async {
      final mockSettings = MockSettingsService();
      final settingsController = SettingsController(mockSettings);
      await settingsController.loadSettings();
      final de1Handler = De1Handler(
        controller: de1Controller,
        settingsController: settingsController,
        scaleController: TestScaleController(TestScale()),
        workflowController: workflowController,
      );
      final app = Router().plus;
      de1Handler.addRoutes(app);
      settingsHandler = app.call;
    });

    Future<Response> postSettings(Map<String, dynamic> body) async {
      return await settingsHandler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/machine/settings'),
          body: jsonEncode(body),
          headers: {'content-type': 'application/json'},
        ),
      );
    }

    test(
      'fields from one settings request cannot be interleaved with another device write',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final blockedFlow = initial.steamSettings.flow + 1;
        final settingsSteamFlow = initial.steamSettings.flow + 2;
        final settingsHotWaterFlow = initial.hotWaterData.flow + 1;
        final laterSteamFlow = initial.steamSettings.flow + 3;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = blockedFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;
        spy.writeOrder.clear();

        final firstFuture = put({
          'steamSettings': {'flow': blockedFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        final settingsFuture = postSettings({
          'steamFlow': settingsSteamFlow,
          'hotWaterFlow': settingsHotWaterFlow,
        });
        final laterFuture = put({
          'steamSettings': {'flow': laterSteamFlow},
        });

        release.complete();
        final responses = await Future.wait([
          firstFuture,
          settingsFuture,
          laterFuture,
        ]).timeout(const Duration(seconds: 3));

        expect(responses[0].statusCode, 200);
        expect(responses[1].statusCode, 202);
        expect(responses[2].statusCode, 200);
        expect(spy.writeOrder, [
          'steam:$blockedFlow',
          'hotWater:$settingsHotWaterFlow',
          'steam:$settingsSteamFlow',
          'steam:$laterSteamFlow',
        ]);
      },
    );

    test(
      'machine replacement cannot split one settings request across old and new machines',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final steamFlow = initial.steamSettings.flow + 1;
        final hotWaterFlow = initial.hotWaterData.flow + 1;
        final flushTemp = initial.rinseData.targetTemperature + 1;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = steamFlow;
        spy.failSteamFlow = steamFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;
        spy.writeOrder.clear();

        final settingsFuture = postSettings({
          'flushTemp': flushTemp,
          'steamFlow': steamFlow,
          'hotWaterFlow': hotWaterFlow,
        });
        await entered.future.timeout(const Duration(seconds: 2));
        expect(spy.setFlushTemperatureCalls, [flushTemp]);
        expect(spy.setHotWaterFlowCalls, [hotWaterFlow]);
        expect(spy.setSteamFlowCalls, [steamFlow]);

        spy.setConnectionState(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.connectedDe1OrNull, isNull);
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        var completed = false;
        unawaited(settingsFuture.then((_) => completed = true));
        expect(completed, isFalse);

        final replacement = SpyDe1(readyState: false);
        await de1Controller.connectToDe1(replacement);
        expect(completed, isFalse);
        replacement.setReady(true);
        replacement.writeOrder.clear();

        final response = await settingsFuture.timeout(
          const Duration(seconds: 3),
        );
        expect(response.statusCode, 202);
        expect(replacement.writeOrder.sublist(1), [
          'flushTemp:${flushTemp.toDouble()}',
          'hotWater:$hotWaterFlow',
          'steam:$steamFlow',
        ]);
        expect(spy.writeOrder, [
          'flushTemp:${flushTemp.toDouble()}',
          'hotWater:$hotWaterFlow',
          'steam:$steamFlow',
        ]);
        await replacement.dispose();
      },
    );

    test(
      'a successful settings request publishes each changed flow exactly once',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final steamFlow = initial.steamSettings.flow + 2;
        final hotWaterFlow = initial.hotWaterData.flow + 1;
        final flushFlow = initial.rinseData.flow + 1;

        final steamEmits = <double>[];
        final hotWaterEmits = <double>[];
        final flushEmits = <double>[];
        final steamSub = de1Controller.steamData
            .map((e) => e.flow)
            .listen(steamEmits.add);
        final hotWaterSub = de1Controller.hotWaterData
            .map((e) => e.flow)
            .listen(hotWaterEmits.add);
        final flushSub = de1Controller.rinseData
            .map((e) => e.flow)
            .listen(flushEmits.add);

        final response = await postSettings({
          'steamFlow': steamFlow,
          'hotWaterFlow': hotWaterFlow,
          'flushFlow': flushFlow,
        });
        expect(response.statusCode, 202);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(steamEmits.where((f) => f == steamFlow).length, 1);
        expect(hotWaterEmits.where((f) => f == hotWaterFlow).length, 1);
        expect(flushEmits.where((f) => f == flushFlow).length, 1);
        await steamSub.cancel();
        await hotWaterSub.cancel();
        await flushSub.cancel();
      },
    );

    test(
      'no flow publication occurs before a replacement retry succeeds',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final steamFlow = initial.steamSettings.flow + 2;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = steamFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;

        final steamEmits = <double>[];
        final steamSub = de1Controller.steamData
            .map((e) => e.flow)
            .listen(steamEmits.add);

        final settingsFuture = postSettings({'steamFlow': steamFlow});
        await entered.future.timeout(const Duration(seconds: 2));

        spy.setConnectionState(ConnectionState.disconnected);
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(steamEmits.where((f) => f == steamFlow), isEmpty);

        final replacement = SpyDe1(readyState: false);
        await de1Controller.connectToDe1(replacement);
        replacement.setReady(true);
        final response = await settingsFuture.timeout(
          const Duration(seconds: 3),
        );
        expect(response.statusCode, 202);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(steamEmits.where((f) => f == steamFlow).length, 1);
        await steamSub.cancel();
        await replacement.dispose();
      },
    );

    test('no flow publication occurs when replacement waiting fails', () async {
      final shortSpy = SpyDe1();
      final shortController = De1Controller(
        controller: deviceController,
        machineReplacementTimeout: const Duration(milliseconds: 100),
      );
      await shortController.connectToDe1(shortSpy);
      await Future<void>.delayed(Duration.zero);
      final mockSettings = MockSettingsService();
      final settingsController = SettingsController(mockSettings);
      await settingsController.loadSettings();
      final shortDe1Handler = De1Handler(
        controller: shortController,
        settingsController: settingsController,
        scaleController: TestScaleController(TestScale()),
        workflowController: WorkflowController(),
      );
      final shortApp = Router().plus;
      shortDe1Handler.addRoutes(shortApp);
      final shortCall = shortApp.call;

      final initial = WorkflowController().currentWorkflow;
      final steamFlow = initial.steamSettings.flow + 2;
      final entered = Completer<void>();
      final release = Completer<void>();
      shortSpy.blockedSteamFlow = steamFlow;
      shortSpy.steamFlowEntered = entered;
      shortSpy.steamFlowRelease = release;

      final steamEmits = <double>[];
      final steamSub = shortController.steamData
          .map((e) => e.flow)
          .listen(steamEmits.add);

      final settingsFuture = () async {
        return await shortCall(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/machine/settings'),
            body: jsonEncode({'steamFlow': steamFlow}),
            headers: {'content-type': 'application/json'},
          ),
        );
      }();
      await entered.future.timeout(const Duration(seconds: 2));

      shortSpy.setConnectionState(ConnectionState.disconnected);
      release.complete();

      final response = await settingsFuture.timeout(const Duration(seconds: 5));
      expect(response.statusCode, 503);
      expect(steamEmits.where((f) => f == steamFlow), isEmpty);
      await steamSub.cancel();
      await shortController.dispose();
      await shortSpy.dispose();
    });

    test('malformed JSON in a settings request returns 400', () async {
      final response = await settingsHandler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/machine/settings'),
          body: '{not json',
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(response.statusCode, 400);
    });
  });

  group('DELETE /api/v1/machine/settings/reset — shared write queue', () {
    late Handler resetHandler;

    setUp(() async {
      final mockSettings = MockSettingsService();
      final settingsController = SettingsController(mockSettings);
      await settingsController.loadSettings();
      final de1Handler = De1Handler(
        controller: de1Controller,
        settingsController: settingsController,
        scaleController: TestScaleController(TestScale()),
        workflowController: workflowController,
      );
      final app = Router().plus;
      de1Handler.addRoutes(app);
      resetHandler = app.call;
    });

    Future<Response> deleteReset() async => await resetHandler(
      Request(
        'DELETE',
        Uri.parse('http://localhost/api/v1/machine/settings/reset'),
      ),
    );

    test(
      'a reset cannot interleave with another queued machine write',
      () async {
        await _settleHandler(spy);
        final initial = workflowController.currentWorkflow;
        final blockedFlow = initial.steamSettings.flow + 1;
        final laterSteamFlow = initial.steamSettings.flow + 2;
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedSteamFlow = blockedFlow;
        spy.steamFlowEntered = entered;
        spy.steamFlowRelease = release;
        spy.writeOrder.clear();

        final firstFuture = put({
          'steamSettings': {'flow': blockedFlow},
        });
        await entered.future.timeout(const Duration(seconds: 2));

        final resetFuture = deleteReset();
        final laterFuture = put({
          'steamSettings': {'flow': laterSteamFlow},
        });

        release.complete();
        final responses = await Future.wait([
          firstFuture,
          resetFuture,
          laterFuture,
        ]).timeout(const Duration(seconds: 3));

        expect(responses[0].statusCode, 200);
        expect(responses[1].statusCode, 202);
        expect(responses[2].statusCode, 200);
        expect(spy.writeOrder, [
          'steam:$blockedFlow',
          'fan:55',
          'heaterIdleTemp:95.0',
          'heaterPh1:2.0',
          'heaterPh2:4.0',
          'heaterPh2Timeout:4.0',
          'refillKit:De1RefillKitSettings.auto',
          'flowEstimation:1.0',
          'steamPurgeMode:0',
          'steam:$laterSteamFlow',
        ]);
      },
    );

    test(
      'machine replacement cannot split a reset across old and new machines',
      () async {
        await _settleHandler(spy);
        final entered = Completer<void>();
        final release = Completer<void>();
        spy.blockedHeaterPhase2Flow = 4.0;
        spy.failHeaterPhase2Flow = 4.0;
        spy.heaterPhase2FlowEntered = entered;
        spy.heaterPhase2FlowRelease = release;
        spy.writeOrder.clear();

        final resetFuture = deleteReset();
        await entered.future.timeout(const Duration(seconds: 2));
        expect(spy.setFanThreshholdCalls, [55, 55]);
        expect(spy.setHeaterIdleTempCalls, [95]);
        expect(spy.setHeaterPhase1FlowCalls, [2.0]);

        spy.setConnectionState(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.connectedDe1OrNull, isNull);
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        var completed = false;
        unawaited(resetFuture.then((_) => completed = true));
        expect(completed, isFalse);

        final replacement = SpyDe1(readyState: false);
        await de1Controller.connectToDe1(replacement);
        replacement.setReady(true);
        replacement.writeOrder.clear();

        final response = await resetFuture.timeout(const Duration(seconds: 3));
        expect(response.statusCode, 202);
        expect(replacement.writeOrder.sublist(1), [
          'fan:55',
          'heaterIdleTemp:95.0',
          'heaterPh1:2.0',
          'heaterPh2:4.0',
          'heaterPh2Timeout:4.0',
          'refillKit:De1RefillKitSettings.auto',
          'flowEstimation:1.0',
          'steamPurgeMode:0',
        ]);
        expect(spy.writeOrder, [
          'fan:55',
          'heaterIdleTemp:95.0',
          'heaterPh1:2.0',
          'heaterPh2:4.0',
        ]);
        await replacement.dispose();
      },
    );
  });
}
