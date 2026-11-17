import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:rxdart/rxdart.dart';

enum ScaleConnectionRole { primary, auxiliary }

class AuxiliaryScaleConnection {
  final Scale scale;
  final String deviceId;
  final Stream<ConnectionState> connectionState;
  final Stream<ScaleSnapshot> snapshots;

  AuxiliaryScaleConnection._({
    required this.scale,
    required this.deviceId,
    required this.connectionState,
    required this.snapshots,
  });
}

class AuxiliaryScaleRegistry {
  final Logger _log = Logger('AuxiliaryScaleRegistry');
  final Map<String, _Session> _sessions = {};
  final Map<String, _Pending> _pending = {};
  final BehaviorSubject<int> _changes = BehaviorSubject.seeded(0);
  bool _disposed = false;

  Stream<int> get changes => _changes.stream;
  Iterable<String> get connectedDeviceIds => _sessions.entries
      .where((entry) => !entry.value.closing)
      .map((entry) => entry.key);

  AuxiliaryScaleConnection? connectionFor(String deviceId) {
    final session = _sessions[deviceId];
    if (session == null || session.closing) return null;
    return session.publicConnection;
  }

  bool isConnectedOrPending(String deviceId) =>
      _sessions.containsKey(deviceId) || _pending.containsKey(deviceId);

  bool isReserved(String deviceId) => isConnectedOrPending(deviceId);

  Future<ConnectionResult> connect(
    Scale scale, {
    required bool Function(String deviceId) isPrimaryClaimed,
  }) async {
    final id = scale.deviceId;
    if (_disposed) return const ConnectionResult.conflict();
    final existing = _sessions[id];
    if (existing != null) {
      return existing.closing
          ? const ConnectionResult.conflict()
          : const ConnectionResult.alreadyConnected();
    }
    if (_pending.containsKey(id)) {
      return const ConnectionResult.conflict();
    }
    if (isPrimaryClaimed(id)) {
      return const ConnectionResult.conflict();
    }
    final operation = _Pending(scale);
    _pending[id] = operation;
    try {
      try {
        await scale.onConnect();
      } finally {
        operation.connectSettled.complete();
      }
      if (!identical(_pending[id], operation) ||
          operation.cancelled ||
          _disposed) {
        await _cleanupLateConnect(id, scale, operation);
        return const ConnectionResult.conflict();
      }
      final state = await scale.connectionState.first;
      if (!identical(_pending[id], operation) ||
          operation.cancelled ||
          _disposed) {
        await _cleanupLateConnect(id, scale, operation);
        return const ConnectionResult.conflict();
      }
      if (state != ConnectionState.connected) {
        await _disconnectQuietly(scale);
        return ConnectionResult.failed(
          'Scale failed to connect (state: ${state.name})',
        );
      }
      if (isPrimaryClaimed(id)) {
        await _disconnectQuietly(scale);
        return const ConnectionResult.conflict();
      }
      final session = _Session(scale);
      _sessions[id] = session;
      try {
        session.start(() => _removeIfCurrent(id, session));
      } catch (_) {
        _sessions.remove(id);
        await session.dispose();
        rethrow;
      }
      _notify();
      return const ConnectionResult.succeeded();
    } catch (error) {
      await _cleanupLateConnect(id, scale, operation);
      _log.warning('Auxiliary scale $id failed to connect', error);
      return ConnectionResult.failed(error.toString());
    } finally {
      if (identical(_pending[id], operation)) {
        _pending.remove(id);
        _notify();
      }
    }
  }

  Future<ConnectionResult> disconnect(String deviceId) async {
    final session = _sessions[deviceId];
    if (session == null) {
      final pending = _pending[deviceId];
      if (pending != null) {
        _cancelPending(pending);
        return const ConnectionResult.succeeded();
      }
      return const ConnectionResult.conflict();
    }
    if (session.closing) return const ConnectionResult.conflict();
    session.closing = true;
    _notify();
    await _finishSession(deviceId, session);
    return const ConnectionResult.succeeded();
  }

  void cancelPending(String deviceId) {
    final pending = _pending[deviceId];
    if (pending != null) _cancelPending(pending);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final pending in _pending.values) {
      _cancelPending(pending);
    }
    final sessions = _sessions.entries.toList();
    for (final entry in sessions) {
      entry.value.closing = true;
      await _finishSession(entry.key, entry.value);
    }
    await _changes.close();
  }

  void _removeIfCurrent(String id, _Session session) {
    if (!identical(_sessions[id], session)) return;
    if (session.closing) return;
    session.closing = true;
    _notify();
    unawaited(_finishSession(id, session));
  }

  void _cancelPending(_Pending pending) {
    if (pending.cancelled) return;
    pending.cancelled = true;
    pending.cleanupFuture ??= _disconnectAfterConnect(pending);
    _notify();
  }

  Future<void> _finishSession(String id, _Session session) async {
    await session.dispose();
    if (identical(_sessions[id], session)) _sessions.remove(id);
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(_changes.value + 1);
  }

  Future<void> _cleanupLateConnect(
    String id,
    Scale scale,
    _Pending pending,
  ) async {
    final current = _sessions[id];
    if (current != null && identical(current.scale, scale)) return;
    await (pending.cleanupFuture ??= _disconnectAfterConnect(pending));
  }

  Future<void> _disconnectAfterConnect(_Pending pending) async {
    await pending.connectSettled.future;
    await _disconnectQuietly(pending.scale);
  }

  Future<void> _disconnectQuietly(Scale scale) async {
    try {
      await scale.disconnect();
    } catch (error, stackTrace) {
      _log.warning(
        'Auxiliary scale ${scale.deviceId} cleanup failed',
        error,
        stackTrace,
      );
    }
  }
}

class _Pending {
  final Scale scale;
  final Completer<void> connectSettled = Completer<void>();
  bool cancelled = false;
  Future<void>? cleanupFuture;

  _Pending(this.scale);
}

class _Session {
  final Scale scale;
  late final AuxiliaryScaleConnection publicConnection =
      AuxiliaryScaleConnection._(
        scale: scale,
        deviceId: scale.deviceId,
        connectionState: _connection.stream,
        snapshots: _snapshots.stream,
      );
  bool closing = false;
  bool _disposed = false;
  final BehaviorSubject<ConnectionState> _connection = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<ScaleSnapshot> _snapshots =
      StreamController.broadcast();

  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<ScaleSnapshot>? _snapshotSub;

  _Session(this.scale);

  void start(void Function() onDisconnect) {
    _connection.add(ConnectionState.connected);
    _connectionSub = scale.connectionState.listen((state) {
      _connection.add(state);
      if (state == ConnectionState.disconnected) onDisconnect();
    });
    _snapshotSub = scale.currentSnapshot.listen(_snapshots.add);
    if (scale is ScaleSnapshotHandoff) {
      (scale as ScaleSnapshotHandoff).activateSnapshots();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _snapshotSub?.cancel();
    await _connectionSub?.cancel();
    _snapshotSub = null;
    _connectionSub = null;
    if (!_snapshots.isClosed) await _snapshots.close();
    if (!_connection.isClosed) await _connection.close();
    try {
      await scale.disconnect();
    } catch (_) {}
  }
}
