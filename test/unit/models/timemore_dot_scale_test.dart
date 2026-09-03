import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/timemore/timemore_dot_protocol.dart';
import 'package:reaprime/src/models/device/impl/timemore/timemore_dot_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _TimemoreDotTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final List<String> operations = [];
  final List<List<int>> writes = [];
  List<String> services = [TimemoreDotScale.serviceIdentifier.long];
  void Function(Uint8List)? notification;
  Object? writeError;
  bool failConnect = false;
  bool disconnectOnInitWrite = false;
  bool _linkDown = false;

  @override
  String get id => 'timemore-dot-test';

  @override
  String get name => 'TIMEMORE DOT';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async {
    operations.add('connect');
    if (failConnect) throw StateError('connect failed');
    states.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async => states.add(ConnectionState.disconnected);

  @override
  Future<List<String>> discoverServices() async => services;

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    operations.add('subscribe:$characteristicUUID');
    notification = callback;
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    operations.add('write:${_hex(data)}');
    writes.add(data.toList());
    if (disconnectOnInitWrite && !_linkDown) {
      _linkDown = true;
      states.add(ConnectionState.disconnected);
      throw const DeviceNotConnectedException.scale();
    }
    if (_linkDown) throw const DeviceNotConnectedException.scale();
    final error = writeError;
    if (error != null) throw error;
  }

  void emit(List<int> data) => notification!(Uint8List.fromList(data));

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async => states.close();
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

TimemoreDotScale _scale(_TimemoreDotTransport transport) => TimemoreDotScale(
  transport: transport,
  initDelayAfterSubscribe: Duration.zero,
  initDelayBeforeMode: Duration.zero,
  initDelayBeforeBattery: Duration.zero,
);

List<int> _frame(int opcode, int cmdId, List<int> payload) =>
    TimemoreDotProtocol.buildFrame(opcode, cmdId, payload);

List<int> _weightPayload(double grams, {int timerSeconds = 0}) {
  final raw = (grams * 10).round() & 0xFFFFFFFF;
  return [
    (raw >> 24) & 0xFF,
    (raw >> 16) & 0xFF,
    (raw >> 8) & 0xFF,
    raw & 0xFF,
    0x00,
    0x00,
    (timerSeconds >> 8) & 0xFF,
    timerSeconds & 0xFF,
    0x00,
  ];
}

