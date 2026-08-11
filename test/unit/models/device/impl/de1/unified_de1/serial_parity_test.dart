import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _RecordingSerialTransport extends SerialTransport {
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final input = StreamController<String>.broadcast(sync: true);
  final writes = <String>[];
  final blockedCommands = <String, Completer<void>>{};
  void Function(String command)? onWrite;
  String? failCommand;

  Completer<void> blockCommand(String command) =>
      blockedCommands[command] = Completer<void>();

  void emitDisconnected() {
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  String get id => 'serial-test';

  @override
  String get name => 'Serial test';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<String> get readStream => input.stream;

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    if (!input.isClosed) await input.close();
    if (!_connectionState.isClosed) await _connectionState.close();
  }

  @override
  Future<void> writeCommand(String command) async {
    writes.add(command);
    onWrite?.call(command);
    if (command == failCommand) throw StateError('write failed');
    await blockedCommands[command]?.future;
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {}
}

void main() {
  late _RecordingSerialTransport serial;
  late UnifiedDe1Transport transport;

  setUp(() {
    serial = _RecordingSerialTransport();
    transport = UnifiedDe1Transport(transport: serial);
  });

  tearDown(() => transport.dispose());

  test('serial writeToMMR frames are exactly 20 bytes', () async {
    for (final length in [1, 19, 20]) {
      final input = Uint8List.fromList(List.generate(length, (i) => i + 1));
      final original = Uint8List.fromList(input);

      await transport.write(Endpoint.writeToMMR, input);

      final payload = serial.writes.removeAt(0).substring(3);
      expect(payload.length, 40);
      expect(
        payload.substring(0, length * 2),
        original.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      );
      expect(
        payload.substring(length * 2),
        List.filled((20 - length) * 2, '0').join(),
      );
      expect(input, original);
    }
  });

  test('serial writeToMMR rejects frames longer than 20 bytes', () async {
    await expectLater(
      transport.write(Endpoint.writeToMMR, Uint8List(21)),
      throwsArgumentError,
    );
    expect(serial.writes, isEmpty);
  });

  test('serial non-writeToMMR frames remain unchanged', () async {
    await transport.write(Endpoint.headerWrite, Uint8List.fromList([1]));

    expect(serial.writes, ['<O>01']);
  });

  test('BLE writeToMMR frames remain unchanged', () async {
    final ble = FakeBleTransport();
    final bleTransport = UnifiedDe1Transport(transport: ble);
    addTearDown(bleTransport.dispose);

    await bleTransport.write(Endpoint.writeToMMR, Uint8List.fromList([1]));

    expect(ble.writes.single.data, [1]);
  });

  group('locally known shot settings', () {
    final settings = De1ShotSettings(
      steamSetting: 1,
      targetSteamTemp: 140,
      targetSteamDuration: 30,
      targetHotWaterTemp: 80,
      targetHotWaterVolume: 200,
      targetHotWaterDuration: 20,
      targetShotVolume: 40,
      groupTemp: 90.5,
    );

    test('successful writes record local state', () async {
      final localSerial = _RecordingSerialTransport();
      final machine = UnifiedDe1(transport: localSerial);
      addTearDown(machine.dispose);

      await machine.updateShotSettings(settings);

      expect(await machine.shotSettings.first, settings);
    });

    test('failed writes record no local state', () async {
      final localSerial = _RecordingSerialTransport();
      final machine = UnifiedDe1(transport: localSerial);
      addTearDown(machine.dispose);
      localSerial.onWrite = (_) => throw StateError('write failed');

      await expectLater(machine.updateShotSettings(settings), throwsStateError);
      await expectLater(
        machine.shotSettings.first.timeout(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('persistent serial reads', () {
    setUp(() async {
      await transport.connect();
      serial.writes.clear();
    });

    test('missing frames report typed unavailability', () async {
      for (final endpoint in [
        Endpoint.stateInfo,
        Endpoint.shotSample,
        Endpoint.waterLevels,
        Endpoint.shotSettings,
        Endpoint.fwMapRequest,
      ]) {
        await expectLater(
          transport.read(endpoint, timeout: Duration.zero),
          throwsA(isA<EndpointUnavailableException>()),
        );
      }
    });

    test('latest genuine frame is replayed', () async {
      serial.input.add('[N]0102\n');

      final result = await transport.read(
        Endpoint.stateInfo,
        timeout: const Duration(milliseconds: 100),
      );

      expect(result.buffer.asUint8List(), [1, 2]);
    });

    test('Bengle telemetry enables S before disabling M', () async {
      await transport.subscribeBengleShotSample();

      expect(serial.writes, ['<+S>', '<-M>']);
      serial.input.add('[S]${'00' * 28}\n');
      expect((await transport.bengleShotSample.first).lengthInBytes, 28);
    });

    test(
      'MMR and requested-state reads are not aliases of cached state',
      () async {
        serial.input.add('[E]0102\n[N]0304\n');

        await expectLater(
          transport.read(Endpoint.readFromMMR),
          throwsA(isA<UnsupportedError>()),
        );
        await expectLater(
          transport.read(Endpoint.requestedState),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('write-only endpoint reads are unsupported', () async {
      await expectLater(
        transport.read(Endpoint.writeToMMR),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('disconnect clears cached persistent frames', () async {
      serial.input.add('[N]0102\n');
      expect((await transport.read(Endpoint.stateInfo)).buffer.asUint8List(), [
        1,
        2,
      ]);

      await transport.disconnect();
      await transport.connect();

      await expectLater(
        transport.read(Endpoint.stateInfo, timeout: Duration.zero),
        throwsA(isA<EndpointUnavailableException>()),
      );
    });
  });

  group('one-shot serial reads', () {
    setUp(() async {
      await transport.connect();
      serial.writes.clear();
    });

    for (final endpoint in [
      Endpoint.versions,
      Endpoint.temperatures,
      Endpoint.calibration,
    ]) {
      test(
        '${endpoint.representation} captures an immediate response',
        () async {
          serial.onWrite = (command) {
            if (command == '<+${endpoint.representation}>') {
              serial.input.add('[${endpoint.representation}]0102\n');
            }
          };

          final result = await transport.read(
            endpoint,
            timeout: const Duration(milliseconds: 100),
          );

          expect(result.buffer.asUint8List(), [1, 2]);
          expect(serial.writes, [
            '<+${endpoint.representation}>',
            '<-${endpoint.representation}>',
          ]);
        },
      );
    }

    test('different representations can be pending concurrently', () async {
      final a = transport.read(
        Endpoint.versions,
        timeout: const Duration(milliseconds: 100),
      );
      final j = transport.read(
        Endpoint.temperatures,
        timeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);

      serial.input.add('[J]02\n[A]01\n');

      expect((await a).buffer.asUint8List(), [1]);
      expect((await j).buffer.asUint8List(), [2]);
    });

    test('duplicate representation is rejected', () async {
      final first = transport.read(
        Endpoint.versions,
        timeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        transport.read(
          Endpoint.versions,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsStateError,
      );
      serial.input.add('[A]01\n');
      await first;
    });

    test('write failure clears the waiter and still unsubscribes', () async {
      serial.failCommand = '<+A>';

      await expectLater(
        transport.read(
          Endpoint.versions,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsStateError,
      );

      serial.failCommand = null;
      serial.onWrite = (command) {
        if (command == '<+A>') serial.input.add('[A]01\n');
      };
      expect(
        (await transport.read(
          Endpoint.versions,
          timeout: const Duration(milliseconds: 100),
        )).buffer.asUint8List(),
        [1],
      );
      expect(serial.writes.where((command) => command == '<-A>').length, 2);
    });

    test('timeout clears the waiter and ignores a late response', () async {
      await expectLater(
        transport.read(Endpoint.versions, timeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      serial.input.add('[A]09\n');
      serial.onWrite = (command) {
        if (command == '<+A>') serial.input.add('[A]01\n');
      };

      final result = await transport.read(
        Endpoint.versions,
        timeout: const Duration(milliseconds: 100),
      );

      expect(result.buffer.asUint8List(), [1]);
    });

    test(
      'read timeout is not extended by a fresh unsubscribe timeout',
      () async {
        const timeout = Duration(milliseconds: 300);
        final unsubscribe = serial.blockCommand('<-A>');
        final stopwatch = Stopwatch()..start();

        try {
          await expectLater(
            transport.read(Endpoint.versions, timeout: timeout),
            throwsA(isA<TimeoutException>()),
          );
          stopwatch.stop();

          expect(
            stopwatch.elapsed,
            lessThan(const Duration(milliseconds: 500)),
          );
        } finally {
          if (!unsubscribe.isCompleted) unsubscribe.complete();
        }
      },
    );

    test('malformed responses do not complete a request', () async {
      final result = transport.read(
        Endpoint.versions,
        timeout: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);

      serial.input.add('[A]0\n[A]01\n');

      expect((await result).buffer.asUint8List(), [1]);
    });

    test('transport disconnect fails pending requests immediately', () async {
      final result = transport.read(
        Endpoint.versions,
        timeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final expectation = expectLater(result, throwsStateError);

      serial.emitDisconnected();

      await expectation;
    });

    test('disconnect fails pending requests immediately', () async {
      final result = transport.read(
        Endpoint.versions,
        timeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final expectation = expectLater(result, throwsStateError);

      await transport.disconnect();

      await expectation;
    });

    test('dispose fails pending requests immediately', () async {
      final result = transport.read(
        Endpoint.versions,
        timeout: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final expectation = expectLater(result, throwsStateError);

      await transport.dispose();

      await expectation;
    });

    test(
      'unsubscribe failure is surfaced after a successful response',
      () async {
        serial.failCommand = '<-A>';
        serial.onWrite = (command) {
          if (command == '<+A>') serial.input.add('[A]01\n');
        };

        await expectLater(
          transport.read(
            Endpoint.versions,
            timeout: const Duration(milliseconds: 100),
          ),
          throwsStateError,
        );
      },
    );
  });
}
