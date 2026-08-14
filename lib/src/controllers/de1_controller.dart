import 'dart:async';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/home_feature/forms/hot_water_form.dart';
import 'package:reaprime/src/home_feature/forms/steam_form.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

part 'de1_controller.defaults.dart';

class De1Controller {
  final DeviceController _deviceController;

  Workflow? defaultWorkflow;

  De1Interface? _de1;
  final Logger _log = Logger("De1Controller");

  final BehaviorSubject<De1Interface?> _de1Controller = BehaviorSubject.seeded(
    null,
  );

  Stream<De1Interface?> get de1 => _de1Controller.stream;

  final BehaviorSubject<SteamSettings> _steamDataController =
      BehaviorSubject.seeded(
        SteamSettings(targetTemperature: 0, flow: 0, duration: 0),
      );

  Stream<SteamSettings> get steamData => _steamDataController.stream;

  final BehaviorSubject<HotWaterData> _hotWaterDataController =
      BehaviorSubject.seeded(
        HotWaterData(targetTemperature: 0, flow: 0, duration: 0, volume: 0),
      );

  Stream<HotWaterData> get hotWaterData => _hotWaterDataController.stream;

  final BehaviorSubject<RinseData> _rinseStream = BehaviorSubject.seeded(
    RinseData(duration: 5, targetTemperature: 90, flow: 2.5),
  );

  Stream<RinseData> get rinseData => _rinseStream.stream;

  final BehaviorSubject<ShotStateEvent> _shotStateSubject =
      BehaviorSubject.seeded(ShotStateEvent.idle());

  Stream<ShotStateEvent> get shotState => _shotStateSubject.stream;
  ShotStateEvent get currentShotState => _shotStateSubject.value;

  static final Logger _shotStateLog = Logger('ShotState');

  void publishShotEvent(ShotStateEvent event) {
    _shotStateLog.fine(
      '[shot ${event.shotId ?? '-'}] ${event.event}: ${event.state.name}'
      '${event.decision != null ? ' (${event.decision!.reason.name})' : ''}',
    );
    if (!_shotStateSubject.isClosed) {
      _shotStateSubject.add(event);
    }
  }

  static const Duration _stopIntentWindow = Duration(seconds: 5);
  ShotDecisionReason? _pendingStopIntent;
  DateTime? _pendingStopIntentAt;

  void recordStopIntent(ShotDecisionReason reason) {
    assert(
      reason == ShotDecisionReason.apiStop ||
          reason == ShotDecisionReason.appStop,
      'stop intent must name a command source (apiStop/appStop)',
    );
    _pendingStopIntent = reason;
    _pendingStopIntentAt = clock.now();
  }

  ShotDecisionReason? consumeStopIntent({Duration window = _stopIntentWindow}) {
    final intent = _pendingStopIntent;
    final at = _pendingStopIntentAt;
    _pendingStopIntent = null;
    _pendingStopIntentAt = null;
    if (intent == null || at == null) return null;
    if (clock.now().difference(at) > window) return null;
    return intent;
  }

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _dataInitialized = false;
  Timer? _shotSettingsDebounce;
  Future<void> _deviceWriteQueue = Future<void>.value();

  int _connectionGeneration = 0;

  final BehaviorSubject<int?> _initSettledSubject = BehaviorSubject.seeded(
    null,
  );

  Stream<int?> get initSettled => _initSettledSubject.stream;

  int get connectionGeneration => _connectionGeneration;

  final Duration machineReplacementTimeout;

  De1Controller({
    required DeviceController controller,
    this.machineReplacementTimeout =
        ConnectionTimings.machineReplacementTimeout,
  }) : _deviceController = controller {
    _log.info("checking ${_deviceController.devices}");
  }

