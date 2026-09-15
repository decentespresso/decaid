import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/profile.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

const _fastSettle = Duration(milliseconds: 100);

const _originalV11Status = [0x03, 0x0A, 0x00, 0x00, 0x64, 0x02, 0x00];
const _hdsV258Status = [0x03, 0x0A, 0x00, 0x00, 0x64, 0x02, 0x58];
const _hdsV3114Status = [0x03, 0x0A, 0x00, 0x00, 0x64, 0x03, 0x1E];

class _LifecycleBleTransport extends BLETransport {
  _LifecycleBleTransport({
    this.respondToVoltage = false,
    this.respondToStatus = true,
    this.statusNotification = _originalV11Status,
  });

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);
  ConnectionState _nativeState = ConnectionState.disconnected;
  bool respondToVoltage;
  bool respondToStatus;
  List<int> statusNotification;
  bool failSoftSleep = false;
  bool failDisplayOff = false;
  int softSleepExitFailures = 0;
  final writes = <Uint8List>[];
  void Function(Uint8List)? notificationCallback;
  void Function(Uint8List)? firstNotificationCallback;
  int disconnectCalls = 0;
  int connectCalls = 0;
  int subscribeCalls = 0;
  int resetSubscriptionCalls = 0;
  Completer<void>? blockSoftSleepExit;

  @override
  String get id => 'decent-scale-lifecycle-test';

  @override
  String get name => 'Decent Scale Lifecycle Test';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _nativeState;

  @override
  Future<void> connect() async {
    connectCalls++;
    _nativeState = ConnectionState.connected;
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _nativeState = ConnectionState.disconnected;
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    DecentScale.serviceIdentifier.long,
  ];

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscribeCalls++;
    notificationCallback = callback;
    firstNotificationCallback ??= callback;
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    resetSubscriptionCalls++;
    notificationCallback = callback;
    firstNotificationCallback ??= callback;
  }

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final frame = Uint8List.fromList(data);
    writes.add(frame);
    if (frame.length == 7 &&
        frame[1] == 0x0A &&
        frame[2] == 0x04 &&
        frame[3] == 0x00) {
      final blocker = blockSoftSleepExit;
      if (blocker != null) await blocker.future;
    }
    if (softSleepExitFailures > 0 &&
        frame.length == 7 &&
        frame[1] == 0x0A &&
        frame[2] == 0x04 &&
        frame[3] == 0x00) {
      softSleepExitFailures--;
      throw const DeviceNotConnectedException.scale();
    }
    if (failSoftSleep &&
        frame.length == 7 &&
        frame[1] == 0x0A &&
        frame[2] == 0x04 &&
        frame[3] == 0x01) {
      throw const DeviceNotConnectedException.scale();
    }
    if (failDisplayOff &&
        frame.length == 7 &&
        frame[1] == 0x0A &&
        frame[2] == 0x00) {
      throw const DeviceNotConnectedException.scale();
    }
    if (frame.length == 7 && frame[1] == 0x0A && frame[2] == 0x01) {
      scheduleMicrotask(() {
        if (respondToStatus) {
          emitNotification(statusNotification);
        } else {
          emitNotification([0x03, 0xCE, 0x00, 0x64, 0x00, 0x00, 0x00]);
        }
      });
    }
    if (frame.length == 7 && frame[1] == 0x22 && respondToVoltage) {
      scheduleMicrotask(
        () => emitNotification([0x03, 0x22, 0x00, 0x64, 0x00, 0x00, 0x45]),
      );
    }
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  void emitDisconnected() {
    _nativeState = ConnectionState.disconnected;
    _connectionState.add(ConnectionState.disconnected);
  }

  void emitNotification(List<int> data) {
    notificationCallback?.call(Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    await _connectionState.close();
  }
}

int _countCommand(
  _LifecycleBleTransport transport,
  int command, [
  int? subcommand,
  int? param,
]) => transport.writes
    .where(
      (data) =>
          data.length >= 4 &&
          data[1] == command &&
          (subcommand == null || data[2] == subcommand) &&
          (param == null || data[3] == param),
    )
    .length;

bool _hasCommand(
  _LifecycleBleTransport transport,
  int command, [
  int? subcommand,
  int? param,
]) => _countCommand(transport, command, subcommand, param) > 0;

