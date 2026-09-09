import 'dart:async';

import 'package:clock/clock.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';

import 'plugin_device_contract.dart';
import 'plugin_manifest.dart';
import 'plugin_protocol_device.dart';

class PluginScale extends PluginProtocolDevice
    implements Scale, ScaleSnapshotHandoff, DisconnectToSleepScale {
  final Set<PluginScaleCapability> capabilities;
  final StreamController<ScaleSnapshot> _snapshots =
      StreamController.broadcast();
  final List<ScaleSnapshot> _handoff = [];
  Completer<void> _firstWeight = Completer<void>();
  bool _active = false;
  DateTime? _lastTimestamp;

  PluginScale({
    required super.deviceId,
    required super.name,
    required super.invoke,
    required Set<PluginScaleCapability> capabilities,
    super.transportType,
    super.onReady,
    super.invocationTimeout,
  }) : capabilities = Set.unmodifiable(capabilities);

  @override
  DeviceType get type => DeviceType.scale;
  @override
  bool get disconnectsToSleep =>
      capabilities.contains(PluginScaleCapability.disconnectToSleep);
  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;
  @override
  void beginSamples() {
    _firstWeight = Completer<void>();
    _handoff.clear();
    _active = false;
    _lastTimestamp = null;
  }

  @override
  Future<void> waitForReadiness() => _firstWeight.future;
  @override
  void activateSnapshots() {
    if (_active) return;
    _active = true;
    for (final snapshot in _handoff) {
      _snapshots.add(snapshot);
    }
    _handoff.clear();
  }

  @override
  void publish(
    Map<String, dynamic> snapshot, {
    String? session,
    DateTime? timestamp,
  }) {
    checkSession(session);
    final weight = snapshot['weight'];
    final battery = snapshot['battery'];
    final flow = snapshot['flow'];
    final timer = snapshot['timerMs'];
    if (snapshot.keys.any(
          (key) =>
              !const {'weight', 'battery', 'flow', 'timerMs'}.contains(key),
        ) ||
        weight is! num ||
        !weight.isFinite ||
        (battery != null &&
            (battery is! int ||
                battery < 0 ||
                battery > 100 ||
                !capabilities.contains(PluginScaleCapability.battery))) ||
        (flow != null &&
            (flow is! num ||
                !flow.isFinite ||
                !capabilities.contains(PluginScaleCapability.flow))) ||
        (timer != null &&
            (timer is! int ||
                timer < 0 ||
                timer > 9007199254740991 ||
                !capabilities.contains(
                  PluginScaleCapability.timerTelemetry,
                )))) {
      throw const PluginDeviceException(
        'Invalid Scale publication',
        code: 'invalid_argument',
      );
    }
    if (!_active && _handoff.length >= 256) {
      reportDisconnected(session: session);
      throw const PluginDeviceException(
        'Scale handoff buffer full',
        code: 'resource_limit',
      );
    }
    final acceptedAt = timestamp ?? clock.now();
    if (_lastTimestamp != null && acceptedAt.isBefore(_lastTimestamp!)) {
      throw const PluginDeviceException(
        'Scale sample precedes the last publication',
        code: 'stale_sample',
      );
    }
    _lastTimestamp = acceptedAt;
    final sample = ScaleSnapshot(
      timestamp: acceptedAt,
      weight: weight.toDouble(),
      batteryLevel: battery as int?,
      flow: (flow as num?)?.toDouble(),
      timerValue: timer == null ? null : Duration(milliseconds: timer as int),
    );
    if (_active) {
      _snapshots.add(sample);
    } else {
      _handoff.add(sample);
    }
    if (!_firstWeight.isCompleted) _firstWeight.complete();
  }

  Future<void> _optional(
    PluginScaleCapability capability,
    PluginDeviceOperation operation,
  ) async {
    if (!capabilities.contains(capability)) {
      throw ScaleOperationException(
        '${operation.name} is unsupported',
        code: 'unsupported_operation',
      );
    }
    try {
      await command(operation);
    } on PluginDeviceException catch (error) {
      throw ScaleOperationException(error.message, code: error.code);
    }
  }

  @override
  Future<void> tare() =>
      _optional(PluginScaleCapability.tare, PluginDeviceOperation.tare);
  @override
  Future<void> startTimer() => _optional(
    PluginScaleCapability.timerControl,
    PluginDeviceOperation.startTimer,
  );
  @override
  Future<void> stopTimer() => _optional(
    PluginScaleCapability.timerControl,
    PluginDeviceOperation.stopTimer,
  );
  @override
  Future<void> resetTimer() => _optional(
    PluginScaleCapability.timerControl,
    PluginDeviceOperation.resetTimer,
  );
  @override
  Future<void> sleepDisplay() => disconnectsToSleep
      ? disconnect()
      : _optional(
          PluginScaleCapability.displayControl,
          PluginDeviceOperation.sleepDisplay,
        );
  @override
  Future<void> wakeDisplay() => _optional(
    PluginScaleCapability.displayControl,
    PluginDeviceOperation.wakeDisplay,
  );
  @override
  Future<void> dispose() async {
    _handoff.clear();
    await super.dispose();
    await _snapshots.close();
  }
}
