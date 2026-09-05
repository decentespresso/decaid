import 'dart:async';
import 'dart:convert';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

const _maxPluginDevices = 8;
const _maxPluginDevicePayloadBytes = 64 * 1024;
final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
const _dataTypes = {
  'number',
  'integer',
  'string',
  'boolean',
  'object',
  'array',
};

enum PluginDeviceOperation { connect, disconnect, execute }

typedef PluginDeviceInvoker =
    Future<Map<String, dynamic>> Function(
      PluginDeviceOperation operation,
      Map<String, dynamic> payload,
    );

class PluginDeviceException implements Exception {
  final String message;

  const PluginDeviceException(this.message);

  @override
  String toString() => message;
}

class PluginDeviceRegistration {
  final String deviceId;

  const PluginDeviceRegistration({required this.deviceId});
}

class PluginDeviceService implements DeviceDiscoveryService {
  final BehaviorSubject<List<Device>> _devices = BehaviorSubject.seeded(
    const [],
  );
  final Map<(String, int, String), _PluginSensor> _registrations = {};
  bool _disposed = false;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    if (_disposed) return;
    _publishDevices();
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  Future<PluginDeviceRegistration> register({
    required String pluginId,
    required int generation,
    required String registrationHandle,
    required Map<String, dynamic> definition,
    required PluginDeviceInvoker invoke,
  }) async {
    _ensureActive();
    _checkPayloadSize(definition, 'Plugin device definition');
    if (!_safeId.hasMatch(registrationHandle)) {
      throw const PluginDeviceException('Invalid registration handle');
    }
    final driverId = _requiredSafeString(definition, 'driverId');
    final instanceId = _requiredSafeString(definition, 'instanceId');
    final name = _requiredString(definition, 'name');
    final vendor = _requiredString(definition, 'vendor');
    final key = (pluginId, generation, registrationHandle);
    if (_registrations.containsKey(key)) {
      throw const PluginDeviceException('Registration handle already exists');
    }
    if (_registrations.keys
            .where((key) => key.$1 == pluginId && key.$2 == generation)
            .length >=
        _maxPluginDevices) {
      throw const PluginDeviceException(
        'A plugin generation may register at most 8 devices',
      );
    }

    final deviceId = 'plugin:$pluginId:$driverId:$instanceId';
    if (_registrations.values.any((sensor) => sensor.deviceId == deviceId)) {
      throw PluginDeviceException('Device already registered: $deviceId');
    }
    final sensor = _PluginSensor(
      deviceId: deviceId,
      name: name,
      vendor: vendor,
      dataChannels: _parseDataChannels(definition['dataChannels']),
      commands: _parseCommands(definition['commands']),
      invoke: invoke,
    );
    _registrations[key] = sensor;
    _publishDevices();
    return PluginDeviceRegistration(deviceId: deviceId);
  }

  void publish({
    required String pluginId,
    required int generation,
    required String registrationHandle,
    required Map<String, dynamic> snapshot,
  }) {
    _ensureActive();
    _checkPayloadSize(snapshot, 'Plugin device snapshot');
    _registration(pluginId, generation, registrationHandle).publish(snapshot);
  }

  void reportDisconnected({
    required String pluginId,
    required int generation,
    required String registrationHandle,
  }) {
    _ensureActive();
    _registration(
      pluginId,
      generation,
      registrationHandle,
    ).reportDisconnected();
  }

  Future<void> unregister({
    required String pluginId,
    required int generation,
    required String registrationHandle,
  }) async {
    _ensureActive();
    final key = (pluginId, generation, registrationHandle);
    final sensor = _registrations[key];
    if (sensor == null) {
      throw const PluginDeviceException('Unknown plugin device registration');
    }
    Object? disconnectError;
    try {
      await sensor.disconnect();
    } catch (error) {
      disconnectError = error;
    }
    _registrations.remove(key);
    await sensor.dispose();
    _publishDevices();
    if (disconnectError != null) {
      throw PluginDeviceException('Device disconnect failed: $disconnectError');
    }
  }

