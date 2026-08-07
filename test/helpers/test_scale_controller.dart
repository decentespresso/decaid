import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/scale.dart';
import 'package:rxdart/rxdart.dart';

import 'test_scale.dart';

class TestScaleController extends ScaleController {
  final TestScale testScale;
  final BehaviorSubject<device.ConnectionState> _connectionState;
  final BehaviorSubject<WeightSnapshot> _weight = BehaviorSubject();

  TestScaleController(this.testScale)
    : _connectionState = BehaviorSubject.seeded(
        device.ConnectionState.connected,
      );

  @override
  Stream<device.ConnectionState> get connectionState => _connectionState.stream;

  @override
  device.ConnectionState get currentConnectionState => _connectionState.value;

  @override
  Stream<WeightSnapshot> get weightSnapshot => _weight.stream;

  @override
  Scale connectedScale() {
    if (_connectionState.value != device.ConnectionState.connected) {
      throw 'No scale connected';
    }
    return testScale;
  }

  void emitWeight(double weight, {double weightFlow = 0.0}) {
    _weight.add(
      WeightSnapshot(
        timestamp: DateTime(2026, 1, 15, 8, 0),
        weight: weight,
        weightFlow: weightFlow,
      ),
    );
  }

  void simulateDisconnect() {
    _connectionState.add(device.ConnectionState.disconnected);
  }

  @override
  void dispose() {
    _connectionState.close();
    _weight.close();
    super.dispose();
  }
}