void main() {
  late _TimemoreDotTransport transport;
  late TimemoreDotScale scale;
  late List<ScaleSnapshot> snapshots;

  setUp(() async {
    transport = _TimemoreDotTransport();
    scale = _scale(transport);
    snapshots = [];
    await scale.onConnect();
    scale.currentSnapshot.listen(snapshots.add);
  });

  tearDown(() async {
    await scale.disconnect();
    await transport.dispose();
  });

  test('decodes positive weight at 0.1 g resolution', () async {
    transport.emit(_frame(0x01, 0x01, _weightPayload(1234.5)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 1234.5);
  });

  test('decodes negative weight', () async {
    transport.emit(_frame(0x01, 0x01, _weightPayload(-12.3)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, -12.3);
  });

  test('accepts opcode 0x02 weight frames', () async {
    transport.emit(_frame(0x02, 0x01, _weightPayload(1.1)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 1.1);
  });

  test('reports timer seconds as a duration', () async {
    transport.emit(_frame(0x01, 0x01, _weightPayload(10.0, timerSeconds: 42)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.timerValue, const Duration(seconds: 42));
  });

  test('zero timer reports no timer value', () async {
    transport.emit(_frame(0x01, 0x01, _weightPayload(10.0)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.timerValue, isNull);
  });

  test(
    'battery frame updates and retains the level across weight frames',
    () async {
      transport.emit(_frame(0x01, 0x05, [0x00, 0x48]));
      transport.emit(_frame(0x01, 0x01, _weightPayload(5.0)));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last.batteryLevel, 72);
    },
  );

  test('single-byte battery payload falls back to the first byte', () async {
    transport.emit(_frame(0x01, 0x05, [80]));
    transport.emit(_frame(0x01, 0x01, _weightPayload(5.0)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.batteryLevel, 80);
  });

  test('implausible battery level is ignored', () async {
    transport.emit(_frame(0x01, 0x05, [0x00, 0x65]));
    transport.emit(_frame(0x01, 0x01, _weightPayload(5.0)));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.batteryLevel, 0);
  });

  test('frame split across notifications decodes once', () async {
    final frame = _frame(0x01, 0x01, _weightPayload(250.0));
    transport.emit(frame.sublist(0, 6));
    transport.emit(frame.sublist(6));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 250.0);
  });

  test('two frames in one notification decode twice', () async {
    final first = _frame(0x01, 0x01, _weightPayload(1.0));
    final second = _frame(0x01, 0x01, _weightPayload(2.0));
    transport.emit([...first, ...second]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.map((snapshot) => snapshot.weight), [1.0, 2.0]);
  });

  test('garbage prefix is skipped before the frame magic', () async {
    final frame = _frame(0x01, 0x01, _weightPayload(3.0));
    transport.emit([0x00, 0xFF, 0x12, ...frame]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 3.0);
  });

  test('implausible length field resyncs instead of stalling', () async {
    final frame = _frame(0x01, 0x01, _weightPayload(4.0));
    transport.emit([0xA5, 0x5A, 0x03, 0x01, 0xFF, 0xFF, 0x00, 0x00, ...frame]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 4.0);
  });

  test('notification CRC bytes are not validated', () async {
    final frame = _frame(0x01, 0x01, _weightPayload(5.0));
    frame[frame.length - 1] ^= 0xFF;
    transport.emit(frame);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 5.0);
  });

  test('decodes a real captured frame from the physical Dot', () async {
    transport.emit([
      0xA5, 0x5A, 0x01, 0x01, 0x00, 0x09, //
      0x00, 0x00, 0x0D, 0xB9, 0x00, 0x00, 0x03, 0xE7, 0x00, //
      0x00, 0x00,
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.weight, 351.3);
    expect(snapshots.single.timerValue, const Duration(seconds: 999));
  });

  test('command ACK frames are ignored', () async {
    transport.emit(_frame(0x03, 0x02, [0x01]));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
  });

  test('short weight payload is ignored', () async {
    transport.emit(
      _frame(0x01, 0x01, [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
  });

  test('connect runs subscribe then the init sequence in order', () async {
    expect(transport.operations, [
      'connect',
      'subscribe:${TimemoreDotScale.weightCharacteristic.long}',
      'write:${_hex(TimemoreDotProtocol.initUnitCommand())}',
      'write:${_hex(TimemoreDotProtocol.initModeCommand())}',
      'write:${_hex(TimemoreDotProtocol.initBatteryCommand())}',
    ]);
    expect(await scale.connectionState.first, ConnectionState.connected);
  });

  test('init write failure is tolerated and connect still completes', () async {
    final failedTransport = _TimemoreDotTransport()
      ..writeError = StateError('init write failed');
    final failedScale = _scale(failedTransport);
    await failedScale.onConnect();
    expect(await failedScale.connectionState.first, ConnectionState.connected);
    failedTransport.writeError = null;
    await failedScale.tare();
    expect(failedTransport.writes.last, TimemoreDotProtocol.tareCommand());
    await failedScale.disconnect();
    await failedTransport.dispose();
  });

  test('disconnect during init does not publish stale connected', () async {
    final droppedTransport = _TimemoreDotTransport()
      ..disconnectOnInitWrite = true;
    final droppedScale = _scale(droppedTransport);
    await droppedScale.onConnect();
    expect(
      await droppedScale.connectionState.first,
      ConnectionState.disconnected,
    );
    await droppedTransport.dispose();
  });

  test('connect failure emits disconnected', () async {
    final failedTransport = _TimemoreDotTransport()..failConnect = true;
    final failedScale = _scale(failedTransport);
    await failedScale.onConnect();
    expect(
      await failedScale.connectionState.first,
      ConnectionState.disconnected,
    );
    await failedTransport.dispose();
  });

  test('missing FFF0 service emits disconnected', () async {
    final wrongTransport = _TimemoreDotTransport()
      ..services = ['0000ffe0-0000-1000-8000-00805f9b34fb'];
    final wrongScale = _scale(wrongTransport);
    await wrongScale.onConnect();
    expect(
      await wrongScale.connectionState.first,
      ConnectionState.disconnected,
    );
    await wrongTransport.dispose();
  });

  test('tare and timer commands write the verified reference bytes', () async {
    await scale.tare();
    await scale.startTimer();
    await scale.stopTimer();
    await scale.resetTimer();
    expect(transport.writes.sublist(transport.writes.length - 4), [
      TimemoreDotProtocol.tareCommand(),
      TimemoreDotProtocol.timerStartCommand(),
      TimemoreDotProtocol.timerStopCommand(),
      TimemoreDotProtocol.timerResetCommand(),
    ]);
  });

  test('disconnected command failure is ignored', () async {
    transport.writeError = const DeviceNotConnectedException.scale();
    await expectLater(scale.tare(), completes);
  });

  test('unrelated command failure propagates', () async {
    transport.writeError = StateError('write failed');
    await expectLater(scale.tare(), throwsStateError);
  });
}