  Future<void> connectToDe1(De1Interface de1Interface) async {
    if (de1Interface == _de1) {
      _log.fine("trying to connect to existing de1, exit early");
      return;
    }
    _onDisconnect();
    _log.fine("found de1, connecting");
    try {
      await de1Interface.onConnect();
    } catch (e, st) {
      _log.warning(
        'Failed to connect to ${de1Interface.name} '
        '(${de1Interface.deviceId}): $e',
        e,
        st,
      );
      _onDisconnect();
      rethrow;
    }
    _de1 = de1Interface;
    _de1Controller.add(_de1);

    _subscriptions.add(
      _de1!.ready.listen((ready) {
        if (ready) {
          _initializeData();
        }
      }),
    );

    _subscriptions.add(
      _de1!.connectionState.listen((connectionData) {
        switch (connectionData) {
          case ConnectionState.discovered:
            _log.info("device $_de1 discovered");
          case ConnectionState.connecting:
            _log.info("device $_de1 connecting");
          case ConnectionState.connected:
            _log.info("device $_de1 connected");
          case ConnectionState.disconnecting:
            _log.info("device $_de1 disconnecting");
          case ConnectionState.disconnected:
            _log.info("device $_de1 disconnected, resetting");
            _onDisconnect();
        }
      }),
    );
  }

  void adoptDevice(De1Interface de1Interface) {
    if (de1Interface == _de1) {
      _log.fine('adoptDevice: already connected to this device, exit early');
      return;
    }
    _onDisconnect();
    _de1 = de1Interface;
    _de1Controller.add(_de1);

    _subscriptions.add(
      _de1!.ready.listen((ready) {
        if (ready) {
          _initializeData();
        }
      }),
    );

    _subscriptions.add(
      _de1!.connectionState.listen((connectionData) {
        switch (connectionData) {
          case ConnectionState.disconnected:
            _log.info('device $_de1 disconnected (adopted), resetting');
            _onDisconnect();
          default:
            break;
        }
      }),
    );
  }

