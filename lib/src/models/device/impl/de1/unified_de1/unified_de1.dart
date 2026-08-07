import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_firmwaremodel.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.utils.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/logical_endpoint.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

part 'firmware_mmr_gate.dart';
part 'unified_de1.mmr.dart';
part 'unified_de1.parsing.dart';
part 'unified_de1.profile.dart';
part 'unified_de1.firmware.dart';
part 'unified_de1.raw.dart';
part 'integrated_scale_capability.dart';
part 'led_strip_capability.dart';

final class _FirmwareCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class UnifiedDe1 implements De1Interface {
  static final BleServiceIdentifier advertisingIdentifier =
      BleServiceIdentifier.short('ffff');
  final UnifiedDe1Transport _transport;
  final _firmwareMmrGate = _FirmwareMmrGate();
  final Duration firmwareEraseTimeout;
  final Duration firmwareVerificationTimeout;

  final Logger _log = Logger("DE1");

  Stream<ByteData>? _cachedMmrStream;

  UnifiedDe1({
    required DataTransport transport,
    this.firmwareEraseTimeout = const Duration(seconds: 30),
    this.firmwareVerificationTimeout = const Duration(seconds: 30),
  }) : _transport = UnifiedDe1Transport(transport: transport);

  @override
  Stream<ConnectionState> get connectionState => _transport.connectionState;

  late final Stream<MachineSnapshot> _currentSnapshot = _transport.shotSample
      .map((d) {
        notifyFrom(Endpoint.shotSample, d.buffer.asUint8List());
        return d;
      })
      .withLatestFrom(
        _transport.state.map((d) {
          notifyFrom(Endpoint.stateInfo, d.buffer.asUint8List());
          return d;
        }),
        (snp, st) {
          final snapshot = _parseStateAndShotSample(st, snp);
          _log.finest("new state: ${snapshot.toJson()}");
          return snapshot;
        },
      )
      .shareReplay(maxSize: 1);

  @override
  Stream<MachineSnapshot> get currentSnapshot => _currentSnapshot;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => _transport.transportType;

  MachineInfo? _info;
  @override
  MachineInfo get machineInfo =>
      _info ??
      MachineInfo(
        version: "0",
        model: "Unknown",
        serialNumber: "0",
        groupHeadControllerPresent: false,
        extra: {},
      );

  @override
  Future<void> disconnect() async {
    await cancelFirmwareUpload();
    await onDisconnect();
    await _transport.disconnect();
  }

  /// End-of-life cleanup. Disconnects if still connected, closes the
  /// raw message controller, and disposes the transport (closing all
  /// subjects and releasing native resources). Safe to call more than
  /// once.
  @override
  Future<void> dispose() async {
    // Guard: disconnect first so capability mixin onDisconnect() fires
    // before subjects close.
    try {
      await disconnect();
    } catch (_) {
      // Transport may already be dead
    }
    if (!_rawMessageController.isClosed) {
      _rawMessageController.close();
    }
    await _transport.dispose();
  }

  @override
  Future<int> getFanThreshhold() async {
    return await _readMMRInt(MMRItem.fanThreshold);
  }

  @override
  Future<double> getFlushFlow() async {
    return await _readMMRScaled(MMRItem.flushFlowRate);
  }

  @override
  Future<double> getFlushTemperature() async {
    return await _readMMRScaled(MMRItem.flushTemp);
  }

  @override
  Future<double> getFlushTimeout() async {
    return await _readMMRScaled(MMRItem.flushTimeout);
  }

  @override
  Future<double> getHeaterIdleTemp() async {
    return await _readMMRScaled(MMRItem.waterHeaterIdleTemp);
  }

  @override
  Future<double> getHeaterPhase1Flow() async {
    return await _readMMRScaled(MMRItem.heaterUp1Flow);
  }

  @override
  Future<double> getHeaterPhase2Flow() async {
    return await _readMMRScaled(MMRItem.heaterUp2Flow);
  }

  @override
  Future<double> getHeaterPhase2Timeout() async {
    return await _readMMRScaled(MMRItem.heaterUp2Timeout);
  }

  @override
  Future<double> getHotWaterFlow() async {
    return await _readMMRScaled(MMRItem.hotWaterFlowRate);
  }

