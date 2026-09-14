import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

/// One scale held open beside the primary one, with no meaning attached to it
/// by the gateway. What it is for -- weighing a dose, a grinder, a comparison
/// against the brewing scale -- is the client's to decide; all this owns is the
/// connection and the two things a caller can do with it, which are read the
/// snapshots and tare.
class AuxiliaryScaleSession {
  final Scale scale;

  String get deviceId => scale.deviceId;

  StreamSubscription<ConnectionState>? _connectionSub;
  StreamSubscription<ScaleSnapshot>? _snapshotSub;

  /// Bumped on every detach so a connect that finishes late cannot deliver
  /// snapshots into a session that has since been replaced.
  int _generation = 0;
  int get generation => _generation;

  ScaleSnapshot? _currentSnapshot;
  ScaleSnapshot? get currentSnapshot => _currentSnapshot;

  final Logger _log;

  final BehaviorSubject<ConnectionState> _connectionController =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  ConnectionState get currentConnectionState => _connectionController.value;

  final StreamController<ScaleSnapshot> _snapshotController =
      StreamController.broadcast();

  Stream<ScaleSnapshot> get snapshot => _snapshotController.stream;

  AuxiliaryScaleSession(this.scale)
    : _log = Logger('AuxiliaryScale(${scale.deviceId})');

  /// Opens the connection. Throws if the scale does not reach connected, and
  /// leaves nothing subscribed behind when it does.
  Future<void> connect() async {
    _snapshotSub = scale.currentSnapshot.listen(_processSnapshot);
    try {
      await scale.onConnect();
    } catch (e) {
      _log.warning('Auxiliary scale failed to connect (onConnect threw)', e);
      await _detach();
      _connectionController.add(ConnectionState.disconnected);
      rethrow;
    }
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      _log.warning('Auxiliary scale failed to connect (state: ${state.name})');
      await _detach();
      _connectionController.add(ConnectionState.disconnected);
      throw StateError(
        'Auxiliary scale failed to connect (state: ${state.name})',
      );
    }
    _attach();
  }

  /// Takes over a scale that is already connected, which is how a device the
  /// transport brought up on its own becomes an auxiliary session.
  Future<void> adopt() async {
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      _log.warning('Adopted auxiliary scale not connected (${state.name})');
      _connectionController.add(ConnectionState.disconnected);
      throw StateError(
        'Adopted auxiliary scale not connected (state: ${state.name})',
      );
    }
    _snapshotSub ??= scale.currentSnapshot.listen(_processSnapshot);
    _attach();
  }

  void _attach() {
    _connectionSub = scale.connectionState.listen(_processConnection);
    if (scale is ScaleSnapshotHandoff) {
      (scale as ScaleSnapshotHandoff).activateSnapshots();
    }
    _connectionController.add(ConnectionState.connected);
  }

  Future<void> tare() async {
    if (currentConnectionState != ConnectionState.connected) {
      throw const DeviceNotConnectedException.scale();
    }
    await scale.tare();
  }

  /// Closes the connection and the session with it.
  Future<void> disconnect() async {
    await _detach();
    _connectionController.add(ConnectionState.disconnected);
    try {
      await scale.disconnect();
    } catch (e) {
      _log.warning('Failed to disconnect auxiliary scale $deviceId', e);
    }
  }

  Future<void> dispose() async {
    await _detach();
    if (!_connectionController.isClosed) {
      await _connectionController.close();
    }
    if (!_snapshotController.isClosed) {
      await _snapshotController.close();
    }
  }

  Future<void> _detach() async {
    _generation++;
    _currentSnapshot = null;
    await _snapshotSub?.cancel();
    _snapshotSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
  }

  void _processSnapshot(ScaleSnapshot snapshot) {
    _currentSnapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void _processConnection(ConnectionState state) {
    if (!_connectionController.isClosed) {
      _connectionController.add(state);
    }
    if (state == ConnectionState.disconnected) {
      _currentSnapshot = null;
    }
  }
}

/// Every scale a client is holding open beside the primary one, keyed by device
/// id. Nothing in the brewing path reads this: [ScaleController] remains the
/// only scale a shot knows about.
class AuxiliaryScaleRegistry {
  final Map<String, AuxiliaryScaleSession> _sessions = {};
  final Logger _log = Logger('AuxiliaryScaleRegistry');

  final StreamController<Set<String>> _changes = StreamController.broadcast();

  /// Emits the held device ids whenever one is added or removed, so an
  /// inventory that reports connection roles can re-publish itself.
  Stream<Set<String>> get changes => _changes.stream;

  Set<String> get deviceIds => _sessions.keys.toSet();

  bool holds(String deviceId) => _sessions.containsKey(deviceId);

  AuxiliaryScaleSession? session(String deviceId) => _sessions[deviceId];

  Iterable<AuxiliaryScaleSession> get sessions => _sessions.values;

  /// Holding a scale that is already held is the same request twice, not a
  /// second session.
  Future<AuxiliaryScaleSession> connect(Scale scale) async {
    final existing = _sessions[scale.deviceId];
    if (existing != null) {
      _log.fine('Auxiliary scale ${scale.deviceId} already held');
      return existing;
    }
    final session = AuxiliaryScaleSession(scale);
    _sessions[scale.deviceId] = session;
    try {
      await session.connect();
    } catch (_) {
      _sessions.remove(scale.deviceId);
      await session.dispose();
      _publish();
      rethrow;
    }
    _publish();
    return session;
  }

  Future<AuxiliaryScaleSession> adopt(Scale scale) async {
    final existing = _sessions[scale.deviceId];
    if (existing != null) return existing;
    final session = AuxiliaryScaleSession(scale);
    _sessions[scale.deviceId] = session;
    try {
      await session.adopt();
    } catch (_) {
      _sessions.remove(scale.deviceId);
      await session.dispose();
      _publish();
      rethrow;
    }
    _publish();
    return session;
  }

  /// Releasing one leaves the others alone, and returns the device to ordinary
  /// primary eligibility.
  Future<void> release(String deviceId) async {
    final session = _sessions.remove(deviceId);
    if (session == null) return;
    _publish();
    await session.disconnect();
    await session.dispose();
  }

  Future<void> releaseAll() async {
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await release(id);
    }
  }

  Future<void> dispose() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
    if (!_changes.isClosed) {
      await _changes.close();
    }
  }

  void _publish() {
    if (!_changes.isClosed) {
      _changes.add(deviceIds);
    }
  }
}
