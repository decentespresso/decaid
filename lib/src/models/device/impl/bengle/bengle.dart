import 'package:flutter/foundation.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class Bengle extends UnifiedDe1
    with IntegratedScaleCapability, LedStripCapability
    implements BengleInterface {
  Bengle({required super.transport});

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  String get name => "Bengle";

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
  int _stopAtTempStubWarningsEmitted = 0;

  @override
  Stream<double> get stopAtTemperatureTarget => _stopAtTempTarget.stream;

  @override
  Stream<bool> get probeAttached => _probeAttached.stream;

  @override
  Stream<double> get probeTemperature => _probeTemperature.stream;

  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {
    final clamped = celsius.clamp(0.0, 80.0).toDouble();
    if (!_stopAtTempTarget.isClosed) {
      _stopAtTempTarget.add(clamped);
    }
    final addr = BengleSteamMmr.stopAtTemperatureTarget;
    if (addr.address == 0x00000000) {
      _logStopAtTempStubOnce(
        'setStopAtTemperatureTarget($clamped) ignored. Awaiting FW.',
      );
      return;
    }
    await writeMmrScaled(addr, clamped);
  }

  @override
  Future<double> getStopAtTemperatureTarget() async {
    final addr = BengleSteamMmr.stopAtTemperatureTarget;
    if (addr.address == 0x00000000) {
      return _stopAtTempTarget.value;
    }
    final value = await readMmrScaled(addr);
    if (!_stopAtTempTarget.isClosed) {
      _stopAtTempTarget.add(value);
    }
    return value;
  }

  void _logStopAtTempStubOnce(String msg) {
    if (_stopAtTempStubWarningsEmitted < 1) {
      log.info('Bengle: stop-at-temperature endpoint unwired; $msg');
      _stopAtTempStubWarningsEmitted++;
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
    await initIntegratedScale();
    await initLedStrip();
  }

  @override
  Future<void> onDisconnect() async {
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