  @override
  Future<double> getSteamFlow() async {
    return await _readMMRScaled(MMRItem.targetSteamFlow);
  }

  @override
  Future<int> getTankTempThreshold() async {
    return await _readMMRInt(MMRItem.tankTemp);
  }

  @override
  Future<bool> getUsbChargerMode() async {
    final result = await _readMMRInt(MMRItem.allowUSBCharging);
    return result == 1;
  }

  @override
  Future<double> getFlowEstimation() async {
    final value = await _readMMRScaled(MMRItem.calFlowEst);
    _cachedFlowEstimation = value;
    return value;
  }

  @override
  double? get cachedFlowEstimation => _cachedFlowEstimation;

  @override
  Future<int> getSteamPurgeMode() async {
    return await _readMMRInt(MMRItem.steamPurgeMode);
  }

  @override
  String get name => "DE1";
  int _voltage = -1;
  int _refillKit = -1;
  double? _cachedFlowEstimation;
  int? _connectedModelValue;

  @protected
  int get connectedModelValue => _connectedModelValue!;

  @override
  Future<void> onConnect() async {
    initRawStream();
    await _transport.connect();

    // Connection edge: the device's profile state is unknown (possibly
    // wedged mid-receive in ProfileDownloadInProgress), so the first
    // setProfile must perform a complete upload.
    _currentProfile = null;

    if (_info != null) {
      return;
    }

    final model = _unpackMMRInt(await _mmrRead(MMRItem.v13Model));
    _connectedModelValue = model;
    if (isBengleModelValue(model) && implementation != .bengle) {
      _log.warning(
        'Device model $model indicates Bengle hardware; '
        'continuing in degraded DE1-compatible mode.',
      );
    }
    final ghcInfo = _unpackMMRInt(await _mmrRead(MMRItem.ghcInfo));
    final serial = _unpackMMRInt(await _mmrRead(MMRItem.serialN));
    final firmware = _unpackMMRInt(await _mmrRead(MMRItem.cpuFirmwareBuild));
    _voltage = _unpackMMRInt(await _mmrRead(MMRItem.heaterV));
    _refillKit = _unpackMMRInt(await _mmrRead(MMRItem.refillKitPresent));
    // Warm the flow-calibration cache so shot persistence can read it without a
    // BLE round-trip. Non-fatal: a dropped read just leaves it null.
    try {
      _cachedFlowEstimation = await getFlowEstimation();
    } catch (e) {
      _log.warning('Could not read flow calibration on connect: $e');
    }

    _info = MachineInfo(
      version: "$firmware",
      model: DecentMachineModel.fromInt(model).name,
      serialNumber: "$serial",
      groupHeadControllerPresent: (ghcInfo & 0x04) > 1,
      extra: {'refillKit': (_refillKit & 0x01) != 0, 'voltage': _voltage},
    );

    _log.info("Info: ${_info!.toJson()}");

    await _mmrWrite(MMRItem.refillKitPresent, [0x02]);

    await enableUserPresenceFeature();
  }

  /// Lifecycle hook for capability mixins to release resources on
  /// disconnect. Default: no-op. Subclasses (e.g. `Bengle`) override
  /// to call their capability's dispose method.
  ///
  /// Invoked from [disconnect] before the transport is torn down, so
  /// overrides may still issue BLE writes if final cleanup needs them.
  /// Mirrors [onConnect] as an extension point.
  Future<void> onDisconnect() async {}

  final StreamController<De1RawMessage> _rawMessageController =
      StreamController.broadcast();

  @override
  Stream<De1RawMessage> get rawOutStream => _rawMessageController.stream;

  @override
  Stream<bool> get ready => _transport.connectionState
      .map((state) => state == ConnectionState.connected)
      .asBroadcastStream();

  /// First DE1 firmware build (`machineInfo.version`) that natively honors
  /// cold maintenance requests (airPurge/descale/clean) on a GHC-fitted
  /// machine. Builds below this drop BLE maintenance requests while the machine
  /// is cold (still preheating). On older firmware we mirror de1app's
  /// "onestep_cold" workaround: load a 1°C single-frame profile so the machine
  /// leaves preheat, then send the state (see
  /// `_prepareColdMaintenanceWorkaround`). 1356 is the first fixed build; on
  /// it the workaround is off (`1356 < 1356` is false), so the native firmware
  /// path is exercised. Raise to a high sentinel (e.g. 9999) to force the
  /// workaround back on if 1356 turns out not to natively honor cold
  /// maintenance.
  static const int _kColdMaintenancePromotionMinFwBuild = 1356;