  Future<void> removeAllForPlugin(
    String pluginId,
    int generation, {
    bool runDisconnect = true,
  }) async {
    final keys = _registrations.keys
        .where((key) => key.$1 == pluginId && key.$2 == generation)
        .toList();
    if (keys.isEmpty) return;
    Object? firstError;
    StackTrace? firstStackTrace;
    if (runDisconnect) {
      await Future.wait(
        keys.map((key) async {
          final sensor = _registrations[key];
          if (sensor == null) return;
          try {
            await sensor.disconnect();
          } catch (error, stackTrace) {
            firstError ??= error;
            firstStackTrace ??= stackTrace;
          }
        }),
      );
    }
    final removed = keys
        .map((key) => _registrations.remove(key))
        .whereType<_PluginSensor>()
        .toList();
    await Future.wait(removed.map((sensor) => sensor.dispose()));
    if (!_devices.isClosed) _publishDevices();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final sensors = _registrations.values.toList();
    _registrations.clear();
    await Future.wait(sensors.map((sensor) => sensor.dispose()));
    await _devices.close();
  }

  _PluginSensor _registration(
    String pluginId,
    int generation,
    String registrationHandle,
  ) {
    final sensor = _registrations[(pluginId, generation, registrationHandle)];
    if (sensor == null) {
      throw const PluginDeviceException('Unknown plugin device registration');
    }
    return sensor;
  }

  void _publishDevices() {
    _devices.add(List<Device>.of(_registrations.values));
  }

  void _ensureActive() {
    if (_disposed) throw StateError('PluginDeviceService is disposed');
  }
}

class _PluginSensor implements Sensor {
  _PluginSensor({
    required this.deviceId,
    required this.name,
    required String vendor,
    required List<DataChannel> dataChannels,
    required List<CommandDescriptor> commands,
    required PluginDeviceInvoker invoke,
  }) : _invoke = invoke,
       info = SensorInfo(
         name: name,
         vendor: vendor,
         dataChannels: dataChannels,
         commands: commands,
       ),
       _dataChannels = {
         for (final channel in dataChannels) channel.key: channel,
       };

