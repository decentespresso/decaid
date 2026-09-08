import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test(
    'complete absent name is negative while unavailable name is unknown',
    () {
      final matcher = PluginBleMatcher.fromJson({
        'name': {'exact': 'bookoo'},
      });
      expect(matcher.evaluate(nameComplete: true), PluginBleMatch.noMatch);
      expect(
        matcher.evaluate(nameComplete: false),
        PluginBleMatch.indeterminate,
      );
    },
  );

  test(
    'normalizes Bluetooth UUID widths without accepting malformed input',
    () {
      for (final value in [
        '0FFE',
        '00000ffe',
        '00000FFE-0000-1000-8000-00805F9B34FB',
      ]) {
        expect(
          normalizePluginBleUuid(value),
          '00000ffe-0000-1000-8000-00805f9b34fb',
        );
      }
      for (final value in [
        '',
        'fff',
        '0x0ffe',
        ' 0ffe',
        '0ffe ',
        '00000ffe00001000800000805f9b34fb',
      ]) {
        expect(() => normalizePluginBleUuid(value), throwsFormatException);
      }
    },
  );

  test('rejects unconstrained, malformed and unknown matcher predicates', () {
    for (final json in <Object?>[
      null,
      'bookoo',
      {},
      {'rssi': -80},
      {'name': {}},
      {
        'name': {'exact': ''},
      },
      {
        'name': {'exact': 'bookoo', 'prefix': 'b'},
      },
      {
        'name': {'regex': '.*'},
      },
      {'serviceUuids': []},
      {
        'serviceUuids': ['nope'],
      },
      {
        'serviceUuids': [123],
      },
      {'serviceUuids': '0ffe'},
    ]) {
      expect(
        () => PluginBleMatcher.fromJson(json),
        throwsFormatException,
        reason: '$json',
      );
    }
  });

  test('case insensitive names are not trimmed', () {
    for (final predicate in ['exact', 'prefix', 'contains']) {
      final matcher = PluginBleMatcher.fromJson({
        'name': {predicate: 'BoOkOo'},
      });
      expect(matcher.evaluate(name: 'BOOKOO'), PluginBleMatch.match);
      expect(matcher.evaluate(name: 'different'), PluginBleMatch.noMatch);
      expect(matcher.evaluate(), PluginBleMatch.indeterminate);
    }
    final exact = PluginBleMatcher.fromJson({
      'name': {'exact': 'bookoo'},
    });
    expect(exact.evaluate(name: ' bookoo'), PluginBleMatch.noMatch);
    expect(exact.evaluate(name: ''), PluginBleMatch.noMatch);
  });

  test('AND preserves unknown evidence but proven false wins', () {
    final matcher = PluginBleMatcher.fromJson({
      'name': {'prefix': 'bookoo'},
      'serviceUuids': ['0ffe', '180f'],
    });
    expect(matcher.evaluate(name: 'bookoo'), PluginBleMatch.indeterminate);
    expect(
      matcher.evaluate(serviceUuids: ['180f']),
      PluginBleMatch.indeterminate,
    );
    expect(matcher.evaluate(name: 'other'), PluginBleMatch.noMatch);
    expect(
      matcher.evaluate(name: 'bookoo', serviceUuids: []),
      PluginBleMatch.noMatch,
    );
    expect(
      matcher.evaluate(name: 'bookoo', serviceUuids: ['180f']),
      PluginBleMatch.match,
    );
    expect(
      matcher.evaluate(
        name: 'bookoo',
        serviceUuids: ['1810'],
        servicesComplete: false,
      ),
      PluginBleMatch.indeterminate,
    );
    expect(
      matcher.evaluate(
        name: 'bookoo',
        serviceUuids: ['180f'],
        servicesComplete: false,
      ),
      PluginBleMatch.match,
    );
  });

  test('service-only matching accepts nameless advertisements', () {
    final matcher = PluginBleMatcher.fromJson({
      'serviceUuids': ['0ffe'],
    });
    expect(matcher.evaluate(serviceUuids: ['00000ffe']), PluginBleMatch.match);
    expect(matcher.evaluate(), PluginBleMatch.indeterminate);
  });

  test('BLE permission remains separate from a driver declaration', () {
    expect(PluginPermissions.fromString('transport.ble'), isNotNull);
    final driver = PluginDriverDeclaration.fromJson({
      'id': 'bookoo',
      'type': 'scale',
      'capabilities': ['battery', 'tare', 'timerControl', 'disconnectToSleep'],
      'ble': {
        'match': {
          'name': {'contains': 'bookoo'},
        },
      },
    });
    expect(driver.type.name, 'scale');
    expect(driver.ble!.evaluate(name: 'BOOKOO Mini'), PluginBleMatch.match);
    expect(
      PluginDriverDeclaration.fromJson(driver.toJson()).toJson(),
      driver.toJson(),
    );
  });

  test('validates Scale capabilities and one BLE declaration policy', () {
    for (final capabilities in [
      ['unknown'],
      ['tare', 'tare'],
      ['displayControl', 'disconnectToSleep'],
      'tare',
    ]) {
      expect(
        () => PluginDriverDeclaration.fromJson({
          'id': 'scale',
          'type': 'scale',
          'capabilities': capabilities,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => PluginDriverDeclaration.fromJson({
        'id': 'sensor',
        'type': 'sensor',
        'capabilities': ['tare'],
      }),
      throwsFormatException,
    );
    expect(
      () => parsePluginDrivers([
        for (final id in ['one', 'two'])
          {
            'id': id,
            'type': 'sensor',
            'ble': {
              'match': {
                'name': {'exact': id},
              },
            },
          },
      ]),
      throwsFormatException,
    );
    expect(
      parsePluginDrivers([
        {'id': 'scale', 'type': 'scale'},
        {'id': 'sensor', 'type': 'sensor'},
      ]),
      hasLength(2),
    );
  });
}
