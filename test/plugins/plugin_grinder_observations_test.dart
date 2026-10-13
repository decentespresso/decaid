import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('observation declarations round-trip independently of commands', () {
    final driver = PluginDriverDeclaration.fromJson({
      'id': 'read-only',
      'type': 'grinder',
      'observations': ['setting', 'rpm'],
    });
    expect(driver.grinderObservations, GrinderObservation.values.toSet());
    expect(driver.grinderCapabilities, isEmpty);
    expect(driver.controls, isEmpty);
    expect(driver.toJson()['observations'], ['setting', 'rpm']);
    for (final observations in [
      null,
      'setting',
      [1],
      ['vendor'],
      ['rpm', 'rpm'],
    ]) {
      expect(
        () => PluginDriverDeclaration.fromJson({
          'id': 'bad',
          'type': 'grinder',
          'observations': observations,
        }),
        throwsFormatException,
      );
    }
    for (final type in ['scale', 'sensor']) {
      expect(
        () => PluginDriverDeclaration.fromJson({
          'id': 'bad',
          'type': type,
          'observations': ['setting'],
        }),
        throwsFormatException,
      );
    }
    expect(
      () => PluginDriverDeclaration.fromJson({
        'id': 'bad',
        'type': 'grinder',
        'observations': ['setting'],
        'controls': {
          'grindSetting': {'kind': 'opaque'},
        },
      }),
      throwsFormatException,
    );
  });

  test(
    'read-only observations are self-contained and session fenced',
    () async {
      final sessions = <String, String>{};
      final calls = <String>[];
      PluginGrinder create(String id, Set<GrinderObservation> observations) {
        late PluginGrinder grinder;
        grinder = PluginGrinder(
          deviceId: id,
          name: id,
          capabilities: const {},
          observations: observations,
          invoke: (operation, payload) async {
            calls.add('$id:${operation.name}');
            if (operation == PluginDeviceOperation.connect) {
              sessions[id] = payload['session'] as String;
              grinder.publish({'state': 'idle'}, session: sessions[id]);
            }
            return {};
          },
        );
        return grinder;
      }

      final one = create('one', GrinderObservation.values.toSet());
      final two = create('two', {GrinderObservation.rpm});
      final controller = GrinderController();
      addTearDown(() async {
        await controller.dispose();
        await one.dispose();
        await two.dispose();
      });
      await one.onConnect();
      await two.onConnect();
      await controller.adoptGrinder(one);
      one.publish({
        'state': 'idle',
        'observedSetting': 'espresso/A',
        'observedRpm': 0,
      }, session: sessions['one']);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.currentSnapshot!.toJson(),
        containsPair('observedSetting', 'espresso/A'),
      );
      expect(controller.currentSnapshot!.observedRpm, 0);
      expect(one.controls, isEmpty);
      final before = List<String>.of(calls);
      for (final command in [
        () => controller.setGrindSetting('12'),
        () => controller.setRpm(900),
        () => one.setGrindSetting('12'),
        () => one.setRpm(900),
      ]) {
        await expectLater(
          Future.sync(command),
          throwsA(
            isA<GrinderOperationException>().having(
              (e) => e.code,
              'code',
              'unsupported_operation',
            ),
          ),
        );
      }
      expect(calls, before);
      for (final invalid in <Map<String, dynamic>>[
        {},
        {'observedSetting': 'x'},
        {'state': 'bad'},
        {'state': 'idle', 'observedSetting': null},
        {'state': 'idle', 'observedSetting': 1},
        {'state': 'idle', 'observedSetting': {}},
        for (final rpm in [null, -1, 1.5, '900', double.nan, double.infinity])
          {'state': 'idle', 'observedRpm': rpm},
        {'state': 'idle', 'observedVendor': true},
        {'state': 'idle', 'setting': 'x'},
        {'state': 'idle', 'rpm': 900},
      ]) {
        expect(
          () => one.publish(invalid, session: sessions['one']),
          throwsA(
            isA<PluginDeviceException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );
        expect((await one.currentSnapshot.first).observedSetting, 'espresso/A');
      }
      expect(
        () => two.publish({
          'state': 'idle',
          'observedSetting': 'x',
        }, session: sessions['two']),
        throwsA(isA<PluginDeviceException>()),
      );
      expect(
        () => one.publishInfo({
          'controls': {
            'grindSetting': {'kind': 'opaque'},
          },
        }, session: sessions['one']),
        throwsA(isA<PluginDeviceException>()),
      );
      one.publish({'state': 'idle'}, session: sessions['one']);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.currentSnapshot!.toJson(),
        isNot(contains('observedSetting')),
      );
      expect(
        controller.currentSnapshot!.toJson(),
        isNot(contains('observedRpm')),
      );
      final old = sessions['one'];
      await controller.adoptGrinder(two);
      two.publish({
        'state': 'idle',
        'observedRpm': 700,
      }, session: sessions['two']);
      await Future<void>.delayed(Duration.zero);
      void delayed() => one.publish({
        'state': 'idle',
        'observedSetting': 'late',
      }, session: old);
      expect(
        delayed,
        throwsA(
          isA<PluginDeviceException>().having(
            (e) => e.code,
            'code',
            'stale_session',
          ),
        ),
      );
      expect(controller.currentSnapshot!.observedRpm, 700);
      await one.onConnect();
      expect(sessions['one'], isNot(old));
      expect(delayed, throwsA(isA<PluginDeviceException>()));
      await controller.adoptGrinder(one);
      expect(controller.currentSnapshot!.observedSetting, isNull);
      await one.dispose();
      expect(
        () => one.publish({
          'state': 'idle',
          'observedRpm': 99,
        }, session: sessions['one']),
        throwsA(isA<PluginDeviceException>()),
      );
    },
  );
}
