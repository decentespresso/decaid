import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/skale/skale2_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _RecordableBleTransport extends BLETransport {
  final List<String> serviceUUIDs = const [
    '0000ff08-0000-1000-8000-00805f9b34fb',
  ];

  final List<String> operations = [];

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  final Map<String, void Function(Uint8List)> _notifyCallbacks = {};

  _RecordableBleTransport();

  @override
  String get id => 'skale2-test-device';

  @override
  String get name => 'Test Skale2';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

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
    if (shortUuid == '2a19') {
      return Uint8List.fromList([80]);
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

    test('uses first weight block from nine-byte notification', () async {
      final completer = Completer<ScaleSnapshot>();
      final sub = scale.currentSnapshot.listen((snapshot) {
        if (!completer.isCompleted) completer.complete(snapshot);
      });

      transport.simulateWeightNotification([
        0x00,
        0xE8,
        0x03,
        0x00,
        0xFF,
        0xD2,
        0x04,
        0x00,
        0xFE,
      ]);

      final snapshot = await completer.future.timeout(
        const Duration(seconds: 1),
      );
      expect(snapshot.weight, closeTo(100.0, 0.001));

      await sub.cancel();
    });

    test('ignores unsupported six-byte frame', () async {
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
}
