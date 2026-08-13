import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  group('Bengle wake schedule wiring', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // probe
      );
      await bengle.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    test(
      'setInactivitySleepTimeout writes minutes to 0x38BC, clamped 0..240',
      () async {
        transport.writes.clear();
        await bengle.setInactivitySleepTimeout(45);
        await bengle.setInactivitySleepTimeout(999);

        final addr = ByteData(4)
          ..setInt32(0, BengleMmr.inactivitySleepTimeout.address, Endian.big);
        final frames = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(frames.length, 2);
        for (final frame in frames) {
          expect(frame.data[1], addr.getUint8(1));
          expect(frame.data[2], addr.getUint8(2));
          expect(frame.data[3], addr.getUint8(3));
        }
        final first = ByteData.sublistView(frames[0].data, 4, 8);
        final second = ByteData.sublistView(frames[1].data, 4, 8);
        expect(first.getUint32(0, Endian.little), 45);
        expect(second.getUint32(0, Endian.little), 240);
      },
    );

    test(
      'pushFirmwareWakeSchedule writes clock, clear, entries, enable',
      () async {
        transport.writes.clear();
        await bengle.pushFirmwareWakeSchedule(
          secondsSinceSundayLocal: 123456,
          windows: const [
            FirmwareWakeWindow(dow: 1, startMin: 360, endMin: 390),
            FirmwareWakeWindow(dow: 3, startMin: 720, endMin: 780),
          ],
        );

        final frames = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(frames.length, 5);

        void expectFrame(int index, BengleMmr mmr, int value) {
          final frame = frames[index];
          final addr = ByteData(4)..setInt32(0, mmr.address, Endian.big);
          expect(frame.data[1], addr.getUint8(1));
          expect(frame.data[2], addr.getUint8(2));
          expect(frame.data[3], addr.getUint8(3));
          final payload = ByteData.sublistView(frame.data, 4, 8);
          expect(payload.getUint32(0, Endian.little), value);
        }

        expectFrame(0, BengleMmr.setLocalTimeOfWeek, 123456);
        expectFrame(1, BengleMmr.scheduleControl, 0); // clear + disable
        expectFrame(2, BengleMmr.scheduleEntry, (1 << 22) | (360 << 11) | 390);
        expectFrame(3, BengleMmr.scheduleEntry, (3 << 22) | (720 << 11) | 780);
        expectFrame(4, BengleMmr.scheduleControl, 1); // enable
      },
    );

    test(
      'pushFirmwareWakeSchedule with no windows clears and stays disabled',
      () async {
        transport.writes.clear();
        await bengle.pushFirmwareWakeSchedule(
          secondsSinceSundayLocal: 0,
          windows: const [],
        );

        final frames = transport.writes
            .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
            .toList();
        expect(frames.length, 2);
        final control = ByteData.sublistView(frames[1].data, 4, 8);
        expect(control.getUint32(0, Endian.little), 0);
      },
    );
  });
}
