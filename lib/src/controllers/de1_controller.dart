import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

part 'de1_controller.defaults.dart';
part 'de1_controller.governor.dart';

class De1Controller {
  final DeviceController _deviceController;

  Workflow? defaultWorkflow;

  De1Interface? _de1;
  final Set<String> _seenSerials = {};
  final Logger _log = Logger("De1Controller");

  List<String> get seenSerials => List.unmodifiable(_seenSerials);

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
  final Queue<_PendingDe1Write<dynamic>> _pendingDeviceWrites = Queue();
  _PendingDe1Write<dynamic>? _activeDeviceWrite;
  bool _firmwareUpdatePending = false;
  bool _firmwareUpdateStarted = false;
  bool _firmwareCancellationRequested = false;
  _PendingDe1Write<dynamic>? _pendingFirmwareWrite;

  int _connectionGeneration = 0;
  String _connectionMachineIdentity = '';

  final BehaviorSubject<int?> _initSettledSubject = BehaviorSubject.seeded(
    null,
  );

  Stream<int?> get initSettled => _initSettledSubject.stream;

  int get connectionGeneration => _connectionGeneration;

  final Duration machineReplacementTimeout;
  final int maxPendingDeviceWrites;

  De1Controller({
    required DeviceController controller,
    this.machineReplacementTimeout =
        ConnectionTimings.machineReplacementTimeout,
    this.maxPendingDeviceWrites = 32,
  }) : assert(maxPendingDeviceWrites >= 0),
       _deviceController = controller {
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
    _connectionMachineIdentity = _machineIdentity(de1Interface);
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
    _connectionMachineIdentity = _machineIdentity(de1Interface);
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

  void _recordSerial(De1Interface device) {
    final String serial;
    try {
      serial = device.machineInfo.serialNumber;
    } catch (_) {
      return;
    }
    if (serial.isNotEmpty && serial != '0') {
      _seenSerials.add(serial);
    }
  }

  void recordResolvedSerial(String serial) {
    if (serial.isNotEmpty && serial != '0') {
      _seenSerials.add(serial);
    }
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
    _recordSerial(device);

    try {
      _subscriptions.add(device.shotSettings.listen(_shotSettingsUpdate));
      try {
        final settings = await _readShotSettings(device);
        if (!stillCurrent()) return;
        _shotSettingsUpdate(settings);
      } on TimeoutException catch (e, st) {
        _log.warning(
          'Initial shot settings unavailable; deferring startup defaults',
          e,
          st,
        );
        _deferStartupDefaults(device, stillCurrent);
        return;
      } on EndpointUnavailableException catch (e, st) {
        _log.warning(
          'Initial shot settings unavailable; skipping startup defaults',
          e,
          st,
        );
        return;
      } on DeviceNotConnectedException catch (e, st) {
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

  void _deferStartupDefaults(
    De1Interface device,
    bool Function() stillCurrent,
  ) {
    unawaited(
      device.shotSettings.first
          .then((settings) async {
            if (!stillCurrent()) return;
            _log.info('Shot settings arrived late; applying startup defaults');
            _shotSettingsUpdate(settings);
            await runDeviceWrite((queued) async {
              if (!identical(queued, device) || !stillCurrent()) return;
              await _setDe1DefaultsFor(device, stillCurrent);
            });
          })
          .catchError((Object e, StackTrace st) {
            _log.warning('Deferred startup defaults failed', e, st);
          }),
    );
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

  int get pendingDeviceWriteCount => _pendingDeviceWrites.length;

  Future<T> runDeviceWrite<T>(
    Future<T> Function(De1Interface device) write, {
    De1ReplayPolicy replayPolicy = De1ReplayPolicy.never,
  }) {
    return _enqueueDeviceWrite(write, replayPolicy: replayPolicy);
  }

  Future<void> runReplaceableDeviceWrite(
    String key,
    Future<void> Function(De1Interface device) write,
  ) {
    return _enqueueDeviceWrite(
      write,
      replayPolicy: De1ReplayPolicy.sameMachine,
      coalescingKey: key,
    );
  }

  Future<De1ShotSettings> _readShotSettings(De1Interface device) async {
    try {
      return await device.shotSettings.first.timeout(
        ConnectionTimings.initialShotSettingsTimeout,
      );
    } on StateError {
      throw const DeviceNotConnectedException.machine();
    }
  }

  Future<SteamFormSettings> steamSettings() async {
    if (_de1 == null) {
      throw const DeviceNotConnectedException.machine();
    }
    De1ShotSettings shotSettings = await _readShotSettings(connectedDe1());
    double flowRate = await connectedDe1().getSteamFlow();

    return SteamFormSettings(
      steamEnabled: shotSettings.targetSteamTemp >= 135,
      targetTemp: shotSettings.targetSteamTemp,
      targetDuration: shotSettings.targetSteamDuration,
      targetFlow: flowRate,
    );
  }

  Future<void> updateSteamSettings(SteamFormSettings settings) async {
    await runReplaceableDeviceWrite(
      'workflow.steam',
      (device) => _writeSteamSettings(device, settings),
    );
    _publishSteamSettings(settings);
  }

  Future<void> _writeSteamSettings(
    De1Interface device,
    SteamFormSettings settings,
  ) async {
    final shotSettings = await _readShotSettings(device);
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
    De1ShotSettings shotSettings = await _readShotSettings(connectedDe1());
    double flowRate = await connectedDe1().getHotWaterFlow();
    return HotWaterFormSettings(
      targetTemperature: shotSettings.targetHotWaterTemp,
      flow: flowRate,
      volume: shotSettings.targetHotWaterVolume,
      duration: shotSettings.targetHotWaterDuration,
    );
  }

  Future<void> updateHotWaterSettings(HotWaterFormSettings settings) async {
    await runReplaceableDeviceWrite(
      'workflow.hotWater',
      (device) => _writeHotWaterSettings(device, settings),
    );
    _publishHotWaterSettings(settings);
  }

  Future<void> _writeHotWaterSettings(
    De1Interface device,
    HotWaterFormSettings settings,
  ) async {
    await device.setHotWaterFlow(settings.flow);
    final shotSettings = await _readShotSettings(device);
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
    await runReplaceableDeviceWrite(
      'workflow.rinse',
      (device) => _writeFlushSettings(device, settings),
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
    _ensureReplaceableDeviceWriteCapacity([
      if (rinseChanged) 'workflow.rinse',
      if (steamChanged) 'workflow.steam',
      if (hotWaterChanged) 'workflow.hotWater',
    ]);
    await Future.wait([
      if (rinseChanged) updateFlushSettings(updated.rinseData),
      if (steamChanged) updateSteamSettings(steam),
      if (hotWaterChanged) updateHotWaterSettings(hotWater),
    ]);
  }

  Future<void> setSteamFlow(double newFlow) async {
    await runDeviceWrite((device) => device.setSteamFlow(newFlow));
    _publishSteamFlow(newFlow);
  }

  Future<int> extendSteamDuration(int seconds) {
    return runDeviceWrite((device) async {
      final settings = await _readShotSettings(device);
      final duration = settings.targetSteamDuration + seconds;
      await device.updateShotSettings(
        settings.copyWith(targetSteamDuration: duration),
      );
      return duration;
    });
  }

  Future<void> setHotWaterFlow(double newFlow) async {
    await runDeviceWrite((device) => device.setHotWaterFlow(newFlow));
    _publishHotWaterFlow(newFlow);
  }

  Future<void> setFlushFlow(double newFlow) async {
    await runDeviceWrite((device) => device.setFlushFlow(newFlow));
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
    });
    if (flushTemp != null || flushFlow != null || flushTimeout != null) {
      _publishRinseSettings(
        targetTemperature: flushTemp,
        flow: flushFlow,
        duration: flushTimeout,
      );
    }
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
    _publishRinseSettings(flow: newFlow);
  }

  void _publishRinseSettings({
    double? targetTemperature,
    double? duration,
    double? flow,
  }) {
    final current = _rinseStream.valueOrNull;
    if (current != null) {
      _rinseStream.add(
        RinseData(
          targetTemperature:
              targetTemperature?.toInt() ?? current.targetTemperature,
          duration: duration?.toInt() ?? current.duration,
          flow: flow ?? current.flow,
        ),
      );
    }
  }

  Future<void> requestMachineState(MachineState state) {
    if (state == MachineState.idle) {
      return connectedDe1().requestState(state);
    }
    return runDeviceWrite((device) => device.requestState(state));
  }

  Future<bool> requestMachineStateIf(
    MachineState state,
    bool Function() stillApplicable,
  ) {
    return runDeviceWrite((device) async {
      if (!stillApplicable()) return false;
      await device.requestState(state);
      return true;
    });
  }

  Future<void> sendUserPresent() {
    return runDeviceWrite((device) => device.sendUserPresent());
  }

  Future<bool> requestShotStepSkip(bool Function() stillApplicable) {
    return requestMachineStateIf(MachineState.skipStep, stillApplicable);
  }

  Future<void> updateFirmware(
    Uint8List image, {
    required void Function(double progress) onProgress,
    void Function()? onStart,
  }) {
    if (_firmwareUpdatePending ||
        connectedDe1().firmwareUpdateState != FirmwareUpdateState.idle) {
      throw FirmwareUpdateInProgressException();
    }
    if (_activeDeviceWrite != null &&
        _pendingDeviceWrites.length >= maxPendingDeviceWrites) {
      throw De1WriteQueueFullException(maxPendingDeviceWrites);
    }
    _firmwareUpdatePending = true;
    _firmwareUpdateStarted = false;
    _firmwareCancellationRequested = false;
    final queued = _activeDeviceWrite != null;
    final Future<void> operation;
    try {
      operation = runDeviceWrite((device) {
        _pendingFirmwareWrite = null;
        if (_firmwareCancellationRequested) {
          throw const FirmwareUpdateCancelledException();
        }
        _firmwareUpdateStarted = true;
        onStart?.call();
        return device.updateFirmware(image, onProgress: onProgress);
      });
      if (queued) _pendingFirmwareWrite = _pendingDeviceWrites.last;
    } catch (_) {
      _firmwareUpdatePending = false;
      _firmwareUpdateStarted = false;
      _firmwareCancellationRequested = false;
      rethrow;
    }
    void clearState() {
      _firmwareUpdatePending = false;
      _firmwareUpdateStarted = false;
      _firmwareCancellationRequested = false;
    }

    operation.then(
      (_) => clearState(),
      onError: (Object _, StackTrace _) => clearState(),
    );
    return operation;
  }

  Future<void> cancelFirmwareUpload() {
    if (_firmwareUpdatePending && !_firmwareUpdateStarted) {
      _firmwareCancellationRequested = true;
      final pending = _pendingFirmwareWrite;
      _pendingFirmwareWrite = null;
      if (pending != null && _pendingDeviceWrites.remove(pending)) {
        pending.completer.completeError(
          const FirmwareUpdateCancelledException(),
        );
      }
      return Future.value();
    }
    return connectedDe1().cancelFirmwareUpload();
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