bool _hasDisplayOff(_LifecycleBleTransport transport) =>
    _hasCommand(transport, 0x0A, 0x00);

int _indexOfCommand(
  _LifecycleBleTransport transport,
  int command, [
  int? subcommand,
  int? param,
]) => transport.writes.indexWhere(
  (data) =>
      data.length >= 4 &&
      data[1] == command &&
      (subcommand == null || data[2] == subcommand) &&
      (param == null || data[3] == param),
);

int _lastIndexOfCommand(
  _LifecycleBleTransport transport,
  int command, [
  int? subcommand,
  int? param,
]) => transport.writes.lastIndexWhere(
  (data) =>
      data.length >= 4 &&
      data[1] == command &&
      (subcommand == null || data[2] == subcommand) &&
      (param == null || data[3] == param),
);

bool _hasSoftSleep(_LifecycleBleTransport transport, [int? param]) =>
    _hasCommand(transport, 0x0A, 0x04, param);

Future<void> _connectAndSettle(
  DecentScale scale, {
  Duration timeout = const Duration(milliseconds: 900),
}) async {
  await scale.onConnect();
  await pumpEventQueue();
  await Future<void>.delayed(timeout);
  await pumpEventQueue();
}

Future<void> _disposeScale(
  DecentScale scale,
  _LifecycleBleTransport transport,
) async {
  await scale.disconnectForHandoff();
  await transport.dispose();
}

