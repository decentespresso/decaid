import 'dart:async';

import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

/// The Bengle firmware's fused puck-hydraulic observer, surfaced as a [Sensor].
///
/// Observer output is not machine telemetry: it is a derived estimate the
/// machine itself never reads back, so it lives in `/sensors` alongside
/// [BengleMilkProbe] rather than on `MachineSnapshot`.
///
/// Every channel except `timestamp`, `rev`, `flags`, `confidence`, `lagConf`
/// and `sigmaQ` is omitted when the firmware reports its wire sentinel: an
/// absent key means "not observed", which a zero would misrepresent as a real
/// measurement of zero.
class BenglePuckEstimator implements Sensor {
  BenglePuckEstimator({required BengleInterface bengle, String? deviceId})
    : _bengle = bengle,
      _deviceId = deviceId ?? '${_machineDeviceId(bengle)}-puckestimator';

  static String _machineDeviceId(BengleInterface bengle) =>
      (bengle as Device).deviceId;

  final BengleInterface _bengle;
  final String _deviceId;

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);
  final BehaviorSubject<Map<String, dynamic>> _data = BehaviorSubject();
  StreamSubscription<BengleEstSample>? _sampleSub;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  TransportType get transportType => _bengle.transportType;

  @override
  String get name => 'Bengle Puck Estimator';

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<Map<String, dynamic>> get data => _data.stream;

  @override
  SensorInfo get info => SensorInfo(
    name: name,
    vendor: 'DecentEspresso',
    dataChannels: [
      DataChannel(key: 'timestamp', type: 'string'),
      DataChannel(key: 'rev', type: 'number'),
      DataChannel(key: 'flags', type: 'number'),
      // r1 / r2 keep the firmware's own names (T_BengleEstSample.R1 / .R2).
      // Their derived counterparts on MachineSnapshot are loadImpedanceDerived
      // and puckResistanceDerived respectively — same quantity, same units,
      // computed from Q_in instead of Q_puck.
      DataChannel(key: 'r1', type: 'number', unit: 'bar·s/mL'),
      DataChannel(key: 'r2', type: 'number', unit: 'bar·s²/mL²'),
      DataChannel(key: 'compliance', type: 'number', unit: 'mL/bar'),
      DataChannel(key: 'confidence', type: 'number'),
      DataChannel(key: 'lag', type: 'number', unit: 's'),
      DataChannel(key: 'lagConfidence', type: 'number'),
      DataChannel(key: 'sigmaQ', type: 'number', unit: 'mL/s'),
      DataChannel(key: 'absorbedVolume', type: 'number', unit: 'mL'),
      DataChannel(key: 'lastPauseTau', type: 'number', unit: 's'),
      DataChannel(key: 'collapseEventCount', type: 'number'),
      DataChannel(key: 'collapseLastEventT', type: 'number', unit: 's'),
      DataChannel(key: 'collapseLastEventMagnitude', type: 'number'),
      DataChannel(key: 'collapseLastEventConcavity', type: 'number'),
      DataChannel(key: 'hydraulicPowerMeasured', type: 'number', unit: 'W'),
    ],
    commands: const [],
  );

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    return const {};
  }

  static Map<String, dynamic> encodeSample(BengleEstSample s) => {
    'timestamp': DateTime.now().toIso8601String(),
    'rev': s.rev,
    'flags': s.flags,
    if (s.r1 != null) 'r1': s.r1,
    if (s.r2 != null) 'r2': s.r2,
    if (s.c != null) 'compliance': s.c,
    'confidence': s.confR,
    if (s.lag != null) 'lag': s.lag,
    'lagConfidence': s.lagConf,
    'sigmaQ': s.sigmaQ,
    if (s.vAbs != null) 'absorbedVolume': s.vAbs,
    if (s.lastPauseTau != null) 'lastPauseTau': s.lastPauseTau,
    if (s.detEventCount != null) 'collapseEventCount': s.detEventCount,
    if (s.detLastEventT != null) 'collapseLastEventT': s.detLastEventT,
    if (s.detLastEventMag != null)
      'collapseLastEventMagnitude': s.detLastEventMag,
    if (s.detLastEventConc != null)
      'collapseLastEventConcavity': s.detLastEventConc,
    // Measured hydraulic power into the puck (rev 3+). The counterpart of
    // MachineSnapshot.hydraulicPowerDerived: same quantity and units, but
    // computed from Q_puck rather than reported group flow, so the two diverge
    // during compliance transients. Absent on pre-rev-3 firmware.
    if (s.wPuck != null) 'hydraulicPowerMeasured': s.wPuck,
  };

  @override
  Future<void> onConnect() async {
    if (_sampleSub != null) return;
    _sampleSub = _bengle.puckEstimator.listen((sample) {
      if (_data.isClosed) return;
      _data.add(encodeSample(sample));
    });
    if (!_connectionState.isClosed) {
      _connectionState.add(ConnectionState.connected);
    }
  }

  @override
  Future<void> disconnect() async {
    await _sampleSub?.cancel();
    _sampleSub = null;
    if (!_connectionState.isClosed) {
      _connectionState.add(ConnectionState.disconnected);
      await _connectionState.close();
    }
    if (!_data.isClosed) {
      await _data.close();
    }
  }
}
