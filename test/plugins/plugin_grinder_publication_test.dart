import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('failed startup drops published session overrides', () async {
    late PluginGrinder grinder;
    grinder = PluginGrinder(
      deviceId: 'startup',
      name: 'Startup',
      pluginId: 'example',
      capabilities: {PluginGrinderCapability.grindSetting},
      controls: {
        'grindSetting': GrinderControlDescriptor.fromJson('grindSetting', {
          'kind': 'opaque',
        }),
      },
      surfaces: const [
        PluginDeviceSurface(
          id: 'settings',
          role: 'settings',
          endpoint: 'device-settings',
        ),
      ],
      invoke: (operation, payload) async {
        if (operation.name == 'connect') {
          grinder.publish({
            'state': 'idle',
            'controls': {
              'grindSetting': {
                'kind': 'enumerated',
                'values': ['filter'],
              },
            },
            'surfaces': [],
          }, session: payload['session'] as String);
          throw StateError('startup failed');
        }
        return {};
      },
    );
    addTearDown(grinder.dispose);
    await expectLater(grinder.onConnect(), throwsStateError);
    expect(grinder.controls['grindSetting']!.kind, 'opaque');
    expect(grinder.surfaces, hasLength(1));
  });

  test(
    'session overrides replace, clear and preserve independently per device',
    () async {
      final sessions = <String, String>{};
      PluginGrinder create(String id) {
        late PluginGrinder grinder;
        grinder = PluginGrinder(
          deviceId: id,
          name: id,
          pluginId: 'example',
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
          },
          surfaces: [
            PluginDeviceSurface(
              id: 'settings',
              role: 'settings',
              endpoint: 'device-settings',
            ),
            PluginDeviceSurface(
              id: 'diagnostics',
              role: 'diagnostics',
              endpoint: 'device-settings',
            ),
          ],
          invoke: (operation, payload) async {
            if (operation.name == 'connect') {
              sessions[id] = payload['session'] as String;
              grinder.publish({'state': 'idle'}, session: sessions[id]);
            }
            return {};
          },
        );
        return grinder;
      }

      final one = create('one:% +?&/');
      final two = create('two');
      final controller = GrinderController();
      addTearDown(() async {
        await controller.dispose();
        await one.dispose();
        await two.dispose();
      });
      await one.onConnect();
      await two.onConnect();
      final href = Uri.parse(one.surfaces.first['href']!);
      expect(href.path, '/api/v1/plugins/example/device-settings');
      expect(href.queryParameters, {'ui': '1', 'deviceId': one.deviceId});
      expect(one.surfaces.first['href'], isNot(contains('deviceId=one:%')));
      expect(two.surfaces.first['href'], isNot(one.surfaces.first['href']));
      one.publish({
        'controls': {
          'grindSetting': {
            'kind': 'enumerated',
            'values': ['filter', 'espresso'],
          },
          'rpmControl': {'kind': 'numeric', 'min': 60, 'max': 120},
        },
        'surfaces': ['settings'],
      }, session: sessions[one.deviceId]);
      await controller.adoptGrinder(one);
      expect(one.controls['grindSetting']!.kind, 'enumerated');
      expect(one.surfaces.map((s) => s['id']), ['settings']);
      expect(two.controls['grindSetting']!.kind, 'numeric');
      expect(two.surfaces, hasLength(2));
      expect(
        () => controller.setGrindSetting('Filter'),
        throwsA(
          isA<GrinderOperationException>().having(
            (e) => e.code,
            'code',
            'invalid_argument',
          ),
        ),
      );
      expect(
        () => one.publish({
          'controls': {
            'rpmControl': {'kind': 'opaque'},
          },
          'surfaces': ['diagnostics'],
        }, session: sessions[one.deviceId]),
        throwsA(
          isA<PluginDeviceException>().having(
            (e) => e.code,
            'code',
            'invalid_argument',
          ),
        ),
      );
      expect(one.controls['rpmControl']!.min, 60);
      expect(one.surfaces.single['id'], 'settings');
      expect(controller.currentConnectionState.name, 'connected');
      expect(controller.currentSnapshot?.state, GrinderState.idle);
      await controller.setGrindSetting('filter');
      for (final forbidden in ['foreign', 'settings/evil']) {
        expect(
          () => one.publish({
            'surfaces': [forbidden],
          }, session: sessions[one.deviceId]),
          throwsA(
            isA<PluginDeviceException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );
        expect(one.surfaces.single['id'], 'settings');
        expect(one.controls['grindSetting']!.kind, 'enumerated');
      }
      one.publish({
        'controls': {'grindSetting': null},
        'surfaces': [],
      }, session: sessions[one.deviceId]);
      expect(one.controls['grindSetting']!.kind, 'numeric');
      expect(one.controls['rpmControl']!.min, 60);
      expect(one.surfaces, isEmpty);
      one.publish({
        'controls': null,
        'surfaces': null,
      }, session: sessions[one.deviceId]);
      expect(one.controls.keys, ['grindSetting']);
      expect(one.surfaces, hasLength(2));
      one.publish({
        'controls': {
          'grindSetting': {'kind': 'opaque'},
        },
        'surfaces': [],
      }, session: sessions[one.deviceId]);
      expect(one.controls['grindSetting']!.kind, 'opaque');
      expect(one.surfaces, isEmpty);
      final oldSession = sessions[one.deviceId];
      await one.disconnect();
      expect(one.controls['grindSetting']!.kind, 'numeric');
      expect(one.surfaces, hasLength(2));
      await one.onConnect();
      expect(
        () => one.publish({
          'controls': {
            'grindSetting': {'kind': 'opaque'},
          },
        }, session: oldSession),
        throwsA(
          isA<PluginDeviceException>().having(
            (e) => e.code,
            'code',
            'stale_session',
          ),
        ),
      );
      expect(one.controls['grindSetting']!.kind, 'numeric');
      await controller.adoptGrinder(one);
      one.publish({
        'controls': {
          'grindSetting': {'kind': 'opaque'},
        },
        'surfaces': [],
      }, session: sessions[one.deviceId]);
      await controller.adoptGrinder(two);
      expect(controller.connectedGrinder(), same(two));
      expect(two.controls['grindSetting']!.kind, 'numeric');
      expect(two.surfaces, hasLength(2));
      expect(one.controls['grindSetting']!.kind, 'numeric');
      expect(one.surfaces, hasLength(2));
      two.publish({
        'controls': {
          'grindSetting': {'kind': 'opaque'},
        },
        'surfaces': [],
      }, session: sessions[two.deviceId]);
      await two.dispose();
      expect(two.controls['grindSetting']!.kind, 'numeric');
      expect(two.surfaces, hasLength(2));
    },
  );
}
