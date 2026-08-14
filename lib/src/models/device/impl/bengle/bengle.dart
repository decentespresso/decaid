import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class Bengle extends UnifiedDe1
    with
        IntegratedScaleCapability,
        LedStripCapability,
        BengleFirmwareProbe,
        ScaleCalibrationCapability,
        CupWarmerCapability,
        WakeScheduleCapability
    implements BengleInterface {
  Bengle({required super.transport});

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  String get name => "Bengle";

  @override
  MachineInfo get machineInfo {
    final info = super.machineInfo;
    return MachineInfo(
      version: info.version,
      model: info.model,
      serialNumber: info.serialNumber,
      groupHeadControllerPresent: info.groupHeadControllerPresent,
      extra: {
        ...info.extra,
        'bengleFirmwareSurface': supportsCurrentBengleFirmwareSurface
            ? 'current'
            : 'outdated',
      },
    );
  }

  @override
  Future<void> setCupWarmerTemperature(double celsius) =>
      writeMmrScaled(BengleMmr.matSetPoint, celsius);

  @override
  Future<double> getCupWarmerTemperature() =>
      readMmrScaled(BengleMmr.matSetPoint);

  @override
  @protected
  Future<void> beforeFirmwareUpload() async {
    await Future.delayed(Duration(milliseconds: 500), () async {
      await requestState(MachineState.fwUpgrade);
    });
  }

  @override
  @protected
  Duration get firmwareUploadBatchPause => Duration.zero;

  final BehaviorSubject<double> _stopAtTempTarget =
      BehaviorSubject<double>.seeded(0.0);
  final BehaviorSubject<bool> _probeAttached = BehaviorSubject<bool>.seeded(
    false,
  );
  final PublishSubject<double> _probeTemperature = PublishSubject<double>();
  StreamSubscription<ByteData>? _probeSub;

  @override
  Stream<double> get stopAtTemperatureTarget => _stopAtTempTarget.stream;

  @override
  Stream<bool> get probeAttached => _probeAttached.stream;

  @override
  Stream<double> get probeTemperature => _probeTemperature.stream;

  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {
    final clamped = celsius.clamp(0.0, 85.0).toDouble();
    if (!_stopAtTempTarget.isClosed) {
      _stopAtTempTarget.add(clamped);
    }
    await writeMmrScaled(BengleSteamMmr.targetMilkTemp, clamped);
  }

  @override
  Future<double> getStopAtTemperatureTarget() async {
    final value = await readMmrScaled(BengleSteamMmr.targetMilkTemp);
    if (!_stopAtTempTarget.isClosed) {
      _stopAtTempTarget.add(value);
    }
    return value;
  }

  void _handleProbeSample(ByteData frame) {
    final sample = decodeBengleShotSample(frame);
    if (sample == null) return;
    final attached = sample.milkTemperature != 0;
    if (!_probeAttached.isClosed && attached != _probeAttached.value) {
      _probeAttached.add(attached);
    }
    if (attached && !_probeTemperature.isClosed) {
      _probeTemperature.add(sample.milkTemperature);
    }
  }

  @override
  Future<void> onConnect() async {
    await super.onConnect();
    if (!isBengleModelValue(connectedModelValue)) {
      await dispose();
      throw DeviceIdentityMismatchException(
        expected: 'Bengle',
        actualModelValue: connectedModelValue,
      );
    }
    await probeBengleFirmwareSurface();
    await enableBengleShotSample();
    _probeSub = notificationsFor(
      Endpoint.bengleShotSample,
    ).listen(_handleProbeSample);
    await initIntegratedScale();
    await initLedStrip();
  }

  @override
  Future<void> onDisconnect() async {
    await _probeSub?.cancel();
    _probeSub = null;
    await disposeLedStrip();
    await disposeIntegratedScale();
    if (!_stopAtTempTarget.isClosed) {
      await _stopAtTempTarget.close();
    }
    if (!_probeAttached.isClosed) {
      await _probeAttached.close();
    }
    if (!_probeTemperature.isClosed) {
      await _probeTemperature.close();
    }
    await super.onDisconnect();
  }
}