  /// Minimal single-frame 1°C profile mirroring de1app's "onestep_cold"
  /// (`de1_comms.tcl` / `binary.tcl`). Its 1°C group goal is already below the
  /// current group temperature, so the machine stops preheating the group; its
  /// tankTemperature of 0 (written to the tank threshold MMR by
  /// `setProfile`/`_sendProfile`) stops tank preheat too. Both are needed for
  /// the machine to leave preheat and reach the state where a maintenance
  /// request is honored. See `_prepareColdMaintenanceWorkaround`.
  static const Profile _onestepColdProfile = Profile(
    version: '1.0',
    title: 'onestep_cold',
    notes: 'cold maintenance workaround (reaprime)',
    author: 'reaprime',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPressure(
        name: 'onestep_cold',
        transition: TransitionType.fast,
        volume: 0.0,
        seconds: 1.0,
        temperature: 1.0,
        sensor: TemperatureSensor.coffee,
        pressure: 0.0,
      ),
    ],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  @override
  Future<void> requestState(MachineState newState) async {
    // Cold-maintenance workaround: on old firmware + GHC + cold machine, load a
    // 1°C profile so the machine leaves preheat and can honor the maintenance
    // request. setProfile writes the tank threshold MMR from the profile's
    // tankTemperature (0 here), so no separate set-to-0 or restore is needed —
    // the next brew's profile re-sets it, mirroring de1app.
    await _prepareColdMaintenanceWorkaround(newState);
    final Uint8List data = Uint8List(1);
    data[0] = De1StateEnum.fromMachineState(newState).hexValue;
    await _transport.writeWithResponse(Endpoint.requestedState, data);
  }

  /// On old firmware + GHC + cold machine, prepare the onestep_cold workaround:
  /// load a 1°C profile whose tankTemperature is 0. The 1°C group goal stops
  /// group preheat and the 0 tank threshold stops tank preheat, so the machine
  /// leaves preheat and can honor the maintenance request. Mirrors de1app's
  /// `de1_send_pre_maintenance_profile` (machine.tcl) + `de1_send_shot_frames`
  /// (de1_comms.tcl:1505-1514), which sends the frames and the tank-threshold
  /// MMR in one shot. setProfile does both here, so there is nothing to save or
  /// restore — the next brew's setProfile writes that profile's tankTemperature,
  /// exactly as de1app does on every shot. Lives inside `requestState` so EVERY
  /// caller — web API, native debug view, sequencers, presence — gets it.
  /// Non-maintenance states return immediately.
  Future<void> _prepareColdMaintenanceWorkaround(MachineState state) async {
    final isMaintenance =
        state == MachineState.airPurge ||
        state == MachineState.descaling ||
        state == MachineState.cleaning;
    if (!isMaintenance) return;
    final snapshot = await currentSnapshot.first;
    final s = snapshot.state.state;
    final isCold =
        s == MachineState.preheating ||
        s == MachineState.heating ||
        snapshot.state.substate == MachineSubstate.preparingForShot;
    final ghcPresent = machineInfo.groupHeadControllerPresent;
    final fwBuild = int.tryParse(machineInfo.version) ?? 0;
    if (!(isCold &&
        ghcPresent &&
        fwBuild < _kColdMaintenancePromotionMinFwBuild)) {
      return;
    }
    _log.info(
      'Cold maintenance ($state) on GHC + old FW build $fwBuild: '
      'applying onestep_cold workaround (1C profile, tank threshold 0 via '
      'profile.tankTemperature)',
    );
    await setProfile(_onestepColdProfile);
    // Give the firmware time to apply the profile — drop the group target to
    // 1°C and the tank target to 0 — leave preheat, and reach the state where
    // it honors the maintenance request. Mirrors de1app's `after 1000`
    // (machine.tcl).
    await Future.delayed(const Duration(seconds: 1));
  }

  final StreamController<De1RawMessage> _rawInputController =
      StreamController();