Future<void> _reconnectDuringSleep(
  _LifecycleBleTransport transport,
  DecentScale scale,
) async {
  transport.emitDisconnected();
  await pumpEventQueue();
  await scale.onConnect();
  await pumpEventQueue();
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  group('connected display-off lifecycle', () {
    test('original v1.1 uses shared display off and stays connected', () async {
      final transport = _LifecycleBleTransport();
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      expect(
        scale.debugProfile.identity,
        DecentScaleIdentity.originalDecentScale,
      );
      expect(scale.debugProfile.originalFirmwareVersion, '1.1');
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isFalse);
      expect(_hasCommand(transport, 0x22), isTrue);
      transport.writes.clear();

      await scale.sleepDisplay();

      expect(_hasDisplayOff(transport), isTrue);
      expect(_hasSoftSleep(transport), isFalse);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);

      final connectsBeforeWake = transport.connectCalls;
      await scale.wakeDisplay();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
      expect(_hasSoftSleep(transport), isFalse);
      expect(transport.connectCalls, connectsBeforeWake);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test('unknown scale uses display off and stays connected', () async {
      final transport = _LifecycleBleTransport(respondToStatus: false);
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      expect(scale.debugProfile.identity, DecentScaleIdentity.unknown);
      transport.writes.clear();

      await scale.sleepDisplay();

      expect(_hasDisplayOff(transport), isTrue);
      expect(_hasSoftSleep(transport), isFalse);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test('HDS without proven SoftSleep uses display off', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV258Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      expect(scale.debugProfile.identity, DecentScaleIdentity.halfDecentScale);
      expect(
        scale.debugProfile.capabilities.supportsHdsExtendedCommands,
        isTrue,
      );
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isFalse);
      transport.writes.clear();

      await scale.sleepDisplay();

      expect(_hasDisplayOff(transport), isTrue);
      expect(_hasSoftSleep(transport), isFalse);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test(
      'modern HDS enters SoftSleep and wakes on the same connection',
      () async {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale);

        expect(scale.debugProfile.capabilities.supportsSoftSleep, isTrue);
        transport.writes.clear();

        await scale.sleepDisplay();

        expect(_hasSoftSleep(transport, 0x01), isTrue);
        expect(_hasDisplayOff(transport), isFalse);
        expect(transport.disconnectCalls, 0);
        expect(await transport.getConnectionState(), ConnectionState.connected);

        final connectsBeforeWake = transport.connectCalls;
        transport.writes.clear();
        await scale.wakeDisplay();
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(_hasSoftSleep(transport, 0x00), isTrue);
        expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
        expect(transport.connectCalls, connectsBeforeWake);
        expect(transport.disconnectCalls, 0);
        expect(await transport.getConnectionState(), ConnectionState.connected);
        await _disposeScale(scale, transport);
      },
    );

    test('failed HDS SoftSleep falls back to display off', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isTrue);
      transport.failSoftSleep = true;
      transport.writes.clear();

      await scale.sleepDisplay();

      expect(_hasSoftSleep(transport, 0x01), isTrue);
      expect(_hasDisplayOff(transport), isTrue);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test('failed HDS SoftSleep still exits SoftSleep on wake', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale, timeout: _fastSettle);
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isTrue);
      transport.failSoftSleep = true;
      transport.writes.clear();

      await scale.sleepDisplay();
      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final exitIndex = _indexOfCommand(transport, 0x0A, 0x04, 0x00);
      final ledIndex = _indexOfCommand(transport, 0x0A, 0x01);
      expect(exitIndex, greaterThanOrEqualTo(0));
      expect(ledIndex, greaterThanOrEqualTo(0));
      expect(exitIndex, lessThan(ledIndex));
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test('a failed SoftSleep exit is retried within the same wake', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale, timeout: _fastSettle);
      await scale.sleepDisplay();

      transport.softSleepExitFailures = 1;
      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();

      final ledIndex = _indexOfCommand(transport, 0x0A, 0x01);
      expect(_countCommand(transport, 0x0A, 0x04, 0x00), 2);
      expect(ledIndex, greaterThanOrEqualTo(0));
      expect(
        _lastIndexOfCommand(transport, 0x0A, 0x04, 0x00),
        lessThan(ledIndex),
      );
      expect(transport.disconnectCalls, 0);

      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();
      expect(_countCommand(transport, 0x0A, 0x04, 0x00), 0);
      await _disposeScale(scale, transport);
    });

    test('exhausted SoftSleep exit attempts keep the obligation', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale, timeout: _fastSettle);
      await scale.sleepDisplay();

      transport.softSleepExitFailures = 5;
      transport.writes.clear();
      await expectLater(scale.wakeDisplay(), throwsA(isA<Exception>()));
      await pumpEventQueue();

      expect(_countCommand(transport, 0x0A, 0x04, 0x00), 2);
      expect(_countCommand(transport, 0x0A, 0x01), 0);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);

      transport.softSleepExitFailures = 0;
      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();

      final exitIndex = _indexOfCommand(transport, 0x0A, 0x04, 0x00);
      final ledIndex = _indexOfCommand(transport, 0x0A, 0x01);
      expect(exitIndex, greaterThanOrEqualTo(0));
      expect(ledIndex, greaterThanOrEqualTo(0));
      expect(exitIndex, lessThan(ledIndex));
      await _disposeScale(scale, transport);
    });

    test('a superseding sleep cancels the SoftSleep exit retry', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale, timeout: _fastSettle);
      await scale.sleepDisplay();

      transport.softSleepExitFailures = 5;
      transport.writes.clear();
      var wakeCompleted = false;
      final wake = scale.wakeDisplay().whenComplete(() => wakeCompleted = true);
      await pumpEventQueue();
      expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);
      expect(wakeCompleted, isFalse);
      await scale.sleepDisplay();
      expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);
      await wake;

      expect(_countCommand(transport, 0x0A, 0x01), 0);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test(
      'a superseding sleep during a pending exit cancels the wake',
      () async {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale, timeout: _fastSettle);
        await scale.sleepDisplay();

        transport.emitDisconnected();
        await pumpEventQueue();
        await scale.onConnect();
        await pumpEventQueue();

        final exitWrite = Completer<void>();
        transport.blockSoftSleepExit = exitWrite;
        transport.writes.clear();
        var wakeCompleted = false;
        final wake = scale.wakeDisplay().whenComplete(
          () => wakeCompleted = true,
        );
        await pumpEventQueue();
        expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);
        expect(wakeCompleted, isFalse);

        final subscribes = transport.subscribeCalls;
        final resets = transport.resetSubscriptionCalls;
        final disconnects = transport.disconnectCalls;
        await scale.sleepDisplay();
        exitWrite.complete();
        await wake;
        transport.blockSoftSleepExit = null;

        expect(transport.subscribeCalls, subscribes);
        expect(transport.resetSubscriptionCalls, resets);
        expect(transport.disconnectCalls, disconnects);
        expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);
        expect(_countCommand(transport, 0x0A, 0x01), 0);
        expect(await transport.getConnectionState(), ConnectionState.connected);
        await _disposeScale(scale, transport);
      },
    );

    test(
      'latest wake wins after wake-sleep-wake during a pending exit',
      () async {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale, timeout: _fastSettle);
        await scale.sleepDisplay();

        final exitWrite = Completer<void>();
        transport.blockSoftSleepExit = exitWrite;
        transport.writes.clear();
        final firstWake = scale.wakeDisplay();
        await pumpEventQueue();
        expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);

        await scale.sleepDisplay();
        var latestWakeCompleted = false;
        final latestWake = scale.wakeDisplay().whenComplete(
          () => latestWakeCompleted = true,
        );
        await pumpEventQueue();
        expect(latestWakeCompleted, isFalse);

        exitWrite.complete();
        transport.blockSoftSleepExit = null;
        await Future.wait([firstWake, latestWake]);
        await pumpEventQueue();

        expect(latestWakeCompleted, isTrue);
        expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
        expect(await transport.getConnectionState(), ConnectionState.connected);
        await _disposeScale(scale, transport);
      },
    );

    test(
      'exhausted exit does not fake a reconnect on the next same-connection wake',
      () async {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale, timeout: _fastSettle);
        await scale.sleepDisplay();

        transport.softSleepExitFailures = 5;
        await expectLater(scale.wakeDisplay(), throwsA(isA<Exception>()));
        await pumpEventQueue();

        transport.softSleepExitFailures = 0;
        transport.writes.clear();
        final subscribes = transport.subscribeCalls;
        final resets = transport.resetSubscriptionCalls;
        await scale.wakeDisplay();
        await pumpEventQueue();

        expect(transport.subscribeCalls, subscribes);
        expect(transport.resetSubscriptionCalls, resets);
        expect(_countCommand(transport, 0x0A, 0x04, 0x00), 1);
        await _disposeScale(scale, transport);
      },
    );

    test('sleep after a failed exit keeps the obligation', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale, timeout: _fastSettle);
      await scale.sleepDisplay();

      transport.softSleepExitFailures = 2;
      await expectLater(scale.wakeDisplay(), throwsA(isA<Exception>()));
      await pumpEventQueue();

      transport.respondToVoltage = false;
      transport.emitDisconnected();
      await pumpEventQueue();
      await scale.onConnect();
      await pumpEventQueue();
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isFalse);

      await scale.sleepDisplay();
      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();

      expect(_hasSoftSleep(transport, 0x00), isTrue);
      await _disposeScale(scale, transport);
    });

    test('failed display off keeps the connection', () async {
      final transport = _LifecycleBleTransport()..failDisplayOff = true;
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      transport.writes.clear();

      await scale.sleepDisplay();

      expect(_hasDisplayOff(transport), isTrue);
      expect(transport.disconnectCalls, 0);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test(
      'repeated display-off and wake cycles keep the same connection',
      () async {
        final transport = _LifecycleBleTransport();
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale);
        final connectsBefore = transport.connectCalls;
        final disconnectsBefore = transport.disconnectCalls;

        for (var cycle = 0; cycle < 3; cycle++) {
          transport.writes.clear();
          await scale.sleepDisplay();
          await pumpEventQueue();
          expect(_hasDisplayOff(transport), isTrue);
          expect(_hasSoftSleep(transport), isFalse);

          await scale.wakeDisplay();
          await pumpEventQueue();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
        }

        expect(transport.connectCalls, connectsBefore);
        expect(transport.disconnectCalls, disconnectsBefore);
        expect(await transport.getConnectionState(), ConnectionState.connected);
        await _disposeScale(scale, transport);
      },
    );
  });

  group('reconnect and evidence fencing', () {
    test('reconnect during display off attaches dark and wakes', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      final disconnectsBeforeSleep = transport.disconnectCalls;
      await scale.sleepDisplay();
      await pumpEventQueue();
      expect(transport.disconnectCalls, disconnectsBeforeSleep);

      await _reconnectDuringSleep(transport, scale);
      expect(transport.disconnectCalls, disconnectsBeforeSleep + 1);

      transport.writes.clear();
      await scale.wakeDisplay();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(_hasCommand(transport, 0x0A, 0x01), isTrue);
      expect(transport.disconnectCalls, disconnectsBeforeSleep + 1);
      expect(await transport.getConnectionState(), ConnectionState.connected);
      await _disposeScale(scale, transport);
    });

    test(
      'reconnect during SoftSleep exits before confirming the channel',
      () async {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale, timeout: _fastSettle);
        await scale.sleepDisplay();

        transport.emitDisconnected();
        await pumpEventQueue();
        await scale.onConnect();
        transport.writes.clear();
        await scale.wakeDisplay();
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final exitIndex = _indexOfCommand(transport, 0x0A, 0x04, 0x00);
        final ledIndex = _indexOfCommand(transport, 0x0A, 0x01);
        expect(exitIndex, greaterThanOrEqualTo(0));
        expect(ledIndex, greaterThanOrEqualTo(0));
        expect(exitIndex, lessThan(ledIndex));
        await _disposeScale(scale, transport);
      },
    );

    test(
      'stale subscription evidence cannot promote a newer attempt',
      () async {
        final transport = _LifecycleBleTransport(respondToStatus: false);
        final scale = DecentScale(transport: transport);
        await scale.onConnect();
        await pumpEventQueue();
        final staleCallback = transport.firstNotificationCallback!;

        await scale.sleepDisplay();
        await _reconnectDuringSleep(transport, scale);

        staleCallback(
          Uint8List.fromList([0x03, 0x22, 0x01, 0x89, 0x00, 0x00, 0xA9]),
        );
        await pumpEventQueue();

        expect(scale.debugProfile.identity, DecentScaleIdentity.unknown);
        await scale.wakeDisplay();
        await pumpEventQueue();
        await _disposeScale(scale, transport);
      },
    );

    test('profile does not leak across connections', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isTrue);
      await scale.disconnectForHandoff();

      transport.respondToVoltage = false;
      transport.statusNotification = _originalV11Status;
      transport.writes.clear();
      await _connectAndSettle(scale);

      expect(scale.debugProfile.capabilities.supportsSoftSleep, isFalse);
      transport.writes.clear();
      await scale.sleepDisplay();

      expect(_hasSoftSleep(transport), isFalse);
      expect(_hasDisplayOff(transport), isTrue);
      expect(transport.disconnectCalls, 1);
      await _disposeScale(scale, transport);
    });

    test(
      'explicit disconnect withholds power off from an unproven scale',
      () async {
        final transport = _LifecycleBleTransport();
        final scale = DecentScale(transport: transport);
        await _connectAndSettle(scale);
        transport.writes.clear();

        await scale.disconnect();

        expect(_hasCommand(transport, 0x0A, 0x02), isFalse);
        expect(transport.disconnectCalls, 1);
        await transport.dispose();
      },
    );
  });

  group('command and maintenance safety', () {
    test('no heartbeat is sent by lifecycle or scale commands', () async {
      final transport = _LifecycleBleTransport(
        respondToVoltage: true,
        statusNotification: _hdsV3114Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndSettle(scale);

      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      await scale.sleepDisplay();
      await scale.wakeDisplay();
      await pumpEventQueue();

      expect(_hasCommand(transport, 0x0A, 0x03), isFalse);
      expect(
        transport.writes
            .where((data) => data.length >= 6 && data[1] == 0x0A)
            .every((data) => data[5] == 0x00),
        isTrue,
      );
      expect(
        transport.writes,
        contains(orderedEquals([0x03, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x0C])),
      );
      await _disposeScale(scale, transport);
    });

    test('maintenance is read-only', () {
      fakeAsync((async) {
        final transport = _LifecycleBleTransport(
          respondToVoltage: true,
          statusNotification: _hdsV3114Status,
        );
        final scale = DecentScale(transport: transport);
        var connected = false;
        scale.onConnect().then((_) => connected = true);
        async.flushMicrotasks();
        expect(connected, isTrue);
        transport.writes.clear();

        for (var tick = 0; tick < 15; tick++) {
          async.elapse(const Duration(seconds: 4));
          async.flushMicrotasks();
          transport.emitNotification([
            0x03,
            0xCE,
            0x00,
            0x64,
            0x00,
            0x00,
            0x00,
          ]);
          async.flushMicrotasks();
        }

        expect(transport.writes, isEmpty);
        expect(transport.disconnectCalls, 0);
        expect(connected, isTrue);
        scale.disconnectForHandoff();
        async.flushMicrotasks();
        transport.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
