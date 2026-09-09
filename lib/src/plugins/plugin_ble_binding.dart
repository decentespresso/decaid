import 'dart:async';

import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

import 'plugin_ble_registry.dart';
import 'plugin_ble_session.dart';
import 'plugin_bound_sensor.dart';
import 'plugin_device_contract.dart';
import 'plugin_manifest.dart';
import 'plugin_scale.dart';

class PluginBleBinding {
  final PluginBleRegistry registry;
  final PluginBleDriver driver;
  final String physicalId;
  final String handle;
  final BLETransport Function() createTransport;
  final bool Function() admit;
  final bool Function() runtimeAlive;
  final PluginDeviceInvoker invokeHandler;
  final Future<void> Function(Map<String, dynamic>) eventSink;
  final Duration invocationTimeout;
  late final PluginDeviceAdapter device;
  PluginBleSession? _session;
  String? _domainSession;
  bool _disposed = false;
  Future<void>? _disposal;

  PluginBleBinding({
    required this.registry,
    required this.driver,
    required this.physicalId,
    required this.handle,
    required this.createTransport,
    required this.admit,
    required this.runtimeAlive,
    required this.invokeHandler,
    required this.eventSink,
    required this.invocationTimeout,
    required String name,
    required Map<String, dynamic> definition,
  }) {
    final publicId =
        'plugin:${driver.pluginId}:${driver.declaration.id}:$physicalId';
    device = driver.declaration.type == PluginDriverType.sensor
        ? PluginBoundSensor(
            deviceId: publicId,
            name: name,
            invoke: invoke,
            transportType: TransportType.ble,
            onReady: () => _session!.markReady(),
            invocationTimeout: invocationTimeout,
            definition: definition,
          )
        : PluginScale(
            deviceId: publicId,
            name: name,
            invoke: invoke,
            transportType: TransportType.ble,
            onReady: () => _session!.markReady(),
            invocationTimeout: invocationTimeout,
            capabilities: driver.declaration.capabilities,
          );
  }

  bool get occupied =>
      _session != null && _session!.state != PluginBleSessionState.closed;

  void revoke() => _session?.revoke();

  Future<Map<String, dynamic>> invoke(
    PluginDeviceOperation operation,
    Map<String, dynamic> payload,
  ) async {
    if (operation == PluginDeviceOperation.disconnect) {
      final session = _session;
      _domainSession = null;
      if (session != null) {
        await session.retire(
          cleanup: (authority) async {
            await invokeHandler(operation, {'gattSession': authority});
          },
        );
        await session.closed.timeout(invocationTimeout);
      }
      return const {};
    }
    if (_disposed || !registry.isCurrent(driver) || !runtimeAlive()) {
      throw const PluginBleException('stale_session', 'BLE binding retired');
    }
    if (operation != PluginDeviceOperation.connect) {
      final session = _session;
      if (session == null || session.state != PluginBleSessionState.ready) {
        throw const PluginBleException(
          'stale_session',
          'BLE device is not ready',
        );
      }
      final result = await invokeHandler(operation, payload);
      if (!identical(_session, session) || !session.acceptsPublications) {
        throw const PluginBleException('stale_session', 'BLE command retired');
      }
      return result;
    }
    if (occupied) {
      throw const PluginBleException(
        'resource_limit',
        'BLE teardown is pending',
      );
    }
    if (!admit()) {
      throw const PluginBleException('stale_session', 'BLE ownership changed');
    }
    final PluginBleClaim claim;
    try {
      claim = registry.reserve(driver, physicalId);
    } on StateError catch (error) {
      throw PluginBleException('resource_limit', error.message);
    }
    final PluginBleSession session;
    try {
      session = PluginBleSession(
        transport: createTransport(),
        authorized: () => registry.isCurrent(driver),
        runtimeAlive: runtimeAlive,
        cleanupTimeout: invocationTimeout,
        eventSink: (event) async {
          if (event['type'] == 'disconnect') {
            final domainSession = _domainSession;
            if (domainSession != null) {
              device.reportDisconnected(session: domainSession);
            }
          }
          await eventSink(event);
        },
      );
    } catch (_) {
      registry.release(claim);
      rethrow;
    }
    _session = session;
    _domainSession = payload['session'] as String;
    unawaited(session.closed.then((_) => registry.release(claim)));
    await session.connect();
    try {
      return await invokeHandler(operation, {
        ...payload,
        'gattSession': session.id,
      });
    } catch (_) {
      await session.retire();
      rethrow;
    }
  }

  Future<Object?> call(
    String authority,
    String operation,
    Map<String, dynamic> args,
  ) {
    final session = _session;
    if (session == null) {
      throw const PluginBleException('stale_session', 'Unknown BLE session');
    }
    return session.call(authority, operation, args);
  }

  void publish(
    Map<String, dynamic> snapshot,
    String? domainSession, {
    String? sample,
  }) {
    _checkPublication(domainSession);
    final timestamp = sample == null ? null : _session!.consumeSample(sample);
    final target = device;
    if (target is PluginScale) {
      target.publish(snapshot, session: domainSession, timestamp: timestamp);
    } else {
      target.publish(snapshot, session: domainSession);
    }
  }

  void reportDisconnected(String? domainSession) {
    _checkPublication(domainSession);
    device.reportDisconnected(session: domainSession);
  }

  void _checkPublication(String? domainSession) {
    if (domainSession == null ||
        domainSession != _domainSession ||
        _session?.acceptsPublications != true) {
      throw const PluginBleException(
        'stale_session',
        'BLE publication retired',
      );
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    try {
      await device.disconnect();
    } finally {
      await device.dispose();
    }
  }
}
