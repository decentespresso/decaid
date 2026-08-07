import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/hds_wifi_protocol.dart';

void main() {
  group('HdsWifiFrame.parse', () {
    test('untyped grams frame is a weight sample', () {
      final f = HdsWifiFrame.parse('{"grams": 25.66, "ms": 12345}')!;
      expect(f.type, isNull);
      expect(f.grams, closeTo(25.66, 0.001));
      expect(f.hasWeight, isTrue);
      expect(f.confirmsHds, isTrue);
    });

    test('status frame carries battery and charging', () {
      final f = HdsWifiFrame.parse(
        '{"type":"status","grams":0.0,"battery_percent":87,'
        '"charging":true,"timer_running":false,"display_on":true}',
      )!;
      expect(f.isStatus, isTrue);
      expect(f.batteryPercent, 87);
      expect(f.charging, isTrue);
      expect(f.timerRunning, isFalse);
      expect(f.confirmsHds, isTrue);
    });

    test('integer grams is coerced to double', () {
      final f = HdsWifiFrame.parse('{"grams": 18}')!;
      expect(f.grams, 18.0);
      expect(f.hasWeight, isTrue);
    });

    test('button frame parses but is not weight or status', () {
      final f = HdsWifiFrame.parse(
        '{"type":"button","button_number":1,"press":"short"}',
      )!;
      expect(f.type, 'button');
      expect(f.hasWeight, isFalse);
      expect(f.confirmsHds, isFalse);
    });

    test('power_off event is recognized', () {
      final f = HdsWifiFrame.parse(
        '{"type":"power","event":"power_off","reason":"button"}',
      )!;
      expect(f.isPowerOff, isTrue);
    });

    test('rate and error frames parse and are ignorable', () {
      expect(
        HdsWifiFrame.parse('{"type":"rate","interval_ms":100}')!.hasWeight,
        isFalse,
      );
      final err = HdsWifiFrame.parse(
        '{"type":"error","code":1,"message":"x"}',
      )!;
      expect(err.type, 'error');
      expect(err.hasWeight, isFalse);
    });

    test('unknown type parses without error and yields no weight', () {
      final f = HdsWifiFrame.parse('{"type":"future_thing","foo":42}')!;
      expect(f.hasWeight, isFalse);
      expect(f.confirmsHds, isFalse);
    });

    test('malformed JSON returns null', () {
      expect(HdsWifiFrame.parse('{not json'), isNull);
      expect(HdsWifiFrame.parse('grams=1'), isNull);
    });

    test('empty / blank input returns null', () {
      expect(HdsWifiFrame.parse(''), isNull);
      expect(HdsWifiFrame.parse('   '), isNull);
    });

    test('non-object JSON returns null', () {
      expect(HdsWifiFrame.parse('[1,2,3]'), isNull);
      expect(HdsWifiFrame.parse('42'), isNull);
      expect(HdsWifiFrame.parse('"hello"'), isNull);
    });

    test('wrong-typed fields yield null fields, never throw', () {
      // A field of the wrong JSON type must not throw (a stray frame can't drop
      // the connection) — the bad field is treated as absent.
      final f = HdsWifiFrame.parse(
        '{"type":5,"charging":1,"timer_running":"yes","grams":12.0}',
      );
      expect(f, isNotNull);
      expect(f!.type, isNull);
      expect(f.charging, isNull);
      expect(f.timerRunning, isNull);
      expect(f.grams, 12.0);
    });
  });
}