  /// Guards `initRawStream()` against a second `.listen()` on the
  /// single-subscription `_rawInputController`. Without this, a
  /// reconnect on the same `UnifiedDe1` instance throws
  /// `Bad state: Stream has already been listened to.` See comms-harden #3.
  bool _rawStreamInitialized = false;
  @override
  void sendRawMessage(De1RawMessage message) {
    _rawInputController.add(message);
  }

  @override
  Future<void> setFanThreshhold(int temp) async {
    await _writeMMRInt(MMRItem.fanThreshold, temp);
  }

  @override
  Future<void> setFlushFlow(double newFlow) async {
    await _writeMMRScaled(MMRItem.flushFlowRate, newFlow);
  }

  @override
  Future<void> setFlushTemperature(double newTemp) async {
    await _writeMMRScaled(MMRItem.flushTemp, newTemp);
  }

  @override
  Future<void> setFlushTimeout(double newTimeout) async {
    await _writeMMRScaled(MMRItem.flushTimeout, newTimeout);
  }

  @override
  Future<void> setHeaterIdleTemp(double val) async {
    await _writeMMRScaled(MMRItem.waterHeaterIdleTemp, val);
  }

  @override
  Future<void> setHeaterPhase1Flow(double val) async {
    await _writeMMRScaled(MMRItem.heaterUp1Flow, val);
  }

  @override
  Future<void> setHeaterPhase2Flow(double val) async {
    await _writeMMRScaled(MMRItem.heaterUp2Flow, val);
  }

