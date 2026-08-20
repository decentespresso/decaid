import 'dart:convert';
import 'package:crypto/crypto.dart';

class Anonymization {
  static const String _salt = 'reaprime-telemetry-v1';

  static String anonymizeMac(String macAddress) {
    final normalized = macAddress
        .toUpperCase()
        .replaceAll(':', '')
        .replaceAll('-', '');

    final input = '$_salt:mac:$normalized';

    final bytes = utf8.encode(input);
    final hash = sha256.convert(bytes);

    return 'mac_${hash.toString().substring(0, 16)}';
  }

  static String anonymizeIp(String ipAddress) {
    final input = '$_salt:ip:$ipAddress';

    final bytes = utf8.encode(input);
    final hash = sha256.convert(bytes);

    return 'ip_${hash.toString().substring(0, 16)}';
  }

  static String anonymizeSerial(String serialNumber) {
    final bytes = utf8.encode('$_salt:serial:$serialNumber');
    final hash = sha256.convert(bytes);

    return 'serial_${hash.toString().substring(0, 16)}';
  }

  static String anonymize(String input) {
    final macPattern = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$');
    if (macPattern.hasMatch(input)) {
      return anonymizeMac(input);
    }

    final ipv4Pattern = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');
    if (ipv4Pattern.hasMatch(input)) {
      return anonymizeIp(input);
    }

    final ipv6Pattern = RegExp(r'^[0-9A-Fa-f:]+$');
    if (input.contains(':') && ipv6Pattern.hasMatch(input)) {
      return anonymizeIp(input);
    }

    return input;
  }

  static String scrubString(
    String text, {
    List<String> sensitiveStrings = const [],
  }) {
    var scrubbed = text;

    for (final sensitive in sensitiveStrings) {
      if (sensitive.length < 3) continue;
      scrubbed = scrubbed.replaceAll(sensitive, anonymizeSerial(sensitive));
    }

    final macPattern = RegExp(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}');
    scrubbed = scrubbed.replaceAllMapped(macPattern, (match) {
      return anonymizeMac(match.group(0)!);
    });

    final ipv4Pattern = RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
    scrubbed = scrubbed.replaceAllMapped(ipv4Pattern, (match) {
      return anonymizeIp(match.group(0)!);
    });

    final ipv6Pattern = RegExp(
      r'(?<![\dA-Fa-f:])(?:'
      r'(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?::(?:[0-9A-Fa-f]{1,4}:)*[0-9A-Fa-f]{1,4}'
      r'|'
      r'[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){3,}'
      r')(?![\dA-Fa-f:])',
    );
    scrubbed = scrubbed.replaceAllMapped(ipv6Pattern, (match) {
      return anonymizeIp(match.group(0)!);
    });

    return scrubbed;
  }
}
