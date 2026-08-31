import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/skale/skale2_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _RecordableBleTransport extends BLETransport {
  List<String> serviceUUIDs = const [
    '0000ff08-0000-1000-8000-00805f9b34fb',
    '0000180a-0000-1000-8000-00805f9b34fb',
    '0000180f-0000-1000-8000-00805f9b34fb',
  ];

  final List<String> operations = [];

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  final Map<String, void Function(Uint8List)> _notifyCallbacks = {};

  Uint8List firmwareValue = Uint8List.fromList('R029'.codeUnits);
  Object? firmwareError;
  Completer<Uint8List>? firmwareReadCompleter;
  int firmwareReadCount = 0;
  ConnectionState? connectionStateOverride;
  Uint8List batteryValue = Uint8List.fromList([80]);
  Object? batteryError;
  Completer<Uint8List>? batteryReadCompleter;
  int batteryReadCount = 0;

  _RecordableBleTransport();

  @override
  String get id => 'skale2-test-device';

  @override
  String get name => 'Test Skale2';

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionState.stream.map((state) => connectionStateOverride ?? state);

  Future<void> emitConnectionState(ConnectionState state) async {
    _connectionState.add(state);
  }

  @override
  Future<ConnectionState> getConnectionState() async => _connectionState.value;

  @override
  Future<void> connect() async {
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => serviceUUIDs;

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    operations.add('subscribe:$shortUuid');
    _notifyCallbacks[shortUuid] = callback;
  }

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    operations.add('read:$shortUuid');
    if (shortUuid == '2a26') {
      firmwareReadCount++;
      if (firmwareError != null) throw firmwareError!;
      if (firmwareReadCompleter != null) {
        return firmwareReadCompleter!.future;
      }
      return firmwareValue;
    }
    if (shortUuid == '2a19') {
      batteryReadCount++;
      if (batteryError != null) throw batteryError!;
      if (batteryReadCompleter != null) return batteryReadCompleter!.future;
      return batteryValue;
    }
    return Uint8List(0);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final shortUuid = characteristicUUID.substring(4, 8).toLowerCase();
    final hexData = data
        .map((b) => '0x${b.toRadixString(16).toUpperCase()}')
        .join(',');
    operations.add('write:$shortUuid:[$hexData]');
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async {
    _connectionState.close();
  }

  void simulateWeightNotification(List<int> data) {
    _notifyCallbacks['ef81']?.call(Uint8List.fromList(data));
  }

  void simulateButtonNotification(List<int> data) {
    _notifyCallbacks['ef82']?.call(Uint8List.fromList(data));
  }

  bool isSubscribed(String shortUuid) =>
      _notifyCallbacks.containsKey(shortUuid.toLowerCase());

  void clearSubscriptions() {
    _notifyCallbacks.clear();
  }
}

