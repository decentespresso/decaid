import 'dart:async';
import 'dart:convert';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/services/ble/ble_lifecycle_gate.dart';
import 'package:uuid/uuid.dart';

import 'plugin_ble_binding.dart';
import 'plugin_ble_registry.dart';
import 'plugin_ble_session.dart';
import 'plugin_device_contract.dart';
import 'plugin_manifest.dart';

typedef PluginBleInvoker =
    Future<Map<String, dynamic>> Function(
      PluginBleDriver driver,
      String handle,
      PluginDeviceOperation operation,
      Map<String, dynamic> payload,
    );

class PluginBleService {
  final PluginBleRegistry registry;
  final PluginBleInvoker invoke;
  final bool Function(PluginBleDriver) runtimeAlive;
  final bool Function(PluginBleDriver, String, String) hasHandler;
  final Future<void> Function(PluginBleDriver, String, Map<String, dynamic>)
  eventSink;
  final void Function(String) removeHandlers;
  final Duration invocationTimeout;
  final Map<String, PluginBleBinding> _bindings = {};
  bool _disposed = false;

  PluginBleService({
    required this.registry,
    required this.invoke,
    required this.runtimeAlive,
    required this.hasHandler,
    required this.eventSink,
    required this.removeHandlers,
    required this.invocationTimeout,
  });

  int get bindingCount => _bindings.length;

  void revokeSessions() {
    for (final binding in _bindings.values) {
      binding.revoke();
    }
  }

  bool matchesCandidate(Device device, PluginBleDriver driver) =>
      _bindings.values.any(
        (binding) =>
            identical(binding.device, device) &&
            identical(binding.driver, driver),
      );

  Future<Device> createCandidate({
    required PluginBleDriver driver,
    required String physicalId,
    required BleAdvertisementEvidence evidence,
    required BLETransport Function() createTransport,
    required bool Function() admit,
  }) async {
    if (_disposed || !registry.isCurrent(driver)) {
      throw const PluginBleException('stale_session', 'BLE driver retired');
    }
    final id = normalizeBleDeviceId(physicalId);
    for (final binding in _bindings.values) {
      if (identical(binding.driver, driver) && binding.physicalId == id) {
        return binding.device;
      }
    }
    final handle = 'ble_${const Uuid().v4()}';
    try {
      final definition = await invoke(
        driver,
        driver.factoryHandle,
        PluginDeviceOperation.create,
        {
          'registrationHandle': handle,
          'device': {
            'id': 'plugin:${driver.pluginId}:${driver.declaration.id}:$id',
            'name': evidence.name ?? driver.declaration.id,
            'advertisement': {
              'name': evidence.name,
              'nameComplete': evidence.nameComplete,
              'serviceUuids': evidence.serviceUuids,
              'servicesComplete': evidence.servicesComplete,
            },
          },
        },
      );
      if (_disposed || !registry.isCurrent(driver) || !admit()) {
        throw const PluginBleException(
          'stale_session',
          'BLE candidate retired',
        );
      }
      if (utf8.encode(jsonEncode(definition)).length > 64 * 1024) {
        throw const PluginBleException(
          'resource_limit',
          'BLE definition exceeds 64 KiB',
        );
      }
      final required = {
        'connect',
        'disconnect',
        'bleEvent',
        if (driver.declaration.type == PluginDriverType.sensor) 'execute',
        if (driver.declaration.capabilities.contains(
          PluginScaleCapability.tare,
        ))
          'tare',
        if (driver.declaration.capabilities.contains(
          PluginScaleCapability.timerControl,
        )) ...[
          'startTimer',
          'stopTimer',
          'resetTimer',
        ],
        if (driver.declaration.capabilities.contains(
          PluginScaleCapability.displayControl,
        )) ...[
          'sleepDisplay',
          'wakeDisplay',
        ],
      };
      for (final operation in PluginDeviceOperation.values) {
        final name = operation.name;
        if (hasHandler(driver, handle, name) != required.contains(name)) {
          throw PluginBleException(
            'invalid_argument',
            'BLE $name handler does not match declared capabilities',
          );
        }
      }
      if (driver.declaration.type == PluginDriverType.sensor) {
        final vendor = definition['vendor'];
        if (vendor is! String || vendor.isEmpty || vendor.length > 128) {
          throw const PluginBleException(
            'invalid_argument',
            'Invalid Sensor vendor',
          );
        }
      }
      final binding = PluginBleBinding(
        registry: registry,
        driver: driver,
        physicalId: id,
        handle: handle,
        createTransport: createTransport,
        admit: admit,
        runtimeAlive: () => runtimeAlive(driver),
        invokeHandler: (operation, payload) =>
            invoke(driver, handle, operation, payload),
        eventSink: (event) => eventSink(driver, handle, event),
        invocationTimeout: invocationTimeout,
        name: evidence.name ?? driver.declaration.id,
        definition: definition,
      );
      _bindings[handle] = binding;
      return binding.device;
    } catch (_) {
      removeHandlers(handle);
      rethrow;
    }
  }

  PluginBleBinding _binding(String pluginId, int generation, String handle) {
    final binding = _bindings[handle];
    if (binding == null ||
        binding.driver.pluginId != pluginId ||
        binding.driver.generation != generation) {
      throw const PluginBleException('stale_session', 'Unknown BLE binding');
    }
    return binding;
  }

  Future<Object?> call(
    String pluginId,
    int generation,
    String handle,
    String authority,
    String operation,
    Map<String, dynamic> args,
  ) => _binding(pluginId, generation, handle).call(authority, operation, args);

  void publish(
    String pluginId,
    int generation,
    String handle,
    Map<String, dynamic> snapshot,
    String? session, {
    String? sample,
  }) => _binding(
    pluginId,
    generation,
    handle,
  ).publish(snapshot, session, sample: sample);

  void reportDisconnected(
    String pluginId,
    int generation,
    String handle,
    String? session,
  ) => _binding(pluginId, generation, handle).reportDisconnected(session);

  Future<void> discardInactive(Device device) async {
    for (final binding in _bindings.values) {
      if (!identical(binding.device, device)) continue;
      if (binding.occupied || registry.isClaimed(binding.physicalId)) return;
      await discard(device);
      return;
    }
  }

  Future<void> discard(Device device) async {
    final entries = _bindings.entries
        .where((e) => identical(e.value.device, device))
        .toList();
    for (final entry in entries) {
      try {
        await entry.value.dispose();
      } finally {
        _bindings.remove(entry.key);
        removeHandlers(entry.key);
      }
    }
  }

  Future<void> removeGeneration(String pluginId, int generation) async {
    final bindings = _bindings.values
        .where(
          (b) =>
              b.driver.pluginId == pluginId &&
              b.driver.generation == generation,
        )
        .toList();
    try {
      await Future.wait(bindings.map((b) => discard(b.device)));
    } finally {
      registry.removeGeneration(pluginId, generation);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await Future.wait(
        _bindings.values.toList().map((b) => discard(b.device)),
      );
    } finally {
      await registry.dispose();
    }
  }
}
