import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/usb_ids.dart';
import 'package:reaprime/src/services/serial/utils.dart';

void main() {
  group('isBengleEbusTap', () {
    test('exact tap identity is accepted', () {
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'Bengle',
        ),
        isTrue,
      );
    });

    test('interface 0 (machine) is rejected and keeps its identity', () {
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 0,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 1,
          productName: 'Bengle',
        ),
        isFalse,
      );
    });

    test('missing metadata is rejected', () {
      expect(
        isBengleEbusTap(
          vid: null,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: null,
          interfaceNumber: 2,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: null,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: null,
        ),
        isFalse,
      );
    });

    test('wrong vid or pid is rejected', () {
      expect(
        isBengleEbusTap(
          vid: 0x1a86,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x7522,
          interfaceNumber: 2,
          productName: 'Bengle',
        ),
        isFalse,
      );
    });

    test('matching vid/pid/interface but wrong product name is rejected', () {
      // VID/PID are shared Pico SDK identifiers; a Pico board with the same
      // IDs and a tap-like interface layout must not be treated as the tap.
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'Pico',
        ),
        isFalse,
      );
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'DE1',
        ),
        isFalse,
      );
      // Product matching is exact: no case-insensitive fallback.
      expect(
        isBengleEbusTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceNumber: 2,
          productName: 'bengle',
        ),
        isFalse,
      );
    });
  });

  group('isBengleCompositeWithTap', () {
    test('composite with the tap data interface present exposes the tap', () {
      expect(
        isBengleCompositeWithTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceCount: 4,
          productName: 'Bengle',
        ),
        isTrue,
      );
    });

    test('device without the tap data interface yields no tap', () {
      expect(
        isBengleCompositeWithTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceCount: 1,
          productName: 'Bengle',
        ),
        isFalse,
      );
      // Interfaces 0..2 only: the Linux tap control interface exists but the
      // Android bulk-data interface 3 does not, so the tap cannot open.
      expect(
        isBengleCompositeWithTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceCount: 3,
          productName: 'Bengle',
        ),
        isFalse,
      );
      expect(
        isBengleCompositeWithTap(
          vid: 0x2e8a,
          pid: 0x000a,
          interfaceCount: null,
          productName: 'Bengle',
        ),
        isFalse,
      );
    });

    test('unrelated composite devices yield no tap', () {
      expect(
        isBengleCompositeWithTap(
          vid: 0x046d,
          pid: 0xc31c,
          interfaceCount: 4,
          productName: 'Bengle',
        ),
        isFalse,
      );
    });

    test(
      'matching vid/pid/interface count but wrong product name is rejected',
      () {
        expect(
          isBengleCompositeWithTap(
            vid: 0x2e8a,
            pid: 0x000a,
            interfaceCount: 4,
            productName: 'Pico',
          ),
          isFalse,
        );
        expect(
          isBengleCompositeWithTap(
            vid: 0x2e8a,
            pid: 0x000a,
            interfaceCount: 4,
            productName: 'Other',
          ),
          isFalse,
        );
        expect(
          isBengleCompositeWithTap(
            vid: 0x2e8a,
            pid: 0x000a,
            interfaceCount: 4,
            productName: null,
          ),
          isFalse,
        );
      },
    );
  });

  group('computeUsbStableId with interface', () {
    test('interface 2 appends a zero-padded -if02 suffix', () {
      expect(
        computeUsbStableId(
          vid: 0x2e8a,
          pid: 0x000a,
          serial: 'ABC123',
          interfaceNumber: 2,
        ),
        equals('usb-2e8a-a-ABC123-if02'),
      );
    });

    test('interface 0 and absent interface preserve existing IDs', () {
      expect(
        computeUsbStableId(
          vid: 0x2e8a,
          pid: 0x000a,
          serial: 'ABC123',
          interfaceNumber: 0,
        ),
        equals('usb-2e8a-a-ABC123'),
      );
      expect(
        computeUsbStableId(vid: 0x2e8a, pid: 0x000a, serial: 'ABC123'),
        equals('usb-2e8a-a-ABC123'),
      );
    });
  });

  group('withoutUsbInterfaceSuffix', () {
    test('strips the tap suffix back to the physical device ID', () {
      expect(
        withoutUsbInterfaceSuffix('usb-2e8a-a-ABC123-if02'),
        equals('usb-2e8a-a-ABC123'),
      );
      expect(
        withoutUsbInterfaceSuffix('usb-2e8a-a-ABC123-if02-1003'),
        equals('usb-2e8a-a-ABC123'),
      );
    });

    test('returns suffix-free IDs unchanged', () {
      expect(
        withoutUsbInterfaceSuffix('usb-2e8a-a-ABC123'),
        equals('usb-2e8a-a-ABC123'),
      );
      expect(
        withoutUsbInterfaceSuffix('serial-ttyACM0'),
        equals('serial-ttyACM0'),
      );
    });
  });
}
