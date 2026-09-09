import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bookoo/miniscale.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';
import '../../helpers/bookoo_packets.dart';

class _BookooTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final List<List<int>> writes = [];
  void Function(Uint8List)? notification;
  Object? writeError;

  @override
  String get id => 'bookoo-test';

  @override
  String get name => 'BOOKOO';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async => states.add(ConnectionState.connected);

  @override
  Future<void> disconnect() async => states.add(ConnectionState.disconnected);

  @override
  Future<List<String>> discoverServices() async => [
    BookooScale.serviceIdentifier.long,
  ];

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
    writes.add(data.toList());
    final error = writeError;
    if (error != null) throw error;
  }

  void emit(List<int> data) => notification!(Uint8List.fromList(data));

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async => states.close();
}

List<int> _packet(double grams, {int? battery = 50}) {
  return bookooPacket(grams, battery: battery);
}

void main() {
  late _BookooTransport transport;
  late BookooScale scale;
  late List<ScaleSnapshot> snapshots;

  setUp(() async {
    transport = _BookooTransport();
    scale = BookooScale(transport: transport);
    snapshots = [];
    await scale.onConnect();
    scale.currentSnapshot.listen(snapshots.add);
  });

  tearDown(() async {
    await scale.disconnect();
    await transport.dispose();
  });

  test('decodes positive and negative three-byte weights', () async {
    transport.emit(_packet(123.45));
    transport.emit(_packet(-12.34));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.map((snapshot) => snapshot.weight), [123.45, -12.34]);
  });

  test('invalid lengths and unrelated packets emit nothing', () async {
    final valid = _packet(10);
    for (final packet in <List<int>>[
      for (final length in [9, 10, 11, 19]) valid.sublist(0, length),
      [...valid, 0],
      [0x04, ..._packet(10).sublist(1)],
      [0x03, 0x0A, ..._packet(10).sublist(2)],
      <int>[],
    ]) {
      expect(() => transport.emit(packet), returnsNormally);
    }
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
  });

  test('invalid checksum emits nothing', () async {
    final packet = _packet(10);
    packet[18] ^= 1;
    transport.emit(packet);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
  });

  test('invalid sign byte emits nothing', () async {
    final packet = _packet(10);
    packet[6] = 0x00;
    packet[19] = packet.take(19).fold(0, (sum, byte) => sum ^ byte);
    transport.emit(packet);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
  });

  test('invalid battery retains the previous valid level', () async {
    transport.emit(_packet(1, battery: 72));
    transport.emit(_packet(2, battery: 101));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.map((snapshot) => snapshot.batteryLevel), [72, 72]);
  });

  test('commands remain protocol-compatible', () async {
    await scale.tare();
    await scale.startTimer();
    await scale.stopTimer();
    await scale.resetTimer();
    expect(transport.writes, bookooCommands);
  });

  test('shared plugin malformed packet fixtures emit nothing', () async {
    for (final packet in invalidBookooPackets()) {
      transport.emit(packet);
    }
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
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
