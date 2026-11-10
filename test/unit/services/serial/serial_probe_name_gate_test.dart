import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/utils.dart';

void main() {
  test('admits supported serial product names', () {
    for (final name in [
      'Bengle',
      'DE1',
      'Half Decent Scale',
      'USB Serial Device',
      'Debug Probe (CMSIS-DAP)',
    ]) {
      expect(serialProbeAllowsProductName(name), isTrue, reason: name);
    }
  });

  test('preserves case sensitivity and rejects unrelated names', () {
    for (final name in [
      'bengle',
      'de1',
      'USB serial Device',
      'Keyboard',
      'debug Probe (CMSIS-DAP)',
      'Debug Probe (cmsis-dap)',
    ]) {
      expect(serialProbeAllowsProductName(name), isFalse, reason: name);
    }
  });

  test('preserves existing null-name admission', () {
    expect(serialProbeAllowsProductName(null), isTrue);
  });
}
