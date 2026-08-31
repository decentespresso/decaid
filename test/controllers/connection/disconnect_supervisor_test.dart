import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/disconnect_expectations.dart';
import 'package:reaprime/src/controllers/connection/disconnect_supervisor.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';

class _FakeDe1 implements De1Interface {
  @override
  final String deviceId;

  _FakeDe1(this.deviceId);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('DisconnectSupervisor', () {
    late StreamController<De1Interface?> machineController;
    late StatusPublisher statusPublisher;
    late DisconnectSupervisor supervisor;
    bool connecting = false;

    setUp(() {
      machineController = StreamController<De1Interface?>.broadcast();
      statusPublisher = StatusPublisher();
      connecting = false;
      supervisor = DisconnectSupervisor(
        machineStream: machineController.stream,
        scaleStream: const Stream.empty(),
        statusPublisher: statusPublisher,
        expectations: DisconnectExpectations(),
        isConnectingMachine: () => connecting,
        isConnectingScale: () => false,
        scaleLastConnectedId: () => null,
        preferredScaleId: () => null,
      );
    });

    tearDown(() async {
      supervisor.dispose();
      statusPublisher.dispose();
      await machineController.close();
    });

    // De1Controller.adoptDevice() unconditionally resets (emits null) before
    // emitting the newly adopted De1Interface, even when re-adopting a
    // machine that was already connected (e.g. a fresh transport object for
    // the same physical USB device). Any automatic reconnect path that
    // drives this churn must hold isConnectingMachine for its duration, or
    // the reset half of the churn reads as an unexpected disconnect.
    test('reset-then-adopt churn while isConnectingMachine is held through a '
        'flush does not surface an error', () async {
      machineController.add(_FakeDe1('de1-1'));
      await Future<void>.delayed(Duration.zero);
      expect(statusPublisher.current.error, isNull);

      connecting = true;
      machineController.add(null);
      machineController.add(_FakeDe1('de1-1'));
      // The churn is delivered asynchronously (broadcast/BehaviorSubject
      // listeners fire via microtasks), so the guard must still be held
      // when this delivery actually happens.
      await Future<void>.delayed(Duration.zero);
      connecting = false;

      expect(
        statusPublisher.current.error,
        isNull,
        reason:
            'internal reset-then-adopt churn while isConnectingMachine is '
            'held must not be reported as an unexpected disconnect',
      );
    });

    test('releasing isConnectingMachine before the churn is delivered still '
        'surfaces a spurious error', () async {
      // A caller that flips the guard back to false immediately after
      // calling adoptDevice(), without first waiting for the de1 stream to
      // actually deliver the churn, gains nothing: the guard is already
      // false by the time DisconnectSupervisor's listener runs. Callers
      // must await the adopted device settling (e.g.
      // de1Controller.de1.firstWhere(...)) before releasing the guard.
      machineController.add(_FakeDe1('de1-1'));
      await Future<void>.delayed(Duration.zero);
      expect(statusPublisher.current.error, isNull);

      connecting = true;
      machineController.add(null);
      machineController.add(_FakeDe1('de1-1'));
      connecting = false; // released without flushing — too early
      await Future<void>.delayed(Duration.zero);

      expect(
        statusPublisher.current.error?.kind,
        ConnectionErrorKind.machineDisconnected,
      );
    });

    test('a null emission while isConnectingMachine is not held is reported as '
        'an unexpected disconnect', () async {
      machineController.add(_FakeDe1('de1-1'));
      await Future<void>.delayed(Duration.zero);
      expect(statusPublisher.current.error, isNull);

      machineController.add(null);
      machineController.add(_FakeDe1('de1-1'));
      await Future<void>.delayed(Duration.zero);

      expect(
        statusPublisher.current.error?.kind,
        ConnectionErrorKind.machineDisconnected,
      );
    });
  });
}
