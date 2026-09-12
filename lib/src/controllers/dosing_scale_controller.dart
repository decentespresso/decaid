import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class DosingScaleController {
  Scale? _scale;

  StreamSubscription<ConnectionState>? _scaleConnection;
  StreamSubscription<ScaleSnapshot>? _scaleSnapshot;

  String? _lastConnectedDeviceId;
  String? get lastConnectedDeviceId => _lastConnectedDeviceId;

  int _connectionGeneration = 0;
  int get connectionGeneration => _connectionGeneration;

  ScaleSnapshot? _currentSnapshot;
  ScaleSnapshot? get currentSnapshot => _currentSnapshot;

  final Logger log = Logger('DosingScaleController');

  DosingScaleController();

  final BehaviorSubject<ConnectionState> _connectionController =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  ConnectionState get currentConnectionState => _connectionController.value;

  final StreamController<ScaleSnapshot> _snapshotController =
      StreamController.broadcast();

  Stream<ScaleSnapshot> get snapshot => _snapshotController.stream;

  Future<void> connectToScale(Scale scale) async {
    await _releaseCurrent(keeping: scale.deviceId);
    _scaleSnapshot = scale.currentSnapshot.listen(_processSnapshot);
    try {
      await scale.onConnect();
    } catch (e) {
      log.warning('Dosing scale failed to connect (onConnect threw)', e);
      _scaleSnapshot?.cancel();
      _scaleSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      rethrow;
    }
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Dosing scale failed to connect (state: ${state.name})');
      _scaleSnapshot?.cancel();
      _scaleSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      throw StateError('Dosing scale failed to connect (state: ${state.name})');
    }
    _scale = scale;
    _lastConnectedDeviceId = scale.deviceId;
    _scaleConnection = scale.connectionState.listen(_processConnection);
    if (scale is ScaleSnapshotHandoff) {
      (scale as ScaleSnapshotHandoff).activateSnapshots();
    }
    _connectionController.add(ConnectionState.connected);
  }

  Future<void> adoptScale(Scale scale) async {
    await _releaseCurrent(keeping: scale.deviceId);
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Adopted dosing scale not connected (state: ${state.name})');
      _connectionController.add(ConnectionState.disconnected);
      throw StateError(
        'Adopted dosing scale not connected (state: ${state.name})',
      );
    }
    _scale = scale;
    _lastConnectedDeviceId = scale.deviceId;
    _scaleSnapshot = scale.currentSnapshot.listen(_processSnapshot);
    _scaleConnection = scale.connectionState.listen(_processConnection);
    if (scale is ScaleSnapshotHandoff) {
      (scale as ScaleSnapshotHandoff).activateSnapshots();
    }
    _connectionController.add(ConnectionState.connected);
  }

  Scale connectedScale() {
    final scale = _scale;
    if (scale == null) {
      throw const DeviceNotConnectedException.scale();
    }
    return scale;
  }

  Future<void> tare() async {
    await connectedScale().tare();
  }

  Future<void> disconnect() async {
    final scale = _scale;
    _detach();
    _connectionController.add(ConnectionState.disconnected);
    if (scale == null) return;
    try {
      await scale.disconnect();
    } catch (e) {
      log.warning('Failed to disconnect dosing scale ${scale.deviceId}', e);
    }
  }

  void dispose() {
    _detach();
    if (!_connectionController.isClosed) {
      _connectionController.close();
    }
    if (!_snapshotController.isClosed) {
      _snapshotController.close();
    }
  }

  Future<void> _releaseCurrent({required String keeping}) async {
    final previous = _scale;
    _detach();
    if (previous == null || previous.deviceId == keeping) return;
    try {
      if (previous is TransportHandoffScale) {
        await (previous as TransportHandoffScale).disconnectForHandoff();
      } else {
        await previous.disconnect();
      }
    } catch (e) {
      log.warning(
        'Failed to disconnect previous dosing scale ${previous.deviceId}',
        e,
      );
    }
  }

  void _detach() {
    _connectionGeneration++;
    _currentSnapshot = null;
    _scaleSnapshot?.cancel();
    _scaleSnapshot = null;
    _scaleConnection?.cancel();
    _scaleConnection = null;
    _scale = null;
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
