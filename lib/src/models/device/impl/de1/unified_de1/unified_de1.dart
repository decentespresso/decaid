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
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
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
part 'unified_de1.calibration.dart';
part 'unified_de1.parsing.dart';
part 'unified_de1.profile.dart';
part 'unified_de1.firmware.dart';
part 'unified_de1.raw.dart';
part 'integrated_scale_capability.dart';
part 'led_strip_capability.dart';
part 'scale_calibration_capability.dart';
part 'cup_warmer_capability.dart';
part 'wake_schedule_capability.dart';

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
  final Duration calibrationTimeout;
  Future<void> _calibrationQueue = Future<void>.value();

  final Logger _log = Logger("DE1");

  Stream<ByteData>? _cachedMmrStream;

  UnifiedDe1({
    required DataTransport transport,
    this.firmwareEraseTimeout = const Duration(seconds: 30),
    this.firmwareVerificationTimeout = const Duration(seconds: 30),
    this.calibrationTimeout = const Duration(seconds: 4),
  }) : _transport = UnifiedDe1Transport(transport: transport);

  @override
  Stream<ConnectionState> get connectionState => _transport.connectionState;

  late final Stream<MachineSnapshot> _de1Snapshot = _buildSnapshotStream(
    _transport.shotSample,
    Endpoint.shotSample,
    _parseStateAndShotSample,
  );

  late final Stream<MachineSnapshot> _bengleSnapshot = _buildSnapshotStream(
    _transport.bengleShotSample,
    Endpoint.bengleShotSample,
    _parseStateAndBengleShotSample,
  );

  Stream<MachineSnapshot> _buildSnapshotStream(
    Stream<ByteData> source,
    Endpoint endpoint,
    MachineSnapshot? Function(ByteData, ByteData) parse,
  ) => source
      .map((data) {
        notifyFrom(endpoint, data.buffer.asUint8List());
        return data;
      })
      .withLatestFrom(
        _transport.state.map((data) {
          notifyFrom(Endpoint.stateInfo, data.buffer.asUint8List());
          return data;
        }),
        (shot, state) {
          final snapshot = parse(state, shot);
          if (snapshot != null) {
            _log.finest("new state: ${snapshot.toJson()}");
          }
          return snapshot;
        },
      )
      .where((snapshot) => snapshot != null)
      .map((snapshot) => snapshot!)
      .shareReplay(maxSize: 1);

  @override
  Stream<MachineSnapshot> get currentSnapshot =>
      implementation == .bengle ? _bengleSnapshot : _de1Snapshot;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => _transport.transportType;

  MachineInfo? _info;
  MachineInfo? _rawInfo;

  MachineInfo get rawMachineInfo => _rawInfo ?? machineInfo;

  int? get rawModelValue => _connectedModelValue;

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

  void applyEffectiveIdentity({required String serial, required String model}) {
    final info = _info;
    if (info == null) return;
    _rawInfo ??= info;
    _info = MachineInfo(
      version: info.version,
      model: model,
      serialNumber: serial,
      groupHeadControllerPresent: info.groupHeadControllerPresent,
      extra: info.extra,
    );
  }

  void clearEffectiveIdentity() {
    _info = _rawInfo ?? _info;
    _rawInfo = null;
  }

  @override
  Future<void> disconnect() async {
    await cancelFirmwareUpload();
    await onDisconnect();
    await _transport.disconnect();
  }

  @override
  Future<void> dispose() async {
    try {
      await disconnect();
    } catch (_) {}
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
  int _refillKitDetected = -1;
  De1RefillKitSettings _refillKitSetting = De1RefillKitSettings.auto;
  double? _cachedFlowEstimation;
  int? _connectedModelValue;

  @protected
  int get connectedModelValue => _connectedModelValue!;

  /// True when this machine should be driven as a Bengle — by the class picked
  /// at discovery OR by the v13Model the firmware reported. Either alone is
  /// insufficient: a `Bengle` instance has not read v13Model before onConnect,
  /// and a name-picked `UnifiedDe1` that turns out to report v13Model >= 128
  /// still speaks protocol v2 on the wire. Reads false until onConnect has
  /// learned the model, which is why the profile gate is fail-closed.
  bool get isBengle =>
      isBengleModelValue(_connectedModelValue ?? 0) ||
      implementation == DeviceImplementation.bengle;

  @override
  Future<void> onConnect() async {
    initRawStream();
    await _transport.connect();

    _currentProfile = null;
    clearEffectiveIdentity();

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
    _refillKitDetected = _unpackMMRInt(
      await _mmrRead(MMRItem.refillKitPresent),
    );
    // Per-frame Power/Lever/HOLD/power-exit capability bitmask. Only firmware
    // that implements the new pump modes defines this register; stock firmware
    // and every DE1 do not. ANY failure — timeout, short buffer, or a stray word
    // with bits outside 0xF — must yield 0, so the read can never hang or fail
    // the connect flow and the arm-time refusal gate then fail-closes on any
    // new-mode step.
    final profileModeCaps = await _readProfileModeCaps();
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
      extra: {
        'refillKit': (_refillKitDetected & 0x01) != 0,
        'voltage': _voltage,
        // Surfaced through /api/v1/machine/info and read by the
        // profile-upload refusal gate.
        'profileModeCaps': profileModeCaps,
      },
    );

    _log.info("Info: ${_info!.toJson()}");

    await _mmrWrite(MMRItem.refillKitPresent, [De1RefillKitSettings.auto.hex]);
    _refillKitSetting = De1RefillKitSettings.auto;

    await enableUserPresenceFeature();
  }

  /// Outer bound on the ProfileModeCaps read. Long enough to let one internal
  /// MMR read attempt resolve, short enough to bail before the retry budget —
  /// so a machine WITHOUT the register (stock firmware, every DE1) settles to
  /// caps 0 in ~one attempt instead of stalling the connect flow for the full
  /// MMR-read retry budget.
  static const _profileModeCapsReadTimeout = Duration(milliseconds: 4500);

  /// Read the ProfileModeCaps bitmask, fail-closed to 0.
  /// Every failure mode collapses to 0 (no new modes offered): a missing
  /// register (timeout/omit on firmware without the capability), a short
  /// buffer, or a stray word with bits outside the defined 0xF mask. The source
  /// read's late retry-timeout is swallowed (`catchError`) so it can never
  /// surface as an unhandled async error after the outer timeout wins.
  ///
  /// The mask is 0xF (bit0 Power / bit1 Lever / bit2 HOLD / bit3 power exit) and
  /// MUST track the highest defined capability bit: a power-exit-capable machine
  /// returns 0xF, and a mask left at 0x7 would treat that legitimate word as
  /// garbage and zero it, hiding Power/Lever/HOLD/power-exit entirely. This is
  /// why the mask MUST widen to 0xF before any firmware advertises bit3. Bits
  /// above 0xF remain undefined and still fail-close to 0.
  Future<int> _readProfileModeCaps() async {
    try {
      final caps = await _mmrRead(MMRItem.profileModeCaps)
          .then(_unpackMMRInt)
          .catchError((Object _) => 0)
          .timeout(_profileModeCapsReadTimeout, onTimeout: () => 0);
      if (caps < 0 || (caps & ~0xF) != 0) return 0;
      return caps;
    } catch (_) {
      return 0;
    }
  }

  Future<void> onDisconnect() async {}

  final StreamController<De1RawMessage> _rawMessageController =
      StreamController.broadcast();

  @override
  Stream<De1RawMessage> get rawOutStream => _rawMessageController.stream;

  @override
  Stream<bool> get ready => _transport.connectionState
      .map((state) => state == ConnectionState.connected)
      .asBroadcastStream();

  static const int _kColdMaintenancePromotionMinFwBuild = 1356;

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
    await _prepareColdMaintenanceWorkaround(newState);
    final Uint8List data = Uint8List(1);
    data[0] = De1StateEnum.fromMachineState(newState).hexValue;
    await _transport.writeWithResponse(Endpoint.requestedState, data);
  }

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
    await Future.delayed(const Duration(seconds: 1));
  }

  final StreamController<De1RawMessage> _rawInputController =
      StreamController();

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

  Future<void> _profileUploadQueue = Future.value();

  @override
  Future<void> setProfile(Profile profile) {
    final upload = _profileUploadQueue.then(
      (_) => _uploadProfileLocked(profile),
    );
    _profileUploadQueue = upload.catchError((_) {});
    return upload;
  }

  /// Refuse to upload a profile that uses a per-frame Power/Lever step, a HOLD
  /// transition, or a cross-variable power exit to a machine that cannot run it
  /// — either the device is not a Bengle (the modes reinterpret the base-frame
  /// U8D1 SetVal as watts / P0, latch a live measurement for HOLD, or compare
  /// hydraulic watts for a power exit — all protocol-v2 semantics) or its
  /// firmware did not advertise the matching capability bit (bit0 Power, bit1
  /// Lever, bit2 HOLD, bit3 power exit). A HOLD-capable machine returns 0x7, a
  /// power-exit-capable machine 0xF; stock firmware and every DE1 return 0 (see
  /// [onConnect]), so this fail-closes. A power exit is an orthogonal per-step
  /// property (any step type can carry one), so it gets its own predicate and
  /// its own bit — pressure/flow cross-exits stay ungated, since they already
  /// run on a stock DE1. Thrown as a [ProfileModeUnsupportedException] (a
  /// PERMANENT refusal for the connection) so the REST boundary surfaces a clean
  /// 400 instead of a silent mis-command (watts read as bar, a P0 as constant
  /// pressure), and so `WorkflowDeviceSync` parks instead of retrying forever.
  void _assertProfileModeSupported(Profile profile) {
    final hasPower = profile.steps.any((s) => s is ProfileStepPower);
    final hasLever = profile.steps.any((s) => s is ProfileStepLever);
    // A HOLD step is any pressure/flow/power step with `transition:hold`. A
    // LEVER step never takes HOLD (the editor forces JUMP on lever, and the
    // encoder writes it as a plain lever), so it is covered by [hasLever].
    final hasHold = profile.steps.any(
      (s) => s.transition == TransitionType.hold && s is! ProfileStepLever,
    );
    // A power exit is orthogonal to the step type: any step may carry one.
    final hasPowerExit = profile.steps.any(
      (s) => s.exit?.type == ExitType.power,
    );
    if (!hasPower && !hasLever && !hasHold && !hasPowerExit) return;

    // HOLD on the FIRST step is invalid on EVERY machine — there is no previous
    // step whose achieved value could be latched. Refuse it up front (before
    // the caps/Bengle checks); the editor also disables HOLD on step 1, and the
    // firmware falls back to the benign base frame as a last resort.
    if (hasHold &&
        profile.steps.isNotEmpty &&
        profile.steps.first.transition == TransitionType.hold &&
        profile.steps.first is! ProfileStepLever) {
      throw ProfileModeUnsupportedException(
        'The first step of profile "${profile.title}" uses a HOLD transition, '
        'but HOLD latches the value achieved at the exit of the PREVIOUS step '
        'and the first step has no previous step. Remove HOLD from the first '
        'step (it can only follow another step).',
      );
    }

    // "Power", "Power and Lever", "Power, Lever and HOLD".
    String andJoin(List<String> xs) => xs.length <= 1
        ? xs.join()
        : '${xs.sublist(0, xs.length - 1).join(', ')} and ${xs.last}';
    // Describe each refused capability with the RIGHT noun: Power and Lever are
    // pump MODES, HOLD is a TRANSITION, a power exit is an EXIT CONDITION (never
    // a "pump mode"). e.g. "Power and Lever pump modes and the HOLD transition
    // and the power exit condition".
    String describe(List<String> pumpModes, bool hold, bool powerExit) {
      final parts = <String>[
        if (pumpModes.isNotEmpty)
          '${andJoin(pumpModes)} pump mode${pumpModes.length > 1 ? 's' : ''}',
        if (hold) 'HOLD transition',
        if (powerExit) 'power exit condition',
      ];
      return parts.join(' and the ');
    }

    // Refuse a non-Bengle BEFORE any BLE write — these modes are protocol-v2 by
    // definition. This also closes a garbage-caps hole: a stock DE1 whose
    // out-of-range MMR read of the register happened to answer with a mask that
    // passes the check below would otherwise reach the encoder's ext-loop guard
    // only AFTER header + base frames were on the wire, stranding a half-written
    // profile. The ext-loop isBengle guard stays as belt-and-suspenders.
    if (!isBengle) {
      final desc = describe(
        [if (hasPower) 'Power', if (hasLever) 'Lever'],
        hasHold,
        hasPowerExit,
      );
      final count =
          (hasPower ? 1 : 0) +
          (hasLever ? 1 : 0) +
          (hasHold ? 1 : 0) +
          (hasPowerExit ? 1 : 0);
      throw ProfileModeUnsupportedException(
        'This machine is not a Bengle; the $desc used by profile '
        '"${profile.title}" require${count == 1 ? 's' : ''} Bengle firmware '
        '(protocol v2).',
      );
    }
    final caps = (machineInfo.extra['profileModeCaps'] as int?) ?? 0;
    final missingModes = <String>[];
    if (hasPower && (caps & 0x1) == 0) missingModes.add('Power');
    if (hasLever && (caps & 0x2) == 0) missingModes.add('Lever');
    final missingHold = hasHold && (caps & 0x4) == 0;
    final missingPowerExit = hasPowerExit && (caps & 0x8) == 0;
    if (missingModes.isEmpty && !missingHold && !missingPowerExit) return;
    throw ProfileModeUnsupportedException(
      'This machine does not support the '
      '${describe(missingModes, missingHold, missingPowerExit)} '
      'used by profile "${profile.title}" — the firmware did not advertise the '
      'capability (ProfileModeCaps bit missing). Update the machine firmware '
      'to run these profiles.',
    );
  }

  Future<void> _uploadProfileLocked(Profile profile) async {
    // Fail-closed before any BLE write.
    _assertProfileModeSupported(profile);
    if (_currentProfile == profile) {
      return;
    }
    _currentProfile = null;
    await _sendProfile(profile);
    _currentProfile = profile;
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
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async {
    final factory = source == De1CalibrationSource.factory;
    final command = factory
        ? De1CalibrationCodec.factoryReadCommand
        : De1CalibrationCodec.readCommand;
    final packet = await _calibrationRequest(
      De1CalibrationCodec.encodeRead(target, factory: factory),
      command: command,
      target: target,
    );
    return De1Calibration(
      target: packet.target,
      de1ReportedValue: packet.de1ReportedValue,
      measuredValue: packet.measuredValue,
    );
  }

  @override
  Future<void> writeCalibration(De1Calibration calibration) async {
    // DE1app unblocks its command queue on the BLE write event, not on an
    // A012 notification; mirror that by completing on the transport write
    // acknowledgement. A012 frames are processed only by read requests.
    await _transport.writeWithResponse(
      Endpoint.calibration,
      De1CalibrationCodec.encodeWrite(calibration),
    );
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

  @protected
  Logger get log => _log;

  @protected
  Future<void> beforeFirmwareUpload() async {}

  @protected
  int get firmwareUploadBatchSize {
    return switch (_transport.transportType) {
      TransportType.serial => 8,
      _ => 8,
    };
  }

  @protected
  Duration get firmwareUploadBatchPause {
    return switch (_transport.transportType) {
      TransportType.serial => const Duration(milliseconds: 400),
      _ => Duration.zero,
    };
  }

  @protected
  Future<void> enableBengleShotSample() =>
      _transport.subscribeBengleShotSample();

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
        case Endpoint.bengleShotSample:
          return _transport.bengleShotSample;
        case Endpoint.calibration:
          return _transport.calibration;
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
    final scaled = (value * addr.writeScale).round();
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
    return _refillKitSetting;
  }

  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {
    await _writeMMRInt(MMRItem.heaterV, voltage.voltage);
    _voltage = voltage.voltage;
  }

  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {
    await _writeMMRInt(MMRItem.refillKitPresent, settings.hex);
    _refillKitSetting = settings;
  }
}