  final PluginDeviceInvoker _invoke;
  final Map<String, DataChannel> _dataChannels;
  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.discovered);
  final StreamController<Map<String, dynamic>> _data =
      StreamController.broadcast();
  Future<void>? _connecting;
  Future<void>? _disconnectCleanup;
  int? _disconnectCleanupEpoch;
  int _connectionEpoch = 0;
  int _connectionFence = 0;
  bool _disposed = false;

  @override
  final String deviceId;

  @override
  final String name;

  @override
  final SensorInfo info;

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.plugin;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<Map<String, dynamic>> get data => _data.stream;

  @override
  Future<void> onConnect() {
    if (_disposed || _connectionState.value == ConnectionState.connected) {
      return Future.value();
    }
    return _connecting ??= _connectAfterCleanup().whenComplete(
      () => _connecting = null,
    );
  }

  Future<void> _connectAfterCleanup() async {
    final cleanup = _disconnectCleanup;
    final cleanupFence = _connectionFence;
    if (cleanup != null) {
      try {
        await cleanup;
      } catch (_) {}
      if (cleanupFence != _connectionFence) return;
      if (identical(_disconnectCleanup, cleanup)) {
        _disconnectCleanup = null;
        _disconnectCleanupEpoch = null;
      }
    }
    await _connect();
  }

  Future<void> _connect() async {
    ++_connectionEpoch;
    final fence = ++_connectionFence;
    _connectionState.add(ConnectionState.connecting);
    try {
      await _invoke(PluginDeviceOperation.connect, const {});
      if (!_disposed && fence == _connectionFence) {
        _connectionState.add(ConnectionState.connected);
      }
    } catch (_) {
      if (!_disposed && fence == _connectionFence) {
        _connectionState.add(ConnectionState.disconnected);
      }
      if (_disposed || fence != _connectionFence) return;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() {
    if (_disposed) return Future.value();
    final epoch = _connectionEpoch;
    final existing = _disconnectCleanup;
    if (existing != null && _disconnectCleanupEpoch == epoch) {
      if (_connecting != null) _connectionFence += 1;
      return existing;
    }
    final cleanup = _runDisconnectCleanup(epoch);
    _disconnectCleanup = cleanup;
    _disconnectCleanupEpoch = epoch;
    return cleanup;
  }

  Future<void> _runDisconnectCleanup(int epoch) async {
    final connecting = _connecting;
    _connectionFence += 1;
    if (_connectionState.value != ConnectionState.disconnected) {
      _connectionState.add(ConnectionState.disconnecting);
    }
    if (connecting != null) {
      try {
        await connecting;
      } catch (_) {}
    }
    try {
      await _invoke(PluginDeviceOperation.disconnect, const {});
    } finally {
      if (!_disposed && epoch == _connectionEpoch) {
        _connectionState.add(ConnectionState.disconnected);
      }
    }
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    if (_disposed || _connectionState.value != ConnectionState.connected) {
      throw const PluginDeviceException('Plugin device is not connected');
    }
    if (info.commands?.any((command) => command.id == commandId) != true) {
      throw PluginDeviceException('Unknown sensor command: $commandId');
    }
    _checkPayloadSize(
      parameters ?? const {},
      'Plugin device command parameters',
    );
    final result = await _invoke(PluginDeviceOperation.execute, {
      'commandId': commandId,
      'params': parameters,
    });
    _checkPayloadSize(result, 'Plugin device command result');
    return result;
  }

  void publish(Map<String, dynamic> snapshot) {
    if (_disposed) throw const PluginDeviceException('Plugin device is closed');
    if (snapshot.length != _dataChannels.length ||
        !_dataChannels.keys.every(snapshot.containsKey)) {
      throw const PluginDeviceException(
        'Plugin device snapshot must contain every declared data channel',
      );
    }
    for (final entry in snapshot.entries) {
      final channel = _dataChannels[entry.key];
      if (channel == null || !_matchesType(entry.value, channel.type)) {
        throw PluginDeviceException(
          'Invalid value for plugin device channel ${entry.key}',
        );
      }
    }
    _data.add(Map.unmodifiable(snapshot));
  }

  void reportDisconnected() {
    if (_disposed) return;
    _connectionFence += 1;
    _connectionState.add(ConnectionState.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _connectionFence += 1;
    await _data.close();
    await _connectionState.close();
  }
}

String _requiredSafeString(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  if (!_safeId.hasMatch(value)) {
    throw PluginDeviceException('Invalid plugin device $key');
  }
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 128) {
    throw PluginDeviceException('Invalid plugin device $key');
  }
  return value;
}

List<DataChannel> _parseDataChannels(dynamic json) {
  if (json is! List || json.isEmpty || json.length > 64) {
    throw const PluginDeviceException('Invalid plugin device dataChannels');
  }
  final channels = <DataChannel>[];
  final ids = <String>{};
  for (final value in json) {
    if (value is! Map) {
      throw const PluginDeviceException('Invalid plugin device data channel');
    }
    final map = Map<String, dynamic>.from(value);
    final key = _requiredSafeString(map, 'key');
    final type = map['type'];
    final unit = map['unit'];
    if (type is! String ||
        !_dataTypes.contains(type) ||
        (unit != null && unit is! String) ||
        !ids.add(key)) {
      throw const PluginDeviceException('Invalid plugin device data channel');
    }
    channels.add(DataChannel(key: key, type: type, unit: unit as String?));
  }
  return List.unmodifiable(channels);
}

List<CommandDescriptor> _parseCommands(dynamic json) {
  if (json == null) return const [];
  if (json is! List || json.length > 64) {
    throw const PluginDeviceException('Invalid plugin device commands');
  }
  final commands = <CommandDescriptor>[];
  final ids = <String>{};
  for (final value in json) {
    if (value is! Map) {
      throw const PluginDeviceException('Invalid plugin device command');
    }
    final map = Map<String, dynamic>.from(value);
    final id = _requiredSafeString(map, 'id');
    final name = map['name'];
    final description = map['description'];
    final paramsSchema = map['paramsSchema'];
    final resultsSchema = map['resultsSchema'];
    if (!ids.add(id) ||
        (name != null && name is! String) ||
        (description != null && description is! String) ||
        (paramsSchema != null && paramsSchema is! Map) ||
        (resultsSchema != null && resultsSchema is! Map)) {
      throw const PluginDeviceException('Invalid plugin device command');
    }
    commands.add(
      CommandDescriptor(
        id: id,
        name: name as String?,
        description: description as String?,
        paramsSchema: paramsSchema == null
            ? null
            : Map<String, dynamic>.from(paramsSchema as Map),
        resultsSchema: resultsSchema == null
            ? null
            : Map<String, dynamic>.from(resultsSchema as Map),
      ),
    );
  }
  return List.unmodifiable(commands);
}

bool _matchesType(Object? value, String type) => switch (type) {
  'number' => value is num,
  'integer' => value is int,
  'string' => value is String,
  'boolean' => value is bool,
  'object' => value is Map,
  'array' => value is List,
  _ => false,
};

void _checkPayloadSize(Object payload, String name) {
  try {
    if (utf8.encode(jsonEncode(payload)).length >
        _maxPluginDevicePayloadBytes) {
      throw PluginDeviceException('$name exceeds 64 KiB');
    }
  } on JsonUnsupportedObjectError {
    throw PluginDeviceException('$name must be JSON encodable');
  }
}
