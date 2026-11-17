import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('manifest validates fixed descriptors and same-plugin surfaces', () {
    Map<String, dynamic> manifest(dynamic controls, dynamic surfaces) => {
      'id': 'example',
      'name': 'Example',
      'author': '',
      'description': '',
      'version': '1',
      'apiVersion': 1,
      'permissions': ['api'],
      'settings': <String, dynamic>{},
      'api': [
        {'id': 'device-settings', 'type': 'http', 'data': <String, dynamic>{}},
      ],
      'drivers': [
        {
          'id': 'grinder',
          'type': 'grinder',
          'capabilities': ['grindSetting', 'rpmControl'],
          ...?(controls == null ? null : {'controls': controls}),
          ...?(surfaces == null ? null : {'surfaces': surfaces}),
        },
      ],
    };
    final accepted = PluginManifest.fromJson(
      manifest(
        {
          'grindSetting': {'kind': 'numeric', 'min': 1, 'max': 80, 'step': 1},
          'rpmControl': {'kind': 'numeric', 'min': 60, 'max': 120},
        },
        [
          {'id': 'settings', 'role': 'settings', 'endpoint': 'device-settings'},
        ],
      ),
    );
    expect(
      accepted.drivers.single.controls['grindSetting']!.toJson()['max'],
      80,
    );
    expect(accepted.drivers.single.surfaces.single.id, 'settings');
    final sensor = manifest(null, [
      {'id': 'settings', 'role': 'settings', 'endpoint': 'device-settings'},
    ]);
    final sensorDriver = (sensor['drivers'] as List).single as Map;
    sensorDriver
      ..['type'] = 'sensor'
      ..remove('capabilities');
    expect(
      PluginManifest.fromJson(sensor).drivers.single.surfaces.single.role,
      'settings',
    );
    final missingCapability = manifest({
      'grindSetting': {'kind': 'opaque'},
    }, null);
    ((missingCapability['drivers'] as List).single as Map)['capabilities'] = [
      'rpmControl',
    ];
    expect(
      () => PluginManifest.fromJson(missingCapability),
      throwsFormatException,
    );
    final noApi = manifest(null, [
      {'id': 'settings', 'role': 'settings', 'endpoint': 'device-settings'},
    ])..['permissions'] = <String>[];
    expect(() => PluginManifest.fromJson(noApi), throwsFormatException);
    final notHttp =
        manifest(null, [
            {
              'id': 'settings',
              'role': 'settings',
              'endpoint': 'device-settings',
            },
          ])
          ..['api'] = [
            {
              'id': 'device-settings',
              'type': 'websocket',
              'data': <String, dynamic>{},
            },
          ];
    expect(() => PluginManifest.fromJson(notHttp), throwsFormatException);
    final shadowedHttp =
        manifest(null, [
            {
              'id': 'settings',
              'role': 'settings',
              'endpoint': 'device-settings',
            },
          ])
          ..['api'] = [
            {
              'id': 'device-settings',
              'type': 'websocket',
              'data': <String, dynamic>{},
            },
            {
              'id': 'device-settings',
              'type': 'http',
              'data': <String, dynamic>{},
            },
          ];
    expect(() => PluginManifest.fromJson(shadowedHttp), throwsFormatException);
    expect(
      () => PluginManifest.fromJson(manifest({'rpmControl': null}, null)),
      throwsFormatException,
    );
    for (final controls in [
      {
        'startStop': {'kind': 'opaque'},
      },
      {
        'grindSetting': {'kind': 'numeric', 'min': 1, 'max': 80, 'extra': 1},
      },
      {
        'grindSetting': {'kind': 'numeric', 'min': 90, 'max': 80},
      },
      {
        'grindSetting': {'kind': 'numeric', 'min': double.infinity, 'max': 80},
      },
      {
        'grindSetting': {
          'kind': 'enumerated',
          'values': ['a', 'a'],
        },
      },
      {
        'rpmControl': {'kind': 'numeric', 'min': 1.5, 'max': 100},
      },
      {
        'rpmControl': {'kind': 'opaque'},
      },
      {
        'grindSetting': {'kind': 'enumerated', 'values': []},
      },
      {
        'grindSetting': {'kind': 'numeric', 'min': 1, 'max': 2, 'step': null},
      },
      {
        'rpmControl': {'kind': 'numeric', 'min': -1, 'max': 2},
      },
      {
        'rpmControl': {'kind': 'numeric', 'min': 1, 'max': 2, 'step': 0.5},
      },
    ]) {
      expect(
        () => PluginManifest.fromJson(manifest(controls, null)),
        throwsFormatException,
        reason: '$controls',
      );
    }
    for (final surfaces in [
      [
        {'id': '../bad', 'role': 'settings', 'endpoint': 'device-settings'},
      ],
      [
        {'id': 'settings', 'role': 'settings', 'endpoint': 'source'},
      ],
      [
        {'id': 'x', 'role': 'settings', 'endpoint': 'foreign'},
      ],
      [
        {'id': 'x', 'role': 'unknown', 'endpoint': 'device-settings'},
      ],
      [
        {
          'id': 'x',
          'role': 'settings',
          'endpoint': 'device-settings',
          'href': 'https://evil',
        },
      ],
      [
        {'id': 'x', 'role': 'settings', 'endpoint': 'device-settings'},
        {'id': 'x', 'role': 'diagnostics', 'endpoint': 'device-settings'},
      ],
      [
        {'id': 'x', 'role': 'settings', 'endpoint': 'device-settings'},
        {'id': 'y', 'role': 'settings', 'endpoint': 'device-settings'},
      ],
      List.generate(
        9,
        (i) => {
          'id': '$i',
          'role': 'diagnostics',
          'endpoint': 'device-settings',
        },
      ),
    ]) {
      for (final type in ['grinder', 'sensor']) {
        final candidate = manifest(null, surfaces);
        final driver = (candidate['drivers'] as List).single as Map;
        driver['type'] = type;
        if (type == 'sensor') driver.remove('capabilities');
        expect(
          () => PluginManifest.fromJson(candidate),
          throwsFormatException,
          reason: '$type $surfaces',
        );
      }
    }
    for (final route in ['settings', 'source', 'enable', 'disable']) {
      final candidate = manifest(null, [
        {'id': 'safe', 'role': 'diagnostics', 'endpoint': route},
      ]);
      candidate['api'] = [
        {'id': route, 'type': 'http', 'data': <String, dynamic>{}},
      ];
      expect(
        () => PluginManifest.fromJson(candidate),
        throwsFormatException,
        reason: 'Reserved same-plugin HTTP endpoint $route',
      );
    }
  });

  test(
    'controller validates effective descriptors without rewriting commands',
    () async {
      late PluginGrinder grinder;
      final requests = <String>[];
      grinder = PluginGrinder(
        deviceId: 'opaque:% ?&',
        name: 'Grinder',
        capabilities: {
          PluginGrinderCapability.grindSetting,
          PluginGrinderCapability.rpmControl,
        },
        controls: {
          'grindSetting': GrinderControlDescriptor.fromJson('grindSetting', {
            'kind': 'numeric',
            'min': 1,
            'max': 80,
            'step': 1,
          }),
          'rpmControl': GrinderControlDescriptor.fromJson('rpmControl', {
            'kind': 'numeric',
            'min': 60,
            'max': 120,
          }),
        },
        invoke: (operation, payload) async {
          if (operation.name == 'connect') {
            grinder.publish({
              'state': 'idle',
            }, session: payload['session'] as String);
          } else if (operation.name == 'setGrindSetting' ||
              operation.name == 'setRpm') {
            requests.add(
              '${operation.name}:${payload['setting'] ?? payload['rpm']}',
            );
          }
          return {};
        },
      );
      final controller = GrinderController();
      addTearDown(() async {
        await controller.dispose();
        await grinder.dispose();
      });
      await controller.connectToGrinder(grinder);
      for (final setting in ['NaN', 'Infinity', 'abc', '0', '81']) {
        expect(
          () => controller.setGrindSetting(setting),
          throwsA(
            isA<GrinderOperationException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );
      }
      for (final rpm in [59, 121]) {
        expect(
          () => controller.setRpm(rpm),
          throwsA(
            isA<GrinderOperationException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );
      }
      expect(requests, isEmpty);
      await controller.setGrindSetting('1.5');
      await controller.setGrindSetting('80');
      await controller.setRpm(60);
      await controller.setRpm(120);
      expect(requests, [
        'setGrindSetting:1.5',
        'setGrindSetting:80',
        'setRpm:60',
        'setRpm:120',
      ]);
    },
  );
}
