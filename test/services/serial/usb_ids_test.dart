import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/usb_ids.dart';

void main() {
  group('matchUsbDevice', () {
    const a = (0x1234, 0x5678);
    test('returns the model for a matching pair', () {
      const table = {
        UsbDeviceModel.de1: [a],
      };
      expect(
        matchUsbDevice(table, vid: a.$1, pid: a.$2),
        equals(UsbDeviceModel.de1),
      );
    });

    test('returns null for an unknown pair', () {
      const table = {
        UsbDeviceModel.de1: [a],
      };
      expect(matchUsbDevice(table, vid: 0xFFFF, pid: 0xFFFF), isNull);
    });

    test('returns null when vid or pid is null', () {
      const table = {
        UsbDeviceModel.de1: [a],
      };
      expect(matchUsbDevice(table, vid: null, pid: a.$2), isNull);
      expect(matchUsbDevice(table, vid: a.$1, pid: null), isNull);
      expect(matchUsbDevice(table, vid: null, pid: null), isNull);
    });

    test('handles entries with multiple pairs per model', () {
      const c = (0x1111, 0x2222);
      const table = {
        UsbDeviceModel.de1: [a, c],
      };
      expect(
        matchUsbDevice(table, vid: c.$1, pid: c.$2),
        equals(UsbDeviceModel.de1),
      );
    });
  });

  group('default usbDeviceTable', () {
    test('returns null for a clearly unrelated pair', () {
      expect(matchUsbDevice(usbDeviceTable, vid: 0xFFFF, pid: 0xFFFF), isNull);
    });
  });
}
