import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

import 'plugin_device_contract.dart';

abstract class PluginProtocolDevice extends PluginDeviceAdapter {
  @override
  final String deviceId;
  @override
  final String name;
  @override
  final TransportType transportType;
  final PluginDeviceInvoker invoke;
  final void Function()? onReady;
  final Duration invocationTimeout;
  final BehaviorSubject<ConnectionState> _state = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final Logger _log = Logger('PluginProtocolDevice');
  Future<void>? _connecting;
  Future<void>? _disconnecting;
  Completer<void>? _cancelled;
  String? _session;
  bool _disposed = false;

  PluginProtocolDevice({
    required this.deviceId,
    required this.name,
    required this.invoke,
    this.transportType = TransportType.unknown,
    this.onReady,
    this.invocationTimeout = const Duration(seconds: 5),
  });

  @override
  DeviceImplementation get implementation => DeviceImplementation.plugin;
  @override
  Stream<ConnectionState> get connectionState => _state.stream;

  void checkSession(String? session) {
    if (_disposed ||
        session == null ||
        session != _session ||
        (_state.value != ConnectionState.connecting &&
            _state.value != ConnectionState.connected)) {
      throw const PluginDeviceException(
        'Stale plugin device session',
        code: 'stale_session',
      );
    }
  }

  void beginSamples() {}
  Future<void> waitForReadiness() async {}

  @override
  Future<void> onConnect() {
    if (_disposed) {
      return Future.error(
        const PluginDeviceException('Plugin device disposed'),
      );
    }
    if (_state.value == ConnectionState.connected) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    final disconnecting = _disconnecting;
    if (disconnecting != null) {
      try {
        await disconnecting;
      } catch (error) {
        _log.warning('Previous plugin device cleanup failed', error);
      }
    }
    if (_disposed) throw const PluginDeviceException('Plugin device disposed');
    final session = const Uuid().v4();
    _session = session;
    final cancelled = Completer<void>();
    _cancelled = cancelled;
    beginSamples();
    final readiness = waitForReadiness();
    _state.add(ConnectionState.connecting);
    try {
      final initialization = () async {
        await invoke(PluginDeviceOperation.connect, {'session': session});
        await readiness;
      }();
      await Future.any([
        initialization,
        cancelled.future,
      ]).timeout(invocationTimeout);
      checkSession(session);
      onReady?.call();
      _state.add(ConnectionState.connected);
    } catch (error, stackTrace) {
      if (_session == session) {
        try {
          await disconnect();
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> disconnect() {
    if (_disposed) return Future.value();
    final existing = _disconnecting;
    if (existing != null) return existing;
    final session = _session;
    _session = null;
    _state.add(ConnectionState.disconnecting);
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    return _disconnecting = () async {
      try {
        await invoke(PluginDeviceOperation.disconnect, {
          'session': session,
        }).timeout(invocationTimeout);
      } finally {
        _disconnecting = null;
        if (!_disposed) _state.add(ConnectionState.disconnected);
      }
    }();
  }

  Future<void> command(PluginDeviceOperation operation) async {
    final session = _session;
    checkSession(session);
    if (_state.value != ConnectionState.connected) {
      throw const PluginDeviceException('Plugin device is not ready');
    }
    await invoke(operation, {'session': session}).timeout(invocationTimeout);
    checkSession(session);
  }

  @override
  void reportDisconnected({String? session}) {
    checkSession(session);
    unawaited(
      disconnect().catchError((Object error) {
        _log.warning('Plugin protocol failure cleanup device=$deviceId', error);
      }),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _session = null;
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    await _state.close();
  }
}
