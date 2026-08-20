import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/telemetry/anonymization.dart';

void main() {
  group('Anonymization.scrubString', () {
    test('redacts a machine serial number', () {
      final out = Anonymization.scrubString(
        'Info: {serialNumber: 123456} Machine serial 123456',
        sensitiveStrings: ['123456'],
      );
      expect(out, isNot(contains('123456')));
      expect(out, contains('serial_'));
    });

    test('leaves short serials untouched', () {
      final out = Anonymization.scrubString(
        'serial 12',
        sensitiveStrings: ['12'],
      );
      expect(out, contains('12'));
    });

    test('still scrubs mac and ip addresses', () {
      final out = Anonymization.scrubString(
        'mac AA:BB:CC:DD:EE:FF ip 192.168.1.50',
      );
      expect(out, isNot(contains('AA:BB:CC:DD:EE:FF')));
      expect(out, isNot(contains('192.168.1.50')));
    });

    test('scrubs ipv6 addresses', () {
      final out = Anonymization.scrubString(
        'loopback ::1 link-local fe80::1234:abcd '
        '2001:db8::1 full 2001:db8:0:1:1:1:1:1',
      );
      expect(out, isNot(contains('::1')));
      expect(out, isNot(contains('fe80::1234:abcd')));
      expect(out, isNot(contains('2001:db8::1')));
      expect(out, isNot(contains('2001:db8:0:1:1:1:1:1')));
      expect(out, contains('ip_'));
    });

    test('scrubs serialNumber log fields without a serial provider', () {
      final out = Anonymization.scrubString(
        '{"machineInfo":{"serialNumber":"SN123456"}} '
        'serialNumber: SN999888',
      );
      expect(out, isNot(contains('SN123456')));
      expect(out, isNot(contains('SN999888')));
      expect(out, contains('serial_'));
    });

    test('leaves timestamps and bare colons untouched', () {
      final out = Anonymization.scrubString(
        'at 10:30:00 request 2025-05-14T10:30:00.123Z',
      );
      expect(out, contains('10:30:00'));
      expect(out, isNot(contains('ip_')));
    });
  });

  group('Anonymization.anonymizeSerial', () {
    test('is deterministic and prefixed', () {
      final a = Anonymization.anonymizeSerial('123456');
      final b = Anonymization.anonymizeSerial('123456');
      expect(a, b);
      expect(a, startsWith('serial_'));
    });
  });
}
