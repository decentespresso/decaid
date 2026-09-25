import 'dart:async';

import 'package:clock/clock.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';

import 'plugin_device_contract.dart';
import 'plugin_manifest.dart';
import 'plugin_protocol_device.dart';

class PluginGrinder extends PluginProtocolDevice implements GrinderDevice {
  @override
  final Set<GrinderCapability> capabilities;
  final StreamController<GrinderSnapshot> _snapshots =
      StreamController.broadcast();
  Completer<void> _firstState = Completer<void>();
  GrinderSnapshot? _latestSnapshot;

  PluginGrinder({
    required super.deviceId,
    required super.name,
    required super.invoke,
    required Set<PluginGrinderCapability> capabilities,
    super.transportType,
    super.prepareConnection,
    super.onReady,
    super.invocationTimeout,
  }) : capabilities = Set.unmodifiable(
         capabilities.map(
           (capability) => GrinderCapability.values.byName(capability.name),
         ),
       );

  @override
  DeviceType get type => DeviceType.grinder;

  @override
  Stream<GrinderSnapshot> get currentSnapshot => Stream.multi((controller) {
    final subscription = _snapshots.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    final snapshot = _latestSnapshot;
    if (snapshot != null) controller.add(snapshot);
    controller.onCancel = subscription.cancel;
  });

  @override
  void beginSamples() {
    _latestSnapshot = null;
    _firstState = Completer<void>();
  }

  @override
  Future<void> waitForReadiness() => _firstState.future;

  @override
  void publish(Map<String, dynamic> snapshot, {String? session}) {
    checkSession(session);
    final state = snapshot['state'];
    final setting = snapshot['setting'];
    final rpm = snapshot['rpm'];
    final hasSetting = snapshot.containsKey('setting');
    final hasRpm = snapshot.containsKey('rpm');
    final validState =
        state is String &&
        GrinderState.values.any((value) => value.name == state);
    if (snapshot.keys.any(
          (key) => !const {'state', 'setting', 'rpm'}.contains(key),
        ) ||
        !validState ||
        (hasSetting &&
            (setting is! String ||
                !capabilities.contains(GrinderCapability.grindSetting))) ||
        (hasRpm &&
            (rpm is! int ||
                rpm < 0 ||
                !capabilities.contains(GrinderCapability.rpmControl)))) {
      throw const PluginDeviceException(
        'Invalid Grinder publication',
        code: 'invalid_argument',
      );
    }
    final publication = GrinderSnapshot(
      timestamp: clock.now().toUtc(),
      state: GrinderState.values.byName(state),
      setting: setting as String?,
      rpm: rpm as int?,
    );
    _latestSnapshot = publication;
    _snapshots.add(publication);
    if (!_firstState.isCompleted) _firstState.complete();
  }

  Future<void> _optional(
    GrinderCapability capability,
    PluginDeviceOperation operation, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (!capabilities.contains(capability)) {
      throw GrinderOperationException(
        '${operation.name} is unsupported',
        code: 'unsupported_operation',
      );
    }
    try {
      await command(operation, payload);
    } on PluginDeviceException catch (error) {
      throw GrinderOperationException(error.message, code: error.code);
    }
  }

  @override
  Future<void> start() =>
      _optional(GrinderCapability.startStop, PluginDeviceOperation.start);

  @override
  Future<void> stop() =>
      _optional(GrinderCapability.startStop, PluginDeviceOperation.stop);

  @override
  Future<void> setGrindSetting(String setting) => _optional(
    GrinderCapability.grindSetting,
    PluginDeviceOperation.setGrindSetting,
    {'setting': setting},
  );

  @override
  Future<void> setRpm(int rpm) async {
    if (rpm < 0) {
      throw const GrinderOperationException(
        'rpm must be >= 0',
        code: 'invalid_argument',
      );
    }
    await _optional(
      GrinderCapability.rpmControl,
      PluginDeviceOperation.setRpm,
      {'rpm': rpm},
    );
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _snapshots.close();
  }
}
