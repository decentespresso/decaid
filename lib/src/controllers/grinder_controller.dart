import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class GrinderController {
  Grinder? _grinder;

  StreamSubscription<ConnectionState>? _grinderConnection;
  StreamSubscription<GrinderSnapshot>? _grinderSnapshot;

  String? _lastConnectedDeviceId;
  String? get lastConnectedDeviceId => _lastConnectedDeviceId;

  final Logger log = Logger('GrinderController');

  final BehaviorSubject<ConnectionState> _connectionController =
      BehaviorSubject.seeded(ConnectionState.discovered);
  final StreamController<GrinderSnapshot> _snapshotController =
      StreamController.broadcast();

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  ConnectionState get currentConnectionState => _connectionController.value;
  Stream<GrinderSnapshot> get grinderSnapshot => _snapshotController.stream;

  GrinderController();

  void dispose() {
    _grinderSnapshot?.cancel();
    _grinderSnapshot = null;
    _grinderConnection?.cancel();
    _grinderConnection = null;
    if (!_connectionController.isClosed) {
      _connectionController.close();
    }
    if (!_snapshotController.isClosed) {
      _snapshotController.close();
    }
  }

  Future<void> connectToGrinder(Grinder grinder) async {
    final previous = _grinder;
    _onDisconnect();
    if (previous != null && previous.deviceId != grinder.deviceId) {
      try {
        await previous.disconnect();
      } catch (e) {
        log.warning(
          'Failed to disconnect previous grinder ${previous.deviceId}',
          e,
        );
      }
    }
    _grinderSnapshot = grinder.currentSnapshot.listen(_processSnapshot);
    try {
      await grinder.onConnect();
    } catch (e) {
      log.warning('Grinder failed to connect (onConnect threw)', e);
      _grinderSnapshot?.cancel();
      _grinderSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      rethrow;
    }
    final state = await grinder.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Grinder failed to connect (state: ${state.name})');
      _grinderSnapshot?.cancel();
      _grinderSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      throw StateError('Grinder failed to connect (state: ${state.name})');
    }
    _grinder = grinder;
    _lastConnectedDeviceId = grinder.deviceId;
    _grinderConnection = grinder.connectionState.listen(_processConnection);
  }

  Future<void> adoptGrinder(Grinder grinder) async {
    final previous = _grinder;
    _onDisconnect();
    if (previous != null && previous.deviceId != grinder.deviceId) {
      try {
        await previous.disconnect();
      } catch (e) {
        log.warning(
          'Failed to disconnect previous grinder ${previous.deviceId}',
          e,
        );
      }
    }
    _grinderSnapshot = grinder.currentSnapshot.listen(_processSnapshot);
    final state = await grinder.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Adopted grinder not connected (state: ${state.name})');
      _grinderSnapshot?.cancel();
      _grinderSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      throw StateError('Adopted grinder not connected (state: ${state.name})');
    }
    _grinder = grinder;
    _lastConnectedDeviceId = grinder.deviceId;
    _grinderConnection = grinder.connectionState.listen(_processConnection);
  }

  Grinder connectedGrinder() {
    if (_grinder == null) {
      throw const DeviceNotConnectedException.grinder();
    }
    return _grinder!;
  }

  void _onDisconnect() {
    _grinderSnapshot?.cancel();
    _grinderConnection?.cancel();
    _grinder = null;
    _grinderConnection = null;
  }

  GrinderSnapshot? latestSnapshot;

  void _processSnapshot(GrinderSnapshot snapshot) {
    latestSnapshot = snapshot;
    _snapshotController.add(snapshot);
  }

  void _processConnection(ConnectionState state) {
    log.fine('Grinder connection state: ${state.name}');
    _connectionController.add(state);
  }
}