  void _onDisconnect() {
    _log.info("resetting de1");
    _connectionGeneration++;
    _de1 = null;
    _de1Controller.add(_de1);
    _dataInitialized = false;
    _initSettledSubject.add(null);
    _shotSettingsDebounce?.cancel();
    _shotSettingsDebounce = null;
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _initializeData() async {
    if (_dataInitialized) {
      _log.warning("Data already initialized, skipping");
      return;
    }
    final generation = _connectionGeneration;
    final device = connectedDe1();

    bool stillCurrent() =>
        generation == _connectionGeneration &&
        identical(device, connectedDe1OrNull);

    _log.info("Initializing DE1 data");
    _dataInitialized = true;

    try {
      _subscriptions.add(device.shotSettings.listen(_shotSettingsUpdate));
      try {
        final settings = await device.shotSettings.first.timeout(
          ConnectionTimings.initialShotSettingsTimeout,
        );
        if (!stillCurrent()) return;
        _shotSettingsUpdate(settings);
      } on TimeoutException catch (e, st) {
        _log.warning(
          'Initial shot settings unavailable; skipping startup defaults',
          e,
          st,
        );
        return;
      } on EndpointUnavailableException catch (e, st) {
        _log.warning(
          'Initial shot settings unavailable; skipping startup defaults',
          e,
          st,
        );
        return;
      }

      try {
        await _setDe1DefaultsFor(device, stillCurrent);
      } catch (e, st) {
        _log.warning(
          'DE1 startup defaults failed; profile sync will still proceed',
          e,
          st,
        );
      }
    } finally {
      if (stillCurrent()) {
        _initSettledSubject.add(generation);
      }
    }
  }

  Future<void> _shotSettingsUpdate(De1ShotSettings data) async {
    _shotSettingsDebounce?.cancel();
    final generation = _connectionGeneration;
    _shotSettingsDebounce = Timer(
      ConnectionTimings.shotSettingsDebounce,
      () async {
        if (generation != _connectionGeneration || _de1 == null) {
          _log.fine(
            'Shot settings debounce fired after disconnect '
            '(gen=$generation, current=$_connectionGeneration) — skipping',
          );
          return;
        }
        _log.info('Processing shot settings update (debounced)');
        try {
          await _processShotSettingsUpdate(data);
        } on DeviceNotConnectedException catch (e) {
          _log.fine('Shot settings update aborted by disconnect: $e');
        } on MmrTimeoutException catch (e) {
          _log.warning(
            'Shot settings update MMR read timed out '
            '(treating as disconnect): $e',
          );
        }
      },
    );
  }

  Future<void> _processShotSettingsUpdate(De1ShotSettings data) async {
    var steamFlow = await connectedDe1().getSteamFlow();
    _steamDataController.add(
      SteamSettings(
        duration: data.targetSteamDuration,
        targetTemperature: data.targetSteamTemp,
        flow: steamFlow,
      ),
    );
    var hwFlow = await connectedDe1().getHotWaterFlow();
    _hotWaterDataController.add(
      HotWaterData(
        volume: data.targetHotWaterVolume,
        flow: hwFlow,
        targetTemperature: data.targetHotWaterTemp,
        duration: data.targetHotWaterDuration,
      ),
    );
    {
      var flow = await connectedDe1().getFlushFlow();
      var time = await connectedDe1().getFlushTimeout();
      var temp = await connectedDe1().getFlushTemperature();
      _rinseStream.add(
        RinseData(
          flow: flow,
          duration: time.toInt(),
          targetTemperature: temp.toInt(),
        ),
      );
    }
  }

  De1Interface connectedDe1() {
    if (_de1 == null) {
      throw const DeviceNotConnectedException.machine();
    }
    return _de1!;
  }

  De1Interface? get connectedDe1OrNull => _de1;

  Future<T> runDeviceWrite<T>(
    Future<T> Function(De1Interface device) write, {
    bool retryOnReplacement = false,
  }) {
    final operation = _deviceWriteQueue.then(
      (_) => _runDeviceWrite(write, retryOnReplacement),
    );
    _deviceWriteQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<T> _runDeviceWrite<T>(
    Future<T> Function(De1Interface device) write,
    bool retryOnReplacement,
  ) async {
    final attempts = retryOnReplacement ? 2 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      De1Interface device;
      try {
        device = connectedDe1();
      } on DeviceNotConnectedException {
        if (!retryOnReplacement || attempt == 0) rethrow;
        final replacement = await _waitForMachineReplacement(
          machineReplacementTimeout,
        );
        if (replacement == null) {
          throw MachineReplacementTimeoutException(machineReplacementTimeout);
        }
        device = replacement;
      }
      final generation = _connectionGeneration;
      try {
        await _waitForInitialization(device, generation);
        if (generation != _connectionGeneration ||
            !identical(device, connectedDe1OrNull)) {
          if (attempt + 1 < attempts) continue;
          break;
        }
        final result = await write(device);
        if (generation == _connectionGeneration &&
            identical(device, connectedDe1OrNull)) {
          return result;
        }
      } catch (_) {
        if (attempt + 1 == attempts ||
            (generation == _connectionGeneration &&
                identical(device, connectedDe1OrNull))) {
          rethrow;
        }
      }
    }
    throw StateError('Machine changed during device write');
  }

  Future<De1Interface?> _waitForMachineReplacement(Duration timeout) async {
    try {
      return await _de1Controller.stream
          .firstWhere((de1) => de1 != null)
          .timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _waitForInitialization(
    De1Interface device,
    int generation,
  ) async {
    if (_initSettledSubject.valueOrNull == generation) return;
    await _initSettledSubject.stream
        .firstWhere(
          (settled) =>
              settled == generation ||
              generation != _connectionGeneration ||
              !identical(device, connectedDe1OrNull),
        )
        .timeout(ConnectionTimings.initialShotSettingsTimeout);
  }

  Future<SteamFormSettings> steamSettings() async {
    if (_de1 == null) {
      throw const DeviceNotConnectedException.machine();
    }
    De1ShotSettings shotSettings = await connectedDe1().shotSettings.first;
    double flowRate = await connectedDe1().getSteamFlow();

    return SteamFormSettings(
      steamEnabled: shotSettings.targetSteamTemp >= 135,
      targetTemp: shotSettings.targetSteamTemp,
      targetDuration: shotSettings.targetSteamDuration,
      targetFlow: flowRate,
    );
  }

  Future<void> updateSteamSettings(SteamFormSettings settings) async {
    await runDeviceWrite(
      (device) => _writeSteamSettings(device, settings),
      retryOnReplacement: true,
    );
    _publishSteamSettings(settings);
  }

  Future<void> _writeSteamSettings(
    De1Interface device,
    SteamFormSettings settings,
  ) async {
    final shotSettings = await device.shotSettings.first;
    await device.setSteamFlow(settings.targetFlow);
    await device.updateShotSettings(
      shotSettings.copyWith(
        targetSteamTemp: settings.steamEnabled ? settings.targetTemp : 0,
        targetSteamDuration: settings.targetDuration,
      ),
    );
  }

  void _publishSteamSettings(SteamFormSettings settings) {
    _steamDataController.add(
      SteamSettings(
        targetTemperature: settings.steamEnabled ? settings.targetTemp : 0,
        duration: settings.targetDuration,
        flow: settings.targetFlow,
      ),
    );
  }

  Future<HotWaterFormSettings> hotWaterSettings() async {
    if (_de1 == null) {
      throw const DeviceNotConnectedException.machine();
    }
    De1ShotSettings shotSettings = await connectedDe1().shotSettings.first;
    double flowRate = await connectedDe1().getHotWaterFlow();
    return HotWaterFormSettings(
      targetTemperature: shotSettings.targetHotWaterTemp,
      flow: flowRate,
      volume: shotSettings.targetHotWaterVolume,
      duration: shotSettings.targetHotWaterDuration,
    );
  }

  Future<void> updateHotWaterSettings(HotWaterFormSettings settings) async {
    await runDeviceWrite(
      (device) => _writeHotWaterSettings(device, settings),
      retryOnReplacement: true,
    );
    _publishHotWaterSettings(settings);
  }

  Future<void> _writeHotWaterSettings(
    De1Interface device,
    HotWaterFormSettings settings,
  ) async {
    await device.setHotWaterFlow(settings.flow);
    final shotSettings = await device.shotSettings.first;
    await device.updateShotSettings(
      shotSettings.copyWith(
        targetHotWaterTemp: settings.targetTemperature,
        targetHotWaterVolume: settings.volume,
        targetHotWaterDuration: settings.duration,
      ),
    );
  }

  void _publishHotWaterSettings(HotWaterFormSettings settings) {
    _hotWaterDataController.add(
      HotWaterData(
        targetTemperature: settings.targetTemperature,
        duration: settings.duration,
        volume: settings.volume,
        flow: settings.flow,
      ),
    );
  }

  Future<void> updateFlushSettings(RinseData settings) async {
    await runDeviceWrite(
      (device) => _writeFlushSettings(device, settings),
      retryOnReplacement: true,
    );
    _rinseStream.add(settings);
  }

  Future<void> _writeFlushSettings(
    De1Interface device,
    RinseData settings,
  ) async {
    await device.setFlushTimeout(settings.duration.toDouble());
    await device.setFlushFlow(settings.flow);
    await device.setFlushTemperature(settings.targetTemperature.toDouble());
  }

  Future<void> updateWorkflowSettings(
    Workflow previous,
    Workflow updated,
  ) async {
    final rinseChanged = previous.rinseData != updated.rinseData;
    final steamChanged =
        previous.steamSettings.targetTemperature !=
            updated.steamSettings.targetTemperature ||
        previous.steamSettings.duration != updated.steamSettings.duration ||
        previous.steamSettings.flow != updated.steamSettings.flow;
    final hotWaterChanged = previous.hotWaterData != updated.hotWaterData;
    if (!rinseChanged && !steamChanged && !hotWaterChanged) return;

    final steam = SteamFormSettings(
      steamEnabled: updated.steamSettings.targetTemperature >= 135,
      targetTemp: updated.steamSettings.targetTemperature,
      targetDuration: updated.steamSettings.duration,
      targetFlow: updated.steamSettings.flow,
    );
    final hotWater = HotWaterFormSettings(
      targetTemperature: updated.hotWaterData.targetTemperature,
      flow: updated.hotWaterData.flow,
      volume: updated.hotWaterData.volume,
      duration: updated.hotWaterData.duration,
    );
    await runDeviceWrite((device) async {
      if (rinseChanged) {
        await _writeFlushSettings(device, updated.rinseData);
      }
      if (steamChanged) {
        await _writeSteamSettings(device, steam);
      }
      if (hotWaterChanged) {
        await _writeHotWaterSettings(device, hotWater);
      }
    }, retryOnReplacement: true);
    if (rinseChanged) _rinseStream.add(updated.rinseData);
    if (steamChanged) _publishSteamSettings(steam);
    if (hotWaterChanged) _publishHotWaterSettings(hotWater);
  }

  Future<void> setSteamFlow(double newFlow) async {
    await runDeviceWrite(
      (device) => device.setSteamFlow(newFlow),
      retryOnReplacement: true,
    );
    _publishSteamFlow(newFlow);
  }

  Future<void> setHotWaterFlow(double newFlow) async {
    await runDeviceWrite(
      (device) => device.setHotWaterFlow(newFlow),
      retryOnReplacement: true,
    );
    _publishHotWaterFlow(newFlow);
  }

  Future<void> setFlushFlow(double newFlow) async {
    await runDeviceWrite(
      (device) => device.setFlushFlow(newFlow),
      retryOnReplacement: true,
    );
    _publishFlushFlow(newFlow);
  }

  Future<void> updateMachineSettings({
    bool? usb,
    int? fan,
    double? flushTemp,
    double? flushFlow,
    double? flushTimeout,
    double? hotWaterFlow,
    double? steamFlow,
    int? tankTemp,
    int? steamPurgeMode,
  }) async {
    await runDeviceWrite((device) async {
      if (usb != null) await device.setUsbChargerMode(usb);
      if (fan != null) await device.setFanThreshhold(fan);
      if (flushTemp != null) await device.setFlushTemperature(flushTemp);
      if (flushFlow != null) await device.setFlushFlow(flushFlow);
      if (flushTimeout != null) await device.setFlushTimeout(flushTimeout);
      if (hotWaterFlow != null) await device.setHotWaterFlow(hotWaterFlow);
      if (steamFlow != null) await device.setSteamFlow(steamFlow);
      if (tankTemp != null) await device.setTankTempThreshold(tankTemp);
      if (steamPurgeMode != null) {
        await device.setSteamPurgeMode(steamPurgeMode);
      }
    }, retryOnReplacement: true);
    if (flushFlow != null) _publishFlushFlow(flushFlow);
    if (hotWaterFlow != null) _publishHotWaterFlow(hotWaterFlow);
    if (steamFlow != null) _publishSteamFlow(steamFlow);
  }

  void _publishSteamFlow(double newFlow) {
    final current = _steamDataController.valueOrNull;
    if (current != null) {
      _steamDataController.add(
        SteamSettings(
          targetTemperature: current.targetTemperature,
          duration: current.duration,
          flow: newFlow,
        ),
      );
    }
  }

  void _publishHotWaterFlow(double newFlow) {
    final current = _hotWaterDataController.valueOrNull;
    if (current != null) {
      _hotWaterDataController.add(
        HotWaterData(
          targetTemperature: current.targetTemperature,
          duration: current.duration,
          volume: current.volume,
          flow: newFlow,
        ),
      );
    }
  }

  void _publishFlushFlow(double newFlow) {
    final current = _rinseStream.valueOrNull;
    if (current != null) {
      _rinseStream.add(
        RinseData(
          targetTemperature: current.targetTemperature,
          duration: current.duration,
          flow: newFlow,
        ),
      );
    }
  }

  Future<void> dispose() async {
    _shotSettingsDebounce?.cancel();
    _shotSettingsDebounce = null;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _de1?.dispose();
    _de1 = null;
    if (!_initSettledSubject.isClosed) _initSettledSubject.close();
    if (!_de1Controller.isClosed) _de1Controller.close();
    if (!_steamDataController.isClosed) _steamDataController.close();
    if (!_hotWaterDataController.isClosed) _hotWaterDataController.close();
    if (!_rinseStream.isClosed) _rinseStream.close();
    if (!_shotStateSubject.isClosed) _shotStateSubject.close();
  }
}
