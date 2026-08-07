import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:rxdart/subjects.dart';

class MockDe1Controller extends De1Controller {
  final List<De1Interface> connectCalls = [];

  bool shouldFailConnect = false;

  Object? failNextConnectWith;

  final BehaviorSubject<De1Interface?> de1Subject = BehaviorSubject.seeded(
    null,
  );

  MockDe1Controller({required super.controller});

  De1Interface? get lastConnectedDe1 =>
      connectCalls.isNotEmpty ? connectCalls.last : null;

  int get connectMachineCallCount => connectCalls.length;

  @override
  Stream<De1Interface?> get de1 => de1Subject.stream;

  @override
  Future<void> connectToDe1(De1Interface de1Interface) async {
    connectCalls.add(de1Interface);
    if (failNextConnectWith != null) {
      final err = failNextConnectWith!;
      failNextConnectWith = null;
      throw err;
    }
    if (shouldFailConnect) {
      throw Exception('MockDe1Controller: simulated connection failure');
    }
    de1Subject.add(de1Interface);
  }
}
