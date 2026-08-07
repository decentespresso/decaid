import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:web_socket_channel/io.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart' show ConnectionState;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';

/// Bench bug i14 — "the app never reconnects after a power-cycle".
///
/// A machine power-cycle drops the De1 object and builds a NEW one under the
/// SAME device id (the USB stable id is derived from the SAMD21 factory
/// serial, so it is byte-identical across a power-cycle). The machine sockets
/// used to bind to one De1 *instance* at open and never re-bind, so a client
/// that connected before the power-cycle sat on an open-but-silent socket
/// forever.
///
/// These lock the server-side contract: a client that connected BEFORE the
/// swap receives frames from the NEW machine after it, with no client-side
/// action — and exactly one copy of each frame.
void main() {
  late De1Controller de1Controller;
  late HttpServer server;

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();

    de1Controller = De1Controller(controller: deviceController);

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    final de1Handler = De1Handler(
      controller: de1Controller,
      settingsController: settingsController,
      scaleController: ScaleController(),
      workflowController: WorkflowController(),
    );

    final app = Router().plus;
    de1Handler.addRoutes(app);

    server = await io.serve(app.call, 'localhost', 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Uri wsUri(String path) => Uri.parse('ws://localhost:${server.port}$path');

  (IOWebSocketChannel, Stream<Map<String, dynamic>>) connectWs(String path) {
    final channel = IOWebSocketChannel.connect(wsUri(path));
    final messages = channel.stream
        .map((msg) => jsonDecode(msg.toString()) as Map<String, dynamic>)
        .asBroadcastStream();
    // Drain into a broadcast stream eagerly so frames sent before a
    // `.first`/`.take()` is awaited are not dropped.
    messages.listen((_) {});
    return (channel, messages);
  }

  /// Let the WebSocket + rx plumbing settle.
  Future<void> settle([int turns = 6]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The power-cycle, exactly as De1Controller sees it on the bench: the
  /// transport reports `disconnected` (→ `_onDisconnect()` nulls the de1),
  /// then the next scan builds a brand-new instance under the same id.
  Future<TestDe1> powerCycle(TestDe1 old) async {
    old.setConnectionState(ConnectionState.disconnected);
    await settle();
    final fresh = TestDe1(deviceId: old.deviceId, name: old.name);
    await de1Controller.connectToDe1(fresh);
    await settle();
    return fresh;
  }

  MachineSnapshot snapshotAt(double groupTemperature) => MachineSnapshot(
    timestamp: DateTime(2026, 7, 14, 15, 53),
    state: const MachineStateSnapshot(
      state: MachineState.idle,
      substate: MachineSubstate.idle,
    ),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 90,
    groupTemperature: groupTemperature,
    targetMixTemperature: 93,
    targetGroupTemperature: 93,
    profileFrame: 0,
    steamTemperature: 0,
  );

  group('machine snapshot socket survives a machine swap', () {
    test('a client bound before a power-cycle receives frames from the NEW '
        'machine after it', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/snapshot');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();
      expect(received, isNotEmpty, reason: 'the old machine streams');

      final second = await powerCycle(first);
      expect(identical(first, second), isFalse);

      received.clear();
      second.emitSnapshot(snapshotAt(83.09));
      await settle();

      expect(
        received.map((f) => f['groupTemperature']),
        contains(83.09),
        reason: 'the pre-existing socket must re-bind to the new machine',
      );

      await channel.sink.close();
    });

    test(
      'the swapped-in socket is not duplicated (one frame per emit)',
      () async {
        final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(first);

        final (channel, messages) = connectWs('/ws/v1/machine/snapshot');
        final received = <Map<String, dynamic>>[];
        messages.listen(received.add);
        await settle();

        final second = await powerCycle(first);
        // A second power-cycle: three instances have now passed under one socket.
        final third = await powerCycle(second);

        received.clear();
        third.emitSnapshot(snapshotAt(91.5));
        await settle();

        expect(
          received.where((f) => f['groupTemperature'] == 91.5).length,
          1,
          reason:
              'a leaked subscription per swap would multiply the frame rate',
        );

        // The dead instances must have no listener left on them.
        expect(first.snapshotSubject.hasListener, isFalse);
        expect(second.snapshotSubject.hasListener, isFalse);

        await channel.sink.close();
      },
    );

    test('frames from the OLD machine are ignored after the swap', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/snapshot');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();

      await powerCycle(first);

      received.clear();
      first.emitSnapshot(snapshotAt(11.1));
      await settle();

      expect(received, isEmpty);

      await channel.sink.close();
    });

    test(
      'closing the socket cancels the machine subscription (no leak)',
      () async {
        final machine = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(machine);

        final (channel, _) = connectWs('/ws/v1/machine/snapshot');
        await settle();
        expect(machine.snapshotSubject.hasListener, isTrue);

        await channel.sink.close();
        await settle();

        expect(machine.snapshotSubject.hasListener, isFalse);
      },
    );

    test(
      'with no machine connected the socket waits for the first machine',
      () async {
        final (channel, messages) = connectWs('/ws/v1/machine/snapshot');
        final received = <Map<String, dynamic>>[];
        var closed = false;
        messages.listen(received.add, onDone: () => closed = true);

        await settle();
        expect(received, isEmpty);
        expect(closed, isFalse);

        final machine = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(machine);
        await settle();

        received.clear();
        machine.emitSnapshot(snapshotAt(83.09));
        await settle();

        expect(received.map((f) => f['groupTemperature']), contains(83.09));
        await channel.sink.close();
      },
    );
  });

  group('sibling machine sockets survive a machine swap', () {
    test('shotSettings re-binds to the new machine', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/shotSettings');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();

      final second = await powerCycle(first);

      received.clear();
      second.emitShotSettings(
        De1ShotSettings(
          steamSetting: 0,
          targetSteamTemp: 150,
          targetSteamDuration: 30,
          targetHotWaterTemp: 90,
          targetHotWaterVolume: 200,
          targetHotWaterDuration: 30,
          targetShotVolume: 36,
          groupTemp: 92.5,
        ),
      );
      await settle();

      expect(received.map((f) => f['targetSteamTemp']), contains(150));
      await channel.sink.close();
    });

    test('waterLevels re-binds to the new machine', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/waterLevels');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();

      final second = await powerCycle(first);

      received.clear();
      second.emitWaterLevels(
        De1WaterLevels(currentLevel: 42.0, refillLevel: 10.0),
      );
      await settle();

      expect(received.map((f) => f['currentLevel']), contains(42.0));
      await channel.sink.close();
    });
  });

  group('raw WebSocket survives a machine swap', () {
    De1RawMessage rawCommand({
      De1RawMessageType type = De1RawMessageType.request,
      De1RawOperationType operation = De1RawOperationType.read,
      String characteristicUUID = '0x01',
      String payload = '00',
    }) {
      return De1RawMessage(
        type: type,
        operation: operation,
        characteristicUUID: characteristicUUID,
        payload: payload,
      );
    }

    test('a socket opened before a swap receives raw outbound frames from the '
        'replacement machine', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/raw');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();

      final second = await powerCycle(first);

      received.clear();
      second.emitRawMessage(
        rawCommand(
          type: De1RawMessageType.response,
          operation: De1RawOperationType.notify,
          characteristicUUID: '0x36',
          payload: 'deadbeef',
        ),
      );
      await settle();

      expect(
        received.map((f) => f['characteristicUUID']),
        contains('0x36'),
        reason: 'the pre-existing socket must re-bind to the new machine',
      );
      await channel.sink.close();
    });

    test(
      'outbound raw frames from the old machine are ignored after the swap',
      () async {
        final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(first);

        final (channel, messages) = connectWs('/ws/v1/machine/raw');
        final received = <Map<String, dynamic>>[];
        messages.listen(received.add);
        await settle();

        await powerCycle(first);

        received.clear();
        first.emitRawMessage(
          rawCommand(
            type: De1RawMessageType.response,
            operation: De1RawOperationType.notify,
            characteristicUUID: '0x37',
            payload: 'cafe',
          ),
        );
        await settle();

        expect(
          received,
          isEmpty,
          reason: 'frames from the zombie instance must be dropped',
        );
        await channel.sink.close();
      },
    );

    test('repeated swaps do not create duplicate raw subscriptions', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/raw');
      final received = <Map<String, dynamic>>[];
      messages.listen(received.add);
      await settle();

      final second = await powerCycle(first);
      final third = await powerCycle(second);

      received.clear();
      third.emitRawMessage(
        rawCommand(
          type: De1RawMessageType.response,
          operation: De1RawOperationType.notify,
          characteristicUUID: '0x38',
          payload: 'f00d',
        ),
      );
      await settle();

      expect(
        received.where((f) => f['characteristicUUID'] == '0x38').length,
        1,
        reason: 'a leaked subscription per swap would multiply the frame rate',
      );

      // The dead instances must have no listener left on their raw stream.
      expect(first.rawOutSubject.hasListener, isFalse);
      expect(second.rawOutSubject.hasListener, isFalse);

      await channel.sink.close();
    });

    test('an inbound raw request after a swap is delivered exactly once to '
        'the new machine', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/raw');
      messages.listen((_) {});
      await settle();

      final second = await powerCycle(first);

      final command = rawCommand(
        type: De1RawMessageType.request,
        operation: De1RawOperationType.read,
        characteristicUUID: '0x2a',
        payload: '01',
      );
      channel.sink.add(jsonEncode(command.toJson()));
      await settle();

      // The command must reach only the new machine.
      expect(
        second.sentRawMessages,
        hasLength(1),
        reason: 'exactly one command reaches the replacement machine',
      );
      expect(second.sentRawMessages.first.characteristicUUID, '0x2a');

      // The old machine must not receive the command.
      expect(
        first.sentRawMessages,
        isEmpty,
        reason: 'command must not reach the old machine',
      );

      await channel.sink.close();
    });

    test('the inbound request is not delivered to the old machine', () async {
      final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(first);

      final (channel, messages) = connectWs('/ws/v1/machine/raw');
      messages.listen((_) {});
      await settle();

      // Send a command to the first machine before the swap.
      final cmd1 = rawCommand(
        type: De1RawMessageType.request,
        operation: De1RawOperationType.read,
        characteristicUUID: '0x01',
        payload: 'aa',
      );
      channel.sink.add(jsonEncode(cmd1.toJson()));
      await settle();

      expect(
        first.sentRawMessages,
        hasLength(1),
        reason: 'first command reaches the first machine',
      );
      first.sentRawMessages.clear();

      await powerCycle(first);

      // Send a second command after the swap.
      final cmd2 = rawCommand(
        type: De1RawMessageType.request,
        operation: De1RawOperationType.read,
        characteristicUUID: '0x02',
        payload: 'bb',
      );
      channel.sink.add(jsonEncode(cmd2.toJson()));
      await settle();

      // First machine must not receive the second command.
      expect(
        first.sentRawMessages,
        isEmpty,
        reason: 'second command must not reach the old machine',
      );

      await channel.sink.close();
    });

    test('closing the socket removes the raw subscription', () async {
      final machine = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(machine);

      final (channel, _) = connectWs('/ws/v1/machine/raw');
      await settle();

      expect(machine.rawOutSubject.hasListener, isTrue);

      await channel.sink.close();
      await settle();

      // After close, no listener should remain.
      expect(machine.rawOutSubject.hasListener, isFalse);
    });

    test('a command sent immediately after open is handled deterministically '
        'without delay', () async {
      final machine = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
      await de1Controller.connectToDe1(machine);

      final (channel, messages) = connectWs('/ws/v1/machine/raw');
      messages.listen((_) {});

      // Send a command immediately — no settle() before it.
      final command = rawCommand(
        type: De1RawMessageType.request,
        operation: De1RawOperationType.read,
        characteristicUUID: '0x03',
        payload: 'cc',
      );
      channel.sink.add(jsonEncode(command.toJson()));
      await settle();

      expect(
        machine.sentRawMessages,
        hasLength(1),
        reason: 'command must be delivered immediately, no arbitrary delay',
      );
      expect(machine.sentRawMessages.first.characteristicUUID, '0x03');

      await channel.sink.close();
    });

    test(
      'a socket opened before the first machine waits and then attaches',
      () async {
        final (channel, messages) = connectWs('/ws/v1/machine/raw');
        final received = <Map<String, dynamic>>[];
        var closed = false;
        messages.listen(received.add, onDone: () => closed = true);

        await settle();
        expect(received, isEmpty);
        expect(closed, isFalse);

        channel.sink.add(jsonEncode(rawCommand()));
        await settle();

        expect(received, hasLength(1));
        expect(received.single, {'error': 'No machine connected'});
        expect(closed, isFalse);

        final machine = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(machine);
        await settle();

        received.clear();
        machine.emitRawMessage(
          rawCommand(
            type: De1RawMessageType.response,
            operation: De1RawOperationType.notify,
            characteristicUUID: '0x05',
            payload: 'ee',
          ),
        );
        await settle();

        expect(received.map((f) => f['characteristicUUID']), contains('0x05'));
        await channel.sink.close();
      },
    );

    test(
      'a command during the disconnected gap returns an error frame',
      () async {
        final first = TestDe1(deviceId: 'usb-2e8a-a-8549628789ABCDEF');
        await de1Controller.connectToDe1(first);

        final (channel, messages) = connectWs('/ws/v1/machine/raw');
        final received = <Map<String, dynamic>>[];
        messages.listen(received.add);
        await settle();

        first.setConnectionState(ConnectionState.disconnected);
        await settle();

        final command = rawCommand(
          type: De1RawMessageType.request,
          operation: De1RawOperationType.read,
          characteristicUUID: '0x04',
          payload: 'dd',
        );
        channel.sink.add(jsonEncode(command.toJson()));
        await settle();

        // Must see an error frame, not silence.
        final errors = received.where((f) => f['error'] != null);
        expect(
          errors,
          isNotEmpty,
          reason: 'command during disconnect must produce an error frame',
        );
        expect(errors.last['error'], 'No machine connected');

        final second = TestDe1(deviceId: first.deviceId, name: first.name);
        await de1Controller.connectToDe1(second);
        await settle();

        received.removeWhere((f) => f['error'] != null);
        second.emitRawMessage(
          rawCommand(
            type: De1RawMessageType.response,
            operation: De1RawOperationType.notify,
            characteristicUUID: '0x05',
            payload: 'ee',
          ),
        );
        await settle();

        expect(
          received.map((f) => f['characteristicUUID']),
          contains('0x05'),
          reason: 'socket resumes after reconnect',
        );

        await channel.sink.close();
      },
    );
  });
}
