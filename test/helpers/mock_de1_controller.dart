import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:rxdart/subjects.dart';

/// A De1Controller subclass for testing ConnectionManager.
///
/// Records all [connectToDe1] calls and allows controlling the `de1` stream
/// and simulating connection failures.
class MockDe1Controller extends De1Controller {
  /// Every [De1Interface] passed to [connectToDe1].
  final List<De1Interface> connectCalls = [];

  /// When true, [connectToDe1] throws instead of succeeding.
  bool shouldFailConnect = false;

  /// When non-null, [connectToDe1] throws this exact object. Takes
  /// precedence over [shouldFailConnect]. Useful for exercising
  /// typed-exception branches (e.g. `FlutterBluePlusException`).
  Object? failNextConnectWith;

  /// The subject backing the overridden [de1] stream.
  /// Tests can call `de1Subject.add(someDe1)` to simulate connection changes.
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
