import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:rxdart/rxdart.dart';

class MockScaleController extends ScaleController {
  final List<Scale> connectCalls = [];

  bool shouldFailConnect = false;

  Object? failNextConnectWith;

  final BehaviorSubject<ConnectionState> connectionStateSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);

  String? _mockLastConnectedDeviceId;

  MockScaleController();

  Scale? get lastConnectedScale =>
      connectCalls.isNotEmpty ? connectCalls.last : null;

  @override
  String? get lastConnectedDeviceId => _mockLastConnectedDeviceId;

  void debugSetLastConnectedId(String id) {
    _mockLastConnectedDeviceId = id;
  }

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
    _mockLastConnectedDeviceId = scale.deviceId;
    connectionStateSubject.add(ConnectionState.connected);
  }
}
