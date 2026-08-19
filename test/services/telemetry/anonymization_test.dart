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
