import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/logical_endpoint.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

mixin _TestCapability on UnifiedDe1 {
  Future<int> readFan() => readMmrInt(MMRItem.fanThreshold);
  Future<int> readFanViaWrongHelper() => readMmrInt(MMRItem.targetSteamFlow);
  Future<double> readFanAsScaledFloat() => readMmrScaled(MMRItem.fanThreshold);

  Future<List<int>> capRead(MmrAddress addr) => readMmrRaw(addr);
  Future<void> capWrite(MmrAddress addr, List<int> bytes) =>
      writeMmrRaw(addr, bytes);
  Future<double> capReadScaled(MmrAddress addr) => readMmrScaled(addr);
  Future<void> capWriteScaled(MmrAddress addr, double v) =>
      writeMmrScaled(addr, v);
  Stream<ByteData> capNotifications(LogicalEndpoint ep) => notificationsFor(ep);
  Future<void> capWriteEndpoint(
    LogicalEndpoint ep,
    Uint8List data, {
    bool withResponse = true,
  }) => writeEndpoint(ep, data, withResponse: withResponse);
}

class _CapabilityAddr implements MmrAddress {
  @override
  final int address;
  @override
  final int length;
  @override
  final String name;
  @override
  final MmrValueKind kind;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;
  const _CapabilityAddr({
    required this.address,
    required this.length,
    required this.name,
    required this.kind,
    this.readScale = 1.0,
    this.writeScale = 1.0,
    this.min,
    this.max,
  });
}

class _StubLogicalEndpoint implements LogicalEndpoint {
  @override
  final String? uuid;
  @override
  final String? representation;
  @override
  final String name;
  const _StubLogicalEndpoint({
    required this.uuid,
    required this.representation,
    required this.name,
  });
}

class _TestDe1 extends UnifiedDe1 with _TestCapability {
  _TestDe1({required super.transport});
}

void main() {
  group('UnifiedDe1 protected surface', () {
    late FakeBleTransport transport;
    late _TestDe1 de1;

    setUp(() async {
      transport = FakeBleTransport();
      de1 = _TestDe1(transport: transport);
      transport.queueOnConnectResponses();
      await de1.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    test('mixin can read int MMR via readMmrInt', () async {
      transport.queueMmrResponseInt(MMRItem.fanThreshold, 42);
      expect(await de1.readFan(), 42);
    });

    test('readMmrInt throws on scaledFloat address', () async {
      await expectLater(
        de1.readFanViaWrongHelper(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('readMmrInt'), contains('kind')),
          ),
        ),
      );
    });

    test('readMmrScaled throws on int32 address', () async {
      await expectLater(
        de1.readFanAsScaledFloat(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('readMmrScaled'), contains('kind')),
          ),
        ),
      );
    });

    test('readMmrRaw returns bytes for non-MMRItem MmrAddress', () async {
      const addr = _CapabilityAddr(
        address: 0x00802800,
        length: 4,
        name: 'cupWarmerStatus',
        kind: MmrValueKind.bytes,
      );
      transport.queueMmrResponseRaw(addr, [0xDE, 0xAD, 0xBE, 0xEF]);
      final result = await de1.capRead(addr);
      expect(result.sublist(4, 8), [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('writeMmrRaw sends the bytes on the wire for non-MMRItem', () async {
      const addr = _CapabilityAddr(
        address: 0x00803000,
        length: 4,
        name: 'cupWarmerSet',
        kind: MmrValueKind.bytes,
      );
      transport.writes.clear();
      await de1.capWrite(addr, [0x01, 0x02, 0x03, 0x04]);
      final frame = transport.writes.firstWhere(
        (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      expect(frame.data[0], 4);
      final addrBytes = ByteData(4)..setInt32(0, addr.address, Endian.big);
      expect(frame.data[1], addrBytes.getUint8(1));
      expect(frame.data[2], addrBytes.getUint8(2));
      expect(frame.data[3], addrBytes.getUint8(3));
      expect(frame.data.sublist(4, 8), [0x01, 0x02, 0x03, 0x04]);
    });

    test('readMmrScaled returns raw * readScale for non-MMRItem', () async {
      const addr = _CapabilityAddr(
        address: 0x00803800,
        length: 4,
        name: 'cupWarmerTemp',
        kind: MmrValueKind.scaledFloat,
        readScale: 0.1,
      );
      transport.queueMmrResponseRaw(addr, [0xFA, 0x00, 0x00, 0x00]);
      final result = await de1.capReadScaled(addr);
      expect(result, closeTo(25.0, 1e-9));
    });

    test('SteamStartSecs uses hundredths of a second on the wire', () async {
      expect(MMRItem.steamStartSecs.address, 0x0080382C);
      expect(MMRItem.steamStartSecs.length, 4);

      transport.queueMmrResponseInt(MMRItem.steamStartSecs, 150);
      expect(await de1.capReadScaled(MMRItem.steamStartSecs), 1.5);

      transport.writes.clear();
      await de1.capWriteScaled(MMRItem.steamStartSecs, 1.5);
      final frame = transport.writes.firstWhere(
        (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      final payload = ByteData.sublistView(frame.data, 4, 8);
      expect(payload.getInt32(0, Endian.little), 150);
    });

    test('writeMmrScaled clamps to min/max and writes scaled int', () async {
      const addr = _CapabilityAddr(
        address: 0x00804000,
        length: 4,
        name: 'cupWarmerSetTemp',
        kind: MmrValueKind.scaledFloat,
        writeScale: 10.0,
        min: 0,
        max: 500,
      );
      transport.writes.clear();
      await de1.capWriteScaled(addr, 99.9);
      final frame = transport.writes.firstWhere(
        (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      final payload = ByteData.sublistView(frame.data, 4, 8);
      expect(payload.getInt32(0, Endian.little), 500);
    });

    test(
      'notificationsFor(shotSample) routes to transport shotSample',
      () async {
        final stream = de1.capNotifications(Endpoint.shotSample);
        final marker = Uint8List(19);
        marker[0] = 0x7F;
        final received = expectLater(
          stream
              .where((d) => d.lengthInBytes >= 1 && d.getUint8(0) == 0x7F)
              .first,
          completion(isA<ByteData>()),
        );
        final cb = transport.subscribers[Endpoint.shotSample.uuid];
        expect(
          cb,
          isNotNull,
          reason: 'transport must have subscribed to shotSample on connect',
        );
        cb!(marker);
        await received;
      },
    );

    test('notificationsFor throws for non-Endpoint LogicalEndpoint', () {
      const ep = _StubLogicalEndpoint(
        uuid: 'C001',
        representation: 'Z',
        name: 'stub',
      );
      expect(
        () => de1.capNotifications(ep),
        throwsA(
          isA<UnimplementedError>().having(
            (e) => e.message,
            'message',
            contains('runtime subscription'),
          ),
        ),
      );
    });

    test(
      'writeEndpoint(withResponse: false) routes through transport.write',
      () async {
        transport.writes.clear();
        final payload = Uint8List.fromList([0xAB]);
        await de1.capWriteEndpoint(
          Endpoint.requestedState,
          payload,
          withResponse: false,
        );
        final frame = transport.writes.firstWhere(
          (w) => w.characteristicUUID == Endpoint.requestedState.uuid,
        );
        expect(frame.data, payload);
        expect(frame.withResponse, isFalse);
      },
    );
  });
}
