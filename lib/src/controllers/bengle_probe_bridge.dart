import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_milk_probe.dart';

class BengleProbeBridge {
  BengleProbeBridge({
    required De1Controller de1Controller,
    required SensorController sensorController,
  }) : _de1 = de1Controller,
       _sensors = sensorController {
    _de1Sub = _de1.de1.listen(_onMachineChange);
  }

  final De1Controller _de1;
  final SensorController _sensors;
  final Logger _log = Logger('BengleProbeBridge');

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<bool>? _attachedSub;
  BengleMilkProbe? _registeredProbe;
  BengleInterface? _attachedBengle;

  Future<void> _onMachineChange(De1Interface? device) async {
    if (device is BengleInterface) {
      if (identical(_attachedBengle, device)) return;
      await _detachCurrent();
      _attachedBengle = device;
      _attachedSub = device.probeAttached.listen(_onAttachedChange);
    } else {
      await _detachCurrent();
    }
  }

  Future<void> _onAttachedChange(bool attached) async {
    final bengle = _attachedBengle;
    if (bengle == null) return;
    if (attached && _registeredProbe == null) {
      final probe = BengleMilkProbe(bengle: bengle);
      _registeredProbe = probe;
      _log.info('Bengle milk probe attached — registering sensor');
      await _sensors.register(probe);
    } else if (!attached && _registeredProbe != null) {
      final probe = _registeredProbe!;
      _registeredProbe = null;
      _log.info('Bengle milk probe detached — unregistering sensor');
      await _sensors.unregister(probe.deviceId);
    }
  }

  Future<void> _detachCurrent() async {
    await _attachedSub?.cancel();
    _attachedSub = null;
    final probe = _registeredProbe;
    if (probe != null) {
      _registeredProbe = null;
      await _sensors.unregister(probe.deviceId);
    }
    _attachedBengle = null;
  }

  Future<void> dispose() async {
    await _de1Sub?.cancel();
    _de1Sub = null;
    await _detachCurrent();
  }
}
