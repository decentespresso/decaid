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
  final Map<String, GrinderControlDescriptor> _fixedControls;
  final List<PluginDeviceSurface> _declaredSurfaces;
  final String? pluginId;
  final Map<String, GrinderControlDescriptor> _overrides = {};
  List<String>? _availableSurfaces;

  @override
  Map<String, GrinderControlDescriptor> get controls =>
      Map.unmodifiable({..._fixedControls, ..._overrides});

  @override
  bool get hasSurfaceDeclarations => _declaredSurfaces.isNotEmpty;

  @override
  List<Map<String, String>> get surfaces => List.unmodifiable(
    _declaredSurfaces
        .where(
          (surface) =>
              _availableSurfaces == null ||
              _availableSurfaces!.contains(surface.id),
        )
        .map(
          (surface) => {
            'id': surface.id,
            'role': surface.role,
            if (surface.label != null) 'label': surface.label!,
            'href': Uri(
              pathSegments: [
                '',
                'api',
                'v1',
                'plugins',
                pluginId!,
                surface.endpoint,
              ],
              queryParameters: {'ui': '1', 'deviceId': deviceId},
            ).toString(),
          },
        ),
  );

  PluginGrinder({
    this.pluginId,
    Map<String, GrinderControlDescriptor> controls = const {},
    List<PluginDeviceSurface> surfaces = const [],
    required super.deviceId,
    required super.name,
    required super.invoke,
    required Set<PluginGrinderCapability> capabilities,
    super.transportType,
    super.prepareConnection,
    super.onReady,
    super.invocationTimeout,
  }) : _fixedControls = Map.unmodifiable(controls),
       _declaredSurfaces = List.unmodifiable(surfaces),
       capabilities = Set.unmodifiable(
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
    _overrides.clear();
    _availableSurfaces = null;
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
    final hasState = snapshot.containsKey('state');
    final validState =
        !hasState ||
        (state is String &&
            GrinderState.values.any((value) => value.name == state));
    if (snapshot.isEmpty ||
        snapshot.keys.any(
          (key) => !const {
            'state',
            'setting',
            'rpm',
            'controls',
            'surfaces',
          }.contains(key),
        ) ||
        !validState ||
        (!hasState && (hasSetting || hasRpm)) ||
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
    final overrides = Map<String, GrinderControlDescriptor>.of(_overrides);
    List<String>? available = _availableSurfaces;
    try {
      if (snapshot.containsKey('controls')) {
        final updates = snapshot['controls'];
        if (updates == null) {
          overrides.clear();
        } else if (updates is Map &&
            updates.keys.every(
              (key) =>
                  key is String &&
                  const {'grindSetting', 'rpmControl'}.contains(key) &&
                  capabilities.any((capability) => capability.name == key),
            )) {
          for (final entry in updates.entries) {
            if (entry.value == null) {
              overrides.remove(entry.key);
            } else {
              overrides[entry.key
                  as String] = GrinderControlDescriptor.fromJson(
                entry.key as String,
                entry.value,
              );
            }
          }
        } else {
          throw const FormatException('Invalid controls');
        }
      }
      if (snapshot.containsKey('surfaces')) {
        final update = snapshot['surfaces'];
        if (update == null) {
          available = null;
        } else if (update is List &&
            update.every(
              (id) =>
                  id is String &&
                  _declaredSurfaces.any((surface) => surface.id == id),
            ) &&
            update.toSet().length == update.length) {
          available = List<String>.unmodifiable(update.cast<String>());
        } else {
          throw const FormatException('Invalid surfaces');
        }
      }
    } on FormatException {
      throw const PluginDeviceException(
        'Invalid Grinder publication',
        code: 'invalid_argument',
      );
    }
    _overrides
      ..clear()
      ..addAll(overrides);
    _availableSurfaces = available;
    if (!hasState) return;
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
  Future<void> disconnect() {
    _overrides.clear();
    _availableSurfaces = null;
    return super.disconnect();
  }

  @override
  Future<void> dispose() async {
    _overrides.clear();
    _availableSurfaces = null;
    await super.dispose();
    await _snapshots.close();
  }
}
