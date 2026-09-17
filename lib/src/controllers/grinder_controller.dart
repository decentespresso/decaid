import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class GrinderController {
  GrinderDevice? _grinder;
  GrinderDevice? _pendingGrinder;
  Future<void>? _pendingSelection;
  GrinderSnapshot? _currentSnapshot;
  StreamSubscription<GrinderSnapshot>? _snapshotSubscription;
  StreamSubscription<ConnectionState>? _connectionSubscription;
  final Map<GrinderDevice, Future<void>> _teardowns = Map.identity();
  int _generation = 0;
  bool _disposed = false;
  final Logger _log = Logger('GrinderController');
  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.discovered);
  final StreamController<GrinderSnapshot> _snapshots =
      StreamController.broadcast();

  GrinderSnapshot? get currentSnapshot => _currentSnapshot;
  Stream<GrinderSnapshot> get snapshots => _snapshots.stream;
  Stream<ConnectionState> get connectionState => _connectionState.stream;
  ConnectionState get currentConnectionState => _connectionState.value;
  bool get isOccupied => _grinder != null || _pendingGrinder != null;

  bool isSelected(GrinderDevice grinder) =>
      identical(_grinder, grinder) &&
      currentConnectionState == ConnectionState.connected;

  Future<void> connectToGrinder(GrinderDevice grinder) {
    if (_disposed) {
      return Future.error(StateError('GrinderController disposed'));
    }
    if (isSelected(grinder)) return Future.value();
    final pending = _pendingSelection;
    if (identical(_pendingGrinder, grinder) && pending != null) return pending;
    return _beginSelection(grinder, connect: true);
  }

  Future<void> adoptGrinder(GrinderDevice grinder) {
    if (_disposed) {
      return Future.error(StateError('GrinderController disposed'));
    }
    if (isSelected(grinder)) return Future.value();
    return _beginSelection(grinder, connect: false);
  }

  Future<void> _beginSelection(GrinderDevice grinder, {required bool connect}) {
    late Future<void> operation;
    operation = _select(grinder, connect: connect).whenComplete(() {
      if (identical(_pendingSelection, operation)) _pendingSelection = null;
    });
    _pendingSelection = operation;
    return operation;
  }

  Future<void> _select(GrinderDevice grinder, {required bool connect}) async {
    final generation = ++_generation;
    final previous = _grinder;
    final pending = _pendingGrinder;
    _pendingGrinder = grinder;
    _grinder = null;
    _currentSnapshot = null;
    _connectionState.add(ConnectionState.connecting);
    GrinderSnapshot? initialSnapshot;
    var active = false;
    try {
      await _cancelSubscriptions();
      if (pending != null && !identical(pending, grinder)) {
        await _disconnectQuietly(pending);
      }
      if (previous != null &&
          !identical(previous, grinder) &&
          !identical(previous, pending)) {
        await _disconnectQuietly(previous);
      }
      final teardown = _teardowns[grinder];
      if (teardown != null) await teardown;
      _ensureCurrent(generation, grinder);
      _snapshotSubscription = grinder.currentSnapshot.listen((snapshot) {
        if (generation != _generation) return;
        initialSnapshot = snapshot;
        if (!active) return;
        _publish(snapshot);
      });
      if (connect) await grinder.onConnect();
      final state = await grinder.connectionState.first;
      if (state != ConnectionState.connected) {
        throw StateError('Grinder failed to connect (state: ${state.name})');
      }
      _ensureCurrent(generation, grinder);
      _pendingGrinder = null;
      _grinder = grinder;
      active = true;
      final snapshot = initialSnapshot;
      if (snapshot != null) _publish(snapshot);
      _connectionState.add(ConnectionState.connected);
      _connectionSubscription = grinder.connectionState.listen((state) {
        if (generation != _generation) return;
        _connectionState.add(state);
        if (state == ConnectionState.disconnected) _clearSelection();
      });
    } catch (error, stackTrace) {
      if (generation == _generation) {
        await _cancelSubscriptions();
        await _disconnectQuietly(grinder);
        if (generation == _generation) {
          _pendingGrinder = null;
          _grinder = null;
          _currentSnapshot = null;
          _connectionState.add(ConnectionState.disconnected);
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _ensureCurrent(int generation, GrinderDevice grinder) {
    if (generation != _generation || !identical(_pendingGrinder, grinder)) {
      throw StateError('Grinder connection superseded');
    }
  }

  void _publish(GrinderSnapshot snapshot) {
    _currentSnapshot = snapshot;
    _snapshots.add(snapshot);
  }

  void _clearSelection() {
    _generation++;
    _grinder = null;
    _pendingGrinder = null;
    _currentSnapshot = null;
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_connectionSubscription?.cancel());
    _snapshotSubscription = null;
    _connectionSubscription = null;
  }

  Future<void> _cancelSubscriptions() async {
    final snapshotSubscription = _snapshotSubscription;
    final connectionSubscription = _connectionSubscription;
    _snapshotSubscription = null;
    _connectionSubscription = null;
    await snapshotSubscription?.cancel();
    await connectionSubscription?.cancel();
  }

  Future<void> _disconnectQuietly(GrinderDevice grinder) async {
    try {
      await _disconnectOnce(grinder);
    } catch (error) {
      _log.warning('Failed to disconnect grinder ${grinder.deviceId}', error);
    }
  }

  Future<void> _disconnectOnce(GrinderDevice grinder) {
    final existing = _teardowns[grinder];
    if (existing != null) return existing;
    late final Future<void> teardown;
    teardown = Future.sync(grinder.disconnect).whenComplete(() {
      if (identical(_teardowns[grinder], teardown)) {
        _teardowns.remove(grinder);
      }
    });
    _teardowns[grinder] = teardown;
    return teardown;
  }

  GrinderDevice connectedGrinder() {
    final grinder = _grinder;
    if (grinder == null) throw const DeviceNotConnectedException.grinder();
    return grinder;
  }

  Future<void> start() => connectedGrinder().start();
  Future<void> stop() => connectedGrinder().stop();
  Future<void> setGrindSetting(String setting) =>
      connectedGrinder().setGrindSetting(setting);
  Future<void> setRpm(int rpm) => connectedGrinder().setRpm(rpm);

  Future<void> disconnectDevice(GrinderDevice grinder) async {
    if (_grinder?.deviceId == grinder.deviceId ||
        _pendingGrinder?.deviceId == grinder.deviceId) {
      await disconnect();
      return;
    }
    await grinder.disconnect();
  }

  Future<void> cancelConnection(GrinderDevice grinder) async {
    if (!identical(_grinder, grinder) && !identical(_pendingGrinder, grinder)) {
      return;
    }
    await _disconnect(reportFailure: false);
  }

  Future<void> disconnect() => _disconnect(reportFailure: true);

  Future<void> _disconnect({required bool reportFailure}) async {
    final grinder = _grinder;
    final pending = _pendingGrinder;
    final generation = ++_generation;
    _grinder = null;
    _pendingGrinder = null;
    _currentSnapshot = null;
    final teardowns = <Future<void>>[
      if (pending != null)
        reportFailure ? _disconnectOnce(pending) : _disconnectQuietly(pending),
      if (grinder != null && !identical(grinder, pending))
        reportFailure ? _disconnectOnce(grinder) : _disconnectQuietly(grinder),
    ];
    final teardown = Future.wait(teardowns);
    final subscriptions = _cancelSubscriptions();
    try {
      await Future.wait([teardown, subscriptions]);
    } finally {
      if (generation == _generation &&
          _grinder == null &&
          _pendingGrinder == null) {
        _connectionState.add(ConnectionState.disconnected);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _disconnect(reportFailure: false);
    } finally {
      await _snapshots.close();
      await _connectionState.close();
    }
  }
}