void main() {
  group('Skale2Scale initialization sequence', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
    });

    test(
      'LCD ON (0xED) is sent before subscribing to weight notifications',
      () async {
        await scale.onConnect();

        final lcdOnIndex = transport.operations.indexWhere(
          (op) => op.contains('write:ef80:[0xED]'),
        );
        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );

        expect(lcdOnIndex, isNot(equals(-1)), reason: 'LCD ON should be sent');
        expect(
          weightSubIndex,
          isNot(equals(-1)),
          reason: 'weight should be subscribed',
        );
        expect(
          lcdOnIndex,
          lessThan(weightSubIndex),
          reason:
              'LCD ON must be sent before subscribing to weight notifications',
        );
      },
    );

    test(
      'LCD ON (0xEC display weight) is sent before subscribing to weight notifications',
      () async {
        await scale.onConnect();

        final displayWeightIndex = transport.operations.indexWhere(
          (op) => op.contains('write:ef80:[0xEC]'),
        );
        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );

        expect(
          displayWeightIndex,
          isNot(equals(-1)),
          reason: 'Display weight should be sent',
        );
        expect(
          weightSubIndex,
          isNot(equals(-1)),
          reason: 'weight should be subscribed',
        );
        expect(
          displayWeightIndex,
          lessThan(weightSubIndex),
          reason:
              'Display weight command must be sent before subscribing to weight',
        );
      },
    );

    test(
      'button notifications are subscribed after weight notifications',
      () async {
        await scale.onConnect();

        final weightSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef81',
        );
        final buttonSubIndex = transport.operations.indexWhere(
          (op) => op == 'subscribe:ef82',
        );

        expect(weightSubIndex, isNot(equals(-1)));
        expect(buttonSubIndex, isNot(equals(-1)));
        expect(
          weightSubIndex,
          lessThan(buttonSubIndex),
          reason: 'Button subscription should come after weight subscription',
        );
      },
    );

    test(
      'LCD ON is sent a second time after all subscriptions (double-send)',
      () async {
        await scale.onConnect();

        final lcdOnCount = transport.operations
            .where((op) => op.contains('write:ef80:[0xED]'))
            .length;

        expect(
          lcdOnCount,
          greaterThanOrEqualTo(2),
          reason:
              'LCD ON should be sent at least twice (de1app double-send pattern)',
        );
      },
    );

    test('grams command (0x03) is sent after the second LCD ON', () async {
      await scale.onConnect();

      final gramsIndex = transport.operations.indexWhere(
        (op) => op.contains('write:ef80:[0x3]'),
      );
      final lcdOnIndices = transport.operations
          .asMap()
          .entries
          .where((e) => e.value.contains('write:ef80:[0xED]'))
          .map((e) => e.key)
          .toList();

      expect(
        gramsIndex,
        isNot(equals(-1)),
        reason: 'grams command should be sent',
      );
      expect(
        lcdOnIndices.length,
        greaterThanOrEqualTo(2),
        reason: 'LCD ON should be sent at least twice',
      );
      expect(
        gramsIndex,
        greaterThan(lcdOnIndices.last),
        reason: 'grams command should come after the second LCD ON',
      );
    });

    test(
      'button notifications are not best-effort — subscription is explicit',
      () async {
        await scale.onConnect();

        expect(
          transport.isSubscribed('ef82'),
          isTrue,
          reason:
              'Button notifications must be subscribed, not silently skipped',
        );
      },
    );
  });

  group('Skale2Scale wakeDisplay re-subscribes notifications', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
      transport.operations.clear();
    });

    test('wakeDisplay sends LCD ON (0xED) and display weight (0xEC)', () async {
      await scale.wakeDisplay();

      expect(transport.operations.any((op) => op.contains('0xED')), isTrue);
      expect(transport.operations.any((op) => op.contains('0xEC')), isTrue);
    });

    test('wakeDisplay re-subscribes to weight notifications', () async {
      await transport.emitConnectionState(ConnectionState.disconnected);
      transport.clearSubscriptions();

      await scale.wakeDisplay();

      expect(
        transport.operations.any((op) => op == 'subscribe:ef81'),
        isTrue,
        reason: 'wakeDisplay should re-subscribe to weight notifications',
      );
      expect(
        transport.isSubscribed('ef81'),
        isTrue,
        reason: 'weight subscription should be active after wake',
      );
    });

    test('wakeDisplay re-subscribes to button notifications', () async {
      await transport.emitConnectionState(ConnectionState.disconnected);
      transport.clearSubscriptions();

      await scale.wakeDisplay();

      expect(
        transport.operations.any((op) => op == 'subscribe:ef82'),
        isTrue,
        reason: 'wakeDisplay should re-subscribe to button notifications',
      );
      expect(
        transport.isSubscribed('ef82'),
        isTrue,
        reason: 'button subscription should be active after wake',
      );
    });

    test(
      'wakeDisplay does NOT re-subscribe if subscriptions are still active',
      () async {
        await scale.wakeDisplay();

        expect(
          transport.operations.any((op) => op == 'subscribe:ef81'),
          isFalse,
          reason:
              'wakeDisplay should not redundantly subscribe if already active',
        );
        expect(
          transport.operations.any((op) => op == 'subscribe:ef82'),
          isFalse,
          reason:
              'wakeDisplay should not redundantly subscribe if already active',
        );
      },
    );
  });

  group('Skale2Scale timer commands', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
      transport.operations.clear();
    });

    test('startTimer sends 0xDD', () async {
      await scale.startTimer();
      expect(transport.operations.any((op) => op.contains('0xDD')), isTrue);
    });

    test('stopTimer sends 0xD1', () async {
      await scale.stopTimer();
      expect(transport.operations.any((op) => op.contains('0xD1')), isTrue);
    });

    test('resetTimer sends 0xD0', () async {
      await scale.resetTimer();
      expect(transport.operations.any((op) => op.contains('0xD0')), isTrue);
    });
  });

  group('Skale2Scale weight notification parsing', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();
    });

    test('parses weight notification correctly', () async {
      final completer = Completer<ScaleSnapshot>();

      final sub = scale.currentSnapshot.listen((snapshot) {
        if (!completer.isCompleted) completer.complete(snapshot);
      });

      transport.simulateWeightNotification([0x00, 0xE8, 0x03, 0x00]);

      final snapshot = await completer.future.timeout(
        const Duration(seconds: 1),
      );

      expect(snapshot.weight, closeTo(100.0, 0.1));

      await sub.cancel();
    });

    test(
      'parses SDK 5-byte fractional weight (00 D2 04 00 FE -> 12.34)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xD2, 0x04, 0x00, 0xFE]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(12.34, 0.001));

        await sub.cancel();
      },
    );

    test(
      'parses SDK 5-byte negative weight (00 C9 FD FF FF -> -56.7)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xC9, 0xFD, 0xFF, 0xFF]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(-56.7, 0.001));

        await sub.cancel();
      },
    );

    test(
      'parses SDK 5-byte positive exponent (00 7B 00 00 01 -> 1230.0)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0x7B, 0x00, 0x00, 0x01]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(1230.0, 0.001));

        await sub.cancel();
      },
    );

    test(
      'parses SDK 5-byte common exponent -1 (00 E8 03 00 FF -> 100.0)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xE8, 0x03, 0x00, 0xFF]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(100.0, 0.001));

        await sub.cancel();
      },
    );

    test('parses legacy four-byte frame (00 0A 00 00 -> 1.0)', () async {
      final completer = Completer<ScaleSnapshot>();
      final sub = scale.currentSnapshot.listen((snapshot) {
        if (!completer.isCompleted) completer.complete(snapshot);
      });

      transport.simulateWeightNotification([0x00, 0x0A, 0x00, 0x00]);

      final snapshot = await completer.future.timeout(
        const Duration(seconds: 1),
      );

      expect(snapshot.weight, closeTo(1.0, 0.001));

      await sub.cancel();
    });

    test('ignores truncated three-byte frame (no snapshot)', () async {
      var emissions = 0;
      final sub = scale.currentSnapshot.listen((_) => emissions++);

      transport.simulateWeightNotification([0x00, 0xD2, 0x04]);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(emissions, 0);

      await sub.cancel();
    });

    test('ignores oversized six-byte frame (no snapshot)', () async {
      var emissions = 0;
      final sub = scale.currentSnapshot.listen((_) => emissions++);

      transport.simulateWeightNotification([
        0x00,
        0xE8,
        0x03,
        0x00,
        0xFF,
        0x00,
      ]);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(emissions, 0);

      await sub.cancel();
    });
  });

  group('Skale2Scale firmware information', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      transport.serviceUUIDs = const [
        '0000ff08-0000-1000-8000-00805f9b34fb',
        '0000180a-0000-1000-8000-00805f9b34fb',
      ];
      scale = Skale2Scale(transport: transport, initStepDelay: Duration.zero);
      await transport.emitConnectionState(ConnectionState.discovered);
    });

    test('publishes the connected Skale firmware revision', () async {
      transport.firmwareValue = Uint8List.fromList(' R029\u0000'.codeUnits);

      await scale.onConnect();

      expect(scale.currentDeviceInformation?.firmwareVersion, 'R029');
      expect(transport.firmwareReadCount, 1);
    });

    test(
      'initializes metadata when the transport is already connected',
      () async {
        await transport.emitConnectionState(ConnectionState.connected);

        await scale.onConnect();

        expect(scale.currentDeviceInformation?.firmwareVersion, 'R029');
        expect(transport.isSubscribed('ef81'), isTrue);
        expect(await scale.connectionState.first, ConnectionState.connected);
      },
    );

    test('skips firmware read when Device Information is absent', () async {
      transport.serviceUUIDs = const ['0000ff08-0000-1000-8000-00805f9b34fb'];

      await scale.onConnect();

      expect(transport.firmwareReadCount, 0);
      expect(scale.currentDeviceInformation, isNull);
      expect(await scale.connectionState.first, ConnectionState.connected);
    });

    test('ignores empty and malformed firmware values', () async {
      for (final value in [
        Uint8List(0),
        Uint8List.fromList([0xFF]),
        Uint8List.fromList('R0\u000029'.codeUnits),
      ]) {
        transport.firmwareValue = value;
        await scale.onConnect();

        expect(scale.currentDeviceInformation, isNull);

        await scale.disconnect();
        await transport.emitConnectionState(ConnectionState.discovered);
      }
    });

    test('firmware read failure does not fail connection', () async {
      transport.firmwareError = StateError('unsupported');

      await scale.onConnect();

      expect(scale.currentDeviceInformation, isNull);
      expect(await scale.connectionState.first, ConnectionState.connected);
    });

    test('disconnect clears connected-session firmware', () async {
      await scale.onConnect();
      expect(scale.currentDeviceInformation?.firmwareVersion, 'R029');

      await scale.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(scale.currentDeviceInformation, isNull);
      expect(await scale.connectionState.first, ConnectionState.disconnected);
    });

    test(
      'disconnect during firmware read cannot restore stale metadata',
      () async {
        final firmwareRead = Completer<Uint8List>();
        transport.firmwareReadCompleter = firmwareRead;

        final connecting = scale.onConnect();
        while (transport.firmwareReadCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        await transport.emitConnectionState(ConnectionState.disconnected);
        firmwareRead.complete(Uint8List.fromList('R029'.codeUnits));
        await connecting;

        expect(scale.currentDeviceInformation, isNull);
        expect(await scale.connectionState.first, ConnectionState.disconnected);
      },
    );

    test(
      'does not publish after transport disconnects before its event arrives',
      () async {
        final firmwareRead = Completer<Uint8List>();
        transport.firmwareReadCompleter = firmwareRead;

        final connecting = scale.onConnect();
        while (transport.firmwareReadCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        transport.connectionStateOverride = ConnectionState.disconnected;
        firmwareRead.complete(Uint8List.fromList('R029'.codeUnits));
        await connecting;

        expect(scale.currentDeviceInformation, isNull);
      },
    );

    test('late firmware read cannot overwrite a reconnected session', () async {
      final firstRead = Completer<Uint8List>();
      transport.firmwareReadCompleter = firstRead;

      final firstConnection = scale.onConnect();
      while (transport.firmwareReadCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      await transport.emitConnectionState(ConnectionState.disconnected);
      transport.firmwareReadCompleter = null;
      transport.firmwareValue = Uint8List.fromList('R030'.codeUnits);
      await transport.emitConnectionState(ConnectionState.discovered);
      await scale.onConnect();

      firstRead.complete(Uint8List.fromList('R029'.codeUnits));
      await firstConnection;

      expect(scale.currentDeviceInformation?.firmwareVersion, 'R030');
      expect(await scale.connectionState.first, ConnectionState.connected);
    });
  });

  group('Skale2Scale battery information', () {
    late _RecordableBleTransport transport;
    late Skale2Scale scale;

    setUp(() async {
      transport = _RecordableBleTransport();
      transport.serviceUUIDs = const [
        '0000ff08-0000-1000-8000-00805f9b34fb',
        '0000180f-0000-1000-8000-00805f9b34fb',
      ];
      scale = Skale2Scale(
        transport: transport,
        initStepDelay: Duration.zero,
        batteryRefreshInterval: const Duration(milliseconds: 10),
      );
      await transport.emitConnectionState(ConnectionState.discovered);
    });

    tearDown(() async {
      await scale.disconnect();
      await transport.dispose();
    });

    test('publishes valid zero and full battery values', () async {
      for (final value in [0, 100]) {
        transport.batteryValue = Uint8List.fromList([value]);
        await scale.onConnect();
        expect(scale.currentDeviceInformation?.batteryLevel, value);
        await scale.disconnect();
        await transport.emitConnectionState(ConnectionState.discovered);
      }
    });

    test('invalid and failed reads publish no battery percentage', () async {
      for (final value in [
        Uint8List(0),
        Uint8List.fromList([101]),
        Uint8List.fromList([1, 2]),
      ]) {
        transport.batteryValue = value;
        await scale.onConnect();
        expect(scale.currentDeviceInformation, isNull);
        await scale.disconnect();
        await transport.emitConnectionState(ConnectionState.discovered);
      }

      transport.batteryError = StateError('unsupported');
      await scale.onConnect();
      expect(scale.currentDeviceInformation, isNull);
    });

    test('a later invalid refresh clears the previous percentage', () async {
      transport.batteryValue = Uint8List.fromList([82]);
      await scale.onConnect();
      expect(scale.currentDeviceInformation?.batteryLevel, 82);

      transport.batteryValue = Uint8List.fromList([101]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(scale.currentDeviceInformation?.batteryLevel, isNull);
      expect(transport.batteryReadCount, greaterThanOrEqualTo(2));
    });

    test('refresh reads do not overlap', () async {
      await scale.onConnect();
      final read = Completer<Uint8List>();
      transport.batteryReadCompleter = read;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(transport.batteryReadCount, 2);
      read.complete(Uint8List.fromList([80]));
      await Future<void>.delayed(Duration.zero);
    });

    test('does not poll when the Battery Service is absent', () async {
      transport.serviceUUIDs = const ['0000ff08-0000-1000-8000-00805f9b34fb'];
      await scale.onConnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(transport.batteryReadCount, 0);
      expect(scale.currentDeviceInformation, isNull);
    });

    test(
      'USB override clears battery and reports manual power source',
      () async {
        await scale.onConnect();
        expect(scale.currentDeviceInformation?.batteryLevel, 80);

        await scale.setUsbPowered(true);
        expect(scale.currentDeviceInformation?.batteryLevel, isNull);
        expect(
          scale.currentDeviceInformation?.powerSource,
          DevicePowerSource.usb,
        );
        expect(
          scale.currentDeviceInformation?.powerSourceProvenance,
          DevicePowerSourceProvenance.manualOverride,
        );
        final reads = transport.batteryReadCount;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(transport.batteryReadCount, reads);
      },
    );

    test(
      'USB override can be selected before connecting without battery data',
      () async {
        transport.serviceUUIDs = const ['0000ff08-0000-1000-8000-00805f9b34fb'];
        await scale.setUsbPowered(true);
        await scale.onConnect();

        expect(transport.batteryReadCount, 0);
        expect(scale.currentDeviceInformation?.batteryLevel, isNull);
        expect(
          scale.currentDeviceInformation?.powerSourceProvenance,
          DevicePowerSourceProvenance.manualOverride,
        );
      },
    );

    test('disabling USB override immediately refreshes battery', () async {
      await scale.onConnect();
      await scale.setUsbPowered(true);
      transport.batteryValue = Uint8List.fromList([82]);
      await scale.setUsbPowered(false);
      expect(scale.currentDeviceInformation?.batteryLevel, 82);
      expect(scale.currentDeviceInformation?.powerSource, isNull);
    });

    test(
      'USB override does not affect scales without battery service',
      () async {
        transport.serviceUUIDs = const ['0000ff08-0000-1000-8000-00805f9b34fb'];
        await scale.onConnect();
        await scale.setUsbPowered(true);
        expect(
          scale.currentDeviceInformation?.powerSource,
          DevicePowerSource.usb,
        );
        expect(transport.batteryReadCount, 0);
      },
    );

    test('USB override blocks a stale battery read', () async {
      final read = Completer<Uint8List>();
      transport.batteryReadCompleter = read;
      final connecting = scale.onConnect();
      while (transport.batteryReadCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await scale.setUsbPowered(true);
      read.complete(Uint8List.fromList([82]));
      await connecting;
      expect(scale.currentDeviceInformation?.batteryLevel, isNull);
      expect(
        scale.currentDeviceInformation?.powerSource,
        DevicePowerSource.usb,
      );
    });

    test('disable waits for stale read, then performs a fresh read', () async {
      final firstRead = Completer<Uint8List>();
      transport.batteryReadCompleter = firstRead;
      final connecting = scale.onConnect();
      while (transport.batteryReadCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      await scale.setUsbPowered(true);
      final disabling = scale.setUsbPowered(false);
      transport.batteryReadCompleter = null;
      transport.batteryValue = Uint8List.fromList([77]);
      firstRead.complete(Uint8List.fromList([12]));
      await disabling;
      await connecting;

      expect(scale.currentDeviceInformation?.batteryLevel, 77);
      expect(transport.batteryReadCount, 2);
    });

    test(
      'disconnect and reconnect during disable cannot start stale polling',
      () async {
        await scale.onConnect();
        await scale.setUsbPowered(true);
        final firstRead = Completer<Uint8List>();
        transport.batteryReadCompleter = firstRead;
        final disabling = scale.setUsbPowered(false);
        while (transport.batteryReadCount < 2) {
          await Future<void>.delayed(Duration.zero);
        }

        await scale.disconnect();
        transport.batteryReadCompleter = null;
        await transport.emitConnectionState(ConnectionState.discovered);
        await scale.onConnect();
        firstRead.complete(Uint8List.fromList([12]));
        await disabling;
        final reads = transport.batteryReadCount;
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(transport.batteryReadCount, greaterThanOrEqualTo(reads));
        expect(scale.currentDeviceInformation?.batteryLevel, 80);
      },
    );

    test('stops refresh polling after disconnect', () async {
      await scale.onConnect();
      expect(transport.batteryReadCount, 1);
      await scale.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(transport.batteryReadCount, 1);
    });

    test(
      'a reconnect can read while the previous generation is pending',
      () async {
        final firstRead = Completer<Uint8List>();
        transport.batteryReadCompleter = firstRead;
        final firstConnect = scale.onConnect();
        while (transport.batteryReadCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }

        await scale.disconnect();
        transport.batteryReadCompleter = null;
        transport.batteryValue = Uint8List.fromList([82]);
        await scale.onConnect();
        expect(scale.currentDeviceInformation?.batteryLevel, 82);

        firstRead.complete(Uint8List.fromList([12]));
        await firstConnect;
        await Future<void>.delayed(Duration.zero);
        expect(scale.currentDeviceInformation?.batteryLevel, 82);
      },
    );

    test(
      'disconnect prevents a stale in-flight read from repopulating',
      () async {
        final read = Completer<Uint8List>();
        transport.batteryReadCompleter = read;
        final connecting = scale.onConnect();
        while (transport.batteryReadCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await scale.disconnect();
        read.complete(Uint8List.fromList([82]));
        await connecting;
        expect(scale.currentDeviceInformation, isNull);
      },
    );
  });
}
