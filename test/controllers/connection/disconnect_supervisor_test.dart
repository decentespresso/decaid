import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/disconnect_expectations.dart';
import 'package:reaprime/src/controllers/connection/disconnect_supervisor.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';

class _FakeDe1 implements De1Interface {
  @override
  final String deviceId;

  _FakeDe1(this.deviceId);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

DisconnectSupervisor _buildSupervisor(
  StreamController<De1Interface?> machineController,
) {
  return DisconnectSupervisor(
    machineStream: machineController.stream,
    scaleStream: const Stream.empty(),
    statusPublisher: StatusPublisher(),
    expectations: DisconnectExpectations(),
    isConnectingMachine: () => false,
    isConnectingScale: () => false,
    scaleLastConnectedId: () => null,
    preferredScaleId: () => null,
  );
}

void main() {
  for (final expected in [false, true]) {
    test(
      'Scale cleanup retains disconnect classification expected=$expected',
      () async {
        final states = StreamController<ConnectionState>();
        final expectations = DisconnectExpectations();
        final publisher = StatusPublisher();
        var recoveries = 0;
        final supervisor = DisconnectSupervisor(
          machineStream: const Stream.empty(),
          scaleStream: states.stream,
          statusPublisher: publisher,
          expectations: expectations,
          isConnectingMachine: () => false,
          isConnectingScale: () => false,
          scaleLastConnectedId: () => 'scale',
          preferredScaleId: () => 'scale',
          onScaleDisconnected: () => recoveries++,
        );
        states.add(ConnectionState.connected);
        await Future<void>.delayed(Duration.zero);
        if (expected) expectations.mark('scale');
        states.add(ConnectionState.disconnecting);
        states.add(ConnectionState.disconnected);
        states.add(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);
        expect(recoveries, expected ? 0 : 1);
        expect(expectations.consume('scale'), isFalse);
        supervisor.dispose();
        expectations.dispose();
        publisher.dispose();
        await states.close();
      },
    );
  }
  group('DisconnectSupervisor.waitForMachine', () {
    late StreamController<De1Interface?> machineController;
    late DisconnectSupervisor supervisor;

    setUp(() {
      machineController = StreamController<De1Interface?>.broadcast();
      supervisor = _buildSupervisor(machineController);
    });

    tearDown(() async {
      supervisor.dispose();
      await machineController.close();
    });

    test('resolves immediately when the device is already current', () async {
      machineController.add(_FakeDe1('de1-1'));
      await Future<void>.delayed(Duration.zero);

      await supervisor
          .waitForMachine('de1-1')
          .timeout(const Duration(milliseconds: 100));
    });

    test('resolves once the awaited device arrives on the stream', () async {
      final future = supervisor.waitForMachine('de1-1');
      var resolved = false;
      unawaited(future.then((_) => resolved = true));

      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);

      machineController.add(_FakeDe1('de1-1'));
      await future.timeout(const Duration(milliseconds: 100));
      expect(resolved, isTrue);
    });

    test(
      'ignores an unrelated device before the awaited one arrives',
      () async {
        final future = supervisor.waitForMachine('de1-2');

        machineController.add(_FakeDe1('de1-1'));
        await Future<void>.delayed(Duration.zero);

        machineController.add(_FakeDe1('de1-2'));
        await future.timeout(const Duration(milliseconds: 100));
      },
    );

    test(
      'dispose resolves a pending wait instead of hanging forever',
      () async {
        final future = supervisor.waitForMachine('de1-1');
        supervisor.dispose();

        await future.timeout(const Duration(milliseconds: 100));
      },
    );
  });
}
