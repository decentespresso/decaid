import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:rxdart/rxdart.dart';

/// A ScaleController subclass for testing ConnectionManager.
///
/// Records all [connectToScale] calls and allows controlling the
/// `connectionState` stream and simulating connection failures.
class MockScaleController extends ScaleController {
  /// Every [Scale] passed to [connectToScale].
  final List<Scale> connectCalls = [];

  /// When true, [connectToScale] throws a generic [Exception].
  bool shouldFailConnect = false;

  /// When non-null, [connectToScale] throws this exact object. Takes
  /// precedence over [shouldFailConnect]. Useful for exercising
  /// typed-exception branches (e.g. `FlutterBluePlusException`).
  Object? failNextConnectWith;

  /// The subject backing the overridden [connectionState] stream.
  /// Tests can call `connectionStateSubject.add(...)` to simulate changes.
  final BehaviorSubject<ConnectionState> connectionStateSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);

  String? _mockLastConnectedDeviceId;

  MockScaleController();

  Scale? get lastConnectedScale =>
      connectCalls.isNotEmpty ? connectCalls.last : null;

  @override
  String? get lastConnectedDeviceId => _mockLastConnectedDeviceId;

  /// Seed [lastConnectedDeviceId] without going through [connectToScale].
  void debugSetLastConnectedId(String id) {
    _mockLastConnectedDeviceId = id;
  }

  /// Push a [ConnectionState] onto the stream that ConnectionManager
  /// subscribes to, simulating a transport-level transition.
  void mockEmitConnectionState(ConnectionState state) {
    connectionStateSubject.add(state);
  }

  @override
  Stream<ConnectionState> get connectionState => connectionStateSubject.stream;

  @override
  Future<void> connectToScale(Scale scale) async {
    connectCalls.add(scale);
    if (failNextConnectWith != null) {
      final err = failNextConnectWith!;
      failNextConnectWith = null;
      throw err;
    }
    if (shouldFailConnect) {
      throw Exception('MockScaleController: simulated connection failure');
    }
    // Don't call super — we don't want real connection logic in tests.
    _mockLastConnectedDeviceId = scale.deviceId;
    connectionStateSubject.add(ConnectionState.connected);
  }
}