  @override
  Future<void> setHeaterPhase2Timeout(double val) async {
    await _writeMMRScaled(MMRItem.heaterUp2Timeout, val);
  }

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    await _writeMMRScaled(MMRItem.hotWaterFlowRate, newFlow);
  }

  Profile? _currentProfile;

  /// Tail of the profile-upload queue. An upload is a stateful multi-write
  /// sequence (header + frames + tail) the firmware consumes as one
  /// conversation; two uploads whose writes interleave on the transport's
  /// per-device queue wedge the firmware's profile-receive state machine
  /// until the GATT timeout. Chaining every [setProfile] onto this future
  /// serializes uploads across ALL callers — `WorkflowDeviceSync`'s
  /// queue-with-coalesce only covers the workflow path; the REST handler
  /// (`POST /api/v1/machine/profile`) and the reconnect defaults push call
  /// [setProfile] directly.
  Future<void> _profileUploadQueue = Future.value();

  @override
  Future<void> setProfile(Profile profile) {
    // Queue unconditionally — the equality guard runs inside the locked
    // section so it sees the cache as of upload start (after any queued
    // uploads finished), not as of call time.
    final upload = _profileUploadQueue.then(
      (_) => _uploadProfileLocked(profile),
    );
    // Keep the queue alive past a failed upload: the chain swallows the
    // error, the caller's future still surfaces it.
    _profileUploadQueue = upload.catchError((_) {});
    return upload;
  }

  Future<void> _uploadProfileLocked(Profile profile) async {
    if (_currentProfile == profile) {
      return;
    }
    // Invalidate the cache for the duration of the upload and assign only
    // after a successful send. A mid-upload throw can leave the firmware
    // wedged mid-receive, so no profile — including the previously
    // successful one — can be assumed present on the device afterwards; a
    // stale cache would silently no-op the recovery upload on the equality
    // guard. See comms-harden #1.
    _currentProfile = null;
    await _sendProfile(profile);
    _currentProfile = profile;
    // Guard against firmware ProfileDownloadInProgress race: the DE1 writes
    // the shot descriptor to internal flash inside APIView::write for the
    // final frame and tail, and only clears ProfileDownloadInProgress when
    // that flash write returns. If a state=espresso request hits the
    // firmware task loop before the flag clears, doEspresso() aborts to
    // HeaterDown and the shot ends after preinfuse. See BC 9788201734.
    // Kept inside the locked section: a queued upload must not start while
    // the firmware is still flushing the previous descriptor.
    await Future.delayed(ConnectionTimings.profileDownloadGuard);
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    await _writeMMRScaled(MMRItem.targetSteamFlow, newFlow);
  }

  @override
  Future<void> setTankTempThreshold(int temp) async {
    await _writeMMRInt(MMRItem.tankTemp, temp);
  }

  @override
  Future<void> setUsbChargerMode(bool t) async {
    await _writeMMRInt(MMRItem.allowUSBCharging, t ? 1 : 0);
  }

  @override
  Future<void> setFlowEstimation(double multiplier) async {
    await _writeMMRScaled(MMRItem.calFlowEst, multiplier);
    _cachedFlowEstimation = multiplier;
  }

  @override
  Future<void> setSteamPurgeMode(int mode) async {
    await _writeMMRInt(MMRItem.steamPurgeMode, mode);
  }

  @override
  Future<void> enableUserPresenceFeature() async {
    await _writeMMRInt(MMRItem.appFeatureFlags, 1);
  }

  @override
  Future<void> sendUserPresent() async {
    await _writeMMRInt(MMRItem.userPresent, 1);
  }

  @override
  Future<void> setRefillLevel(int newRefillLevel) async {
    ByteData value = ByteData(4);
    try {
      value.setUint16(0, 0, Endian.big);
      value.setUint16(2, newRefillLevel * 256, Endian.big);
      await _transport.writeWithResponse(
        Endpoint.waterLevels,
        value.buffer.asUint8List(),
      );
    } catch (e) {
      _log.severe("failed to set water warning", e);
      rethrow;
    }
  }

  @override
  Stream<De1ShotSettings> get shotSettings => _transport.shotSettings
      .map((d) {
        notifyFrom(Endpoint.shotSettings, d.buffer.asUint8List());
        return d;
      })
      .map(_parseShotSettings)
      .distinct();

  @override
  DeviceType get type => DeviceType.machine;

  _FirmwareCancellationToken? _fwCancelToken;
  FirmwareUpdateState _firmwareUpdateState = FirmwareUpdateState.idle;

  @override
  FirmwareUpdateState get firmwareUpdateState => _firmwareUpdateState;

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) {
    if (_firmwareUpdateState != FirmwareUpdateState.idle) {
      throw FirmwareUpdateInProgressException();
    }
    _firmwareUpdateState = FirmwareUpdateState.erasing;
    final token = _FirmwareCancellationToken();
    _fwCancelToken = token;
    return _updateFirmware(fwImage, onProgress, token).whenComplete(() {
      if (identical(_fwCancelToken, token)) {
        _fwCancelToken = null;
        _firmwareUpdateState = FirmwareUpdateState.idle;
      }
    });
  }

  @override
  Future<void> cancelFirmwareUpload() async {
    if (_firmwareUpdateState == FirmwareUpdateState.idle) return;
    _firmwareUpdateState = FirmwareUpdateState.cancelling;
    _fwCancelToken?.cancel();
    try {
      await requestState(MachineState.sleeping);
    } catch (e) {
      _log.warning(
        'cancelFirmwareUpload: failed to request sleeping state: $e',
      );
    }
  }

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    Uint8List data = Uint8List(9);

    int index = 0;
    data[index] = newSettings.steamSetting;
    index++;
    data[index] = newSettings.targetSteamTemp;
    index++;
    data[index] = newSettings.targetSteamDuration;
    index++;
    data[index] = newSettings.targetHotWaterTemp;
    index++;
    data[index] = newSettings.targetHotWaterVolume;
    index++;
    data[index] = newSettings.targetHotWaterDuration;
    index++;
    data[index] = newSettings.targetShotVolume;
    index++;

    data[index] = newSettings.groupTemp.toInt();
    index++;
    data[index] =
        ((newSettings.groupTemp - newSettings.groupTemp.floor()) * 256.0)
            .toInt();
    index++;

    await _transport.writeWithResponse(Endpoint.shotSettings, data);
    _transport.recordLocalShotSettings(ByteData.sublistView(data));
  }

  @override
  Stream<De1WaterLevels> get waterLevels => _transport.waterLevels
      .map((d) {
        notifyFrom(Endpoint.waterLevels, d.buffer.asUint8List());
        return d;
      })
      .map(_parseWaterLevels);

  // ---- Protected surface for capability mixins (`on UnifiedDe1`) ----
  // Mixins reach the transport and MMR plumbing through these methods
  // instead of touching `_transport` / `_log` directly. New capabilities
  // (Bengle cup warmer, integrated scale, etc.) declare `on UnifiedDe1`
  // and call only the @protected API below.

  @protected
  Logger get log => _log;

  /// Override on machine subclasses that need to take an action between
  /// `requestState(sleeping)` and the start of FW image upload.
  ///
  /// Default: no-op. Bengle overrides this to request
  /// `MachineState.fwUpgrade` (state 0x16) — Bengle FW requires entering
  /// that state before the `.dat` upload protocol starts. DE1 doesn't.
  ///
  /// This resolves the TODO at `unified_de1.firmware.dart:13-14` (commented
  /// `requestState(MachineState.fwUpgrade)` originally lived in the shared
  /// upload routine).
  @protected
  Future<void> beforeFirmwareUpload() async {}

  /// Number of 16-byte chunks written per batch during a firmware
  /// upload before pausing for [firmwareUploadBatchPause].
  ///
  /// Tuning rationale: DE1 serial UART has no flow control, so chunks
  /// pile up in the receive buffer faster than the SPI flash writer can
  /// drain them. Periodic pauses prevent overrun. BLE writeWithResponse
  /// provides ack-based backpressure, so no pause is needed.
  ///
  /// Bengle has built-in flow control on serial too,
  /// so it overrides [firmwareUploadBatchPause] to zero — at which
  /// point this value is unused.
  @protected
  int get firmwareUploadBatchSize {
    return switch (_transport.transportType) {
      TransportType.serial => 8,
      _ => 8,
    };
  }

  /// Pause inserted between batches of [firmwareUploadBatchSize] chunks
  /// during a firmware upload. See [firmwareUploadBatchSize] for the
  /// rationale and per-transport tuning.
  @protected
  Duration get firmwareUploadBatchPause {
    return switch (_transport.transportType) {
      TransportType.serial => const Duration(milliseconds: 400),
      _ => Duration.zero,
    };
  }

  /// Writes [data] to [endpoint]. When [withResponse] is `true` (default)
  /// dispatches to [UnifiedDe1Transport.writeWithResponse]; when `false`
  /// dispatches to [UnifiedDe1Transport.write] for fire-and-forget writes.
  @protected
  Future<void> writeEndpoint(
    LogicalEndpoint endpoint,
    Uint8List data, {
    bool withResponse = true,
  }) async {
    if (withResponse) {
      return _transport.writeWithResponse(endpoint, data);
    }
    return _transport.write(endpoint, data);
  }

  @protected
  Future<ByteData> readEndpoint(
    LogicalEndpoint endpoint, {
    Duration? timeout,
  }) async {
    if (endpoint.uuid == null) {
      throw StateError(
        'UnifiedDe1.readEndpoint: endpoint ${endpoint.name} has no BLE read path',
      );
    }
    return _transport.read(endpoint, timeout: timeout);
  }

  /// Returns the broadcast notification stream for [endpoint].
  ///
  /// Two fall-through paths exist for callers to be aware of:
  ///
  /// 1. A known DE1 [Endpoint] that is not a notifying characteristic
  ///    (e.g. [Endpoint.versions], [Endpoint.requestedState],
  ///    [Endpoint.headerWrite]) raises [UnimplementedError] — by design,
  ///    these endpoints are write-only or one-shot reads. Asking for a
  ///    notification stream is a usage bug, not a missing feature.
  /// 2. A non-[Endpoint] [LogicalEndpoint] (capability-supplied — e.g.
  ///    a future `BengleCupWarmerEndpoint`) also raises
  ///    [UnimplementedError]. Runtime subscription wiring for capability
  ///    endpoints lands with the first capability that needs it.
  @protected
  Stream<ByteData> notificationsFor(LogicalEndpoint endpoint) {
    if (endpoint is Endpoint) {
      switch (endpoint) {
        case Endpoint.shotSample:
          return _transport.shotSample;
        case Endpoint.stateInfo:
          return _transport.state;
        case Endpoint.waterLevels:
          return _transport.waterLevels;
        case Endpoint.shotSettings:
          return _transport.shotSettings;
        case Endpoint.readFromMMR:
          return _mmr;
        case Endpoint.fwMapRequest:
          return _transport.fwMapRequest;
        default:
          throw UnimplementedError(
            'UnifiedDe1.notificationsFor: Endpoint.${endpoint.name} is '
            'not a notifying characteristic on UnifiedDe1',
          );
      }
    }
    throw UnimplementedError(
      'UnifiedDe1.notificationsFor: runtime subscription for ${endpoint.name} '
      'lands with capability impl',
    );
  }

  @protected
  Future<int> readMmrInt(MmrAddress addr) async {
    _assertKind(addr, const {
      MmrValueKind.int32,
      MmrValueKind.int16,
      MmrValueKind.boolean,
    }, 'readMmrInt');
    if (addr is MMRItem) return _readMMRInt(addr);
    final raw = await _mmrReadRaw(addr.address);
    return _unpackMMRInt(raw);
  }

  /// Reads a `scaledFloat` MMR address as `raw * addr.readScale`.
  ///
  /// Asymmetric with [writeMmrScaled]: read scaling is purely a
  /// multiplier — there is no `min`/`max` clamp here. Bounds are a
  /// write-side concern (the firmware reports whatever it stored;
  /// callers that need range validation should clamp before writing,
  /// not after reading).
  @protected
  Future<double> readMmrScaled(MmrAddress addr) async {
    _assertKind(addr, const {MmrValueKind.scaledFloat}, 'readMmrScaled');
    if (addr is MMRItem) return _readMMRScaled(addr);
    final raw = await _mmrReadRaw(addr.address);
    return _unpackMMRInt(raw).toDouble() * addr.readScale;
  }

  @protected
  Future<void> writeMmrInt(MmrAddress addr, int value) async {
    _assertKind(addr, const {
      MmrValueKind.int32,
      MmrValueKind.int16,
      MmrValueKind.boolean,
    }, 'writeMmrInt');
    if (addr is MMRItem) return _writeMMRInt(addr, value);
    final clamped = (addr.min != null && addr.max != null)
        ? value.clamp(addr.min!, addr.max!)
        : value;
    return _mmrWriteRaw(addr.address, _packMMRInt(clamped));
  }

  @protected
  Future<void> writeMmrScaled(MmrAddress addr, double value) async {
    _assertKind(addr, const {MmrValueKind.scaledFloat}, 'writeMmrScaled');
    final scaled = (value * addr.writeScale).toInt();
    if (addr is MMRItem) return _writeMMRInt(addr, scaled);
    final clamped = (addr.min != null && addr.max != null)
        ? scaled.clamp(addr.min!, addr.max!)
        : scaled;
    return _mmrWriteRaw(addr.address, _packMMRInt(clamped));
  }

  @protected
  Future<List<int>> readMmrRaw(MmrAddress addr) async {
    if (addr is MMRItem) return _mmrRead(addr);
    return _mmrReadRaw(addr.address);
  }

  @protected
  Future<void> writeMmrRaw(MmrAddress addr, List<int> data) async {
    if (addr is MMRItem) return _mmrWrite(addr, data);
    return _mmrWriteRaw(addr.address, data);
  }

  void _assertKind(MmrAddress addr, Set<MmrValueKind> allowed, String helper) {
    if (!allowed.contains(addr.kind)) {
      throw StateError(
        'UnifiedDe1.$helper: called on ${addr.name} (kind=${addr.kind.name}); '
        'expected one of $allowed',
      );
    }
  }

  // Private getter for MMR stream with notifyFrom called once per event
  // Cached to ensure only one stream chain is created
  Stream<ByteData> get _mmr {
    _cachedMmrStream ??= _transport.mmr.map((d) {
      notifyFrom(Endpoint.readFromMMR, d.buffer.asUint8List());
      return d;
    }).asBroadcastStream();
    return _cachedMmrStream!;
  }

  @override
  Future<De1HeaterVoltage> getHeaterVoltage() async {
    return De1HeaterVoltage.fromInt(_voltage);
  }

  @override
  Future<De1RefillKitSettings> getRefillKitSettings() async {
    return De1RefillKitSettings.fromInt(_refillKit);
  }

  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {
    await _writeMMRInt(MMRItem.heaterV, voltage.voltage);
    _voltage = voltage.voltage;
  }

  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {
    await _writeMMRInt(MMRItem.refillKitPresent, settings.hex);
    _refillKit = settings.hex;
  }
}
