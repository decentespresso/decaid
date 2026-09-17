import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  test('valid publication gates readiness and commands carry values', () async {
    late PluginGrinder grinder;
    late String session;
    final calls = <(PluginDeviceOperation, Map<String, dynamic>)>[];
    grinder = PluginGrinder(
      deviceId: 'plugin:test:grinder:one',
      name: 'Test grinder',
      capabilities: const {
        PluginGrinderCapability.startStop,
        PluginGrinderCapability.grindSetting,
        PluginGrinderCapability.rpmControl,
      },
      invoke: (operation, payload) async {
        calls.add((operation, payload));
        if (operation == PluginDeviceOperation.connect) {
          session = payload['session'] as String;
          grinder.publish({
            'state': 'idle',
            'setting': '12.3',
            'rpm': 1200,
          }, session: session);
        }
        return const {};
      },
    );
    addTearDown(grinder.dispose);

    final snapshot = grinder.currentSnapshot.first;
    await grinder.onConnect();
    expect(await snapshot, isA<GrinderSnapshot>());
    expect(grinder.capabilities, GrinderCapability.values.toSet());

    await grinder.start();
    await grinder.stop();
    await grinder.setGrindSetting('13');
    await grinder.setRpm(900);

    expect(
      calls
          .where((call) => call.$1 == PluginDeviceOperation.setGrindSetting)
          .single
          .$2,
      {'session': session, 'setting': '13'},
    );
    expect(
      calls.where((call) => call.$1 == PluginDeviceOperation.setRpm).single.$2,
      {'session': session, 'rpm': 900},
    );
  });

  test(
    'invalid and undeclared snapshot fields cannot satisfy readiness',
    () async {
      late PluginGrinder grinder;
      grinder = PluginGrinder(
        deviceId: 'grinder',
        name: 'Grinder',
        capabilities: const {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            final session = payload['session'] as String;
            for (final snapshot in <Map<String, dynamic>>[
              {},
              {'state': 'missing'},
              {'state': 1},
              {'state': 'idle', 'setting': '12'},
              {'state': 'idle', 'setting': null},
              {'state': 'idle', 'rpm': 1200},
              {'state': 'idle', 'rpm': null},
              {'state': 'idle', 'vendor': true},
              {'state': 'idle', 'timestamp': 'forged'},
            ]) {
              expect(
                () => grinder.publish(snapshot, session: session),
                throwsA(
                  isA<PluginDeviceException>().having(
                    (error) => error.code,
                    'code',
                    'invalid_argument',
                  ),
                ),
              );
            }
            grinder.publish({'state': 'unknown'}, session: session);
          }
          return const {};
        },
      );
      addTearDown(grinder.dispose);

      await grinder.onConnect();
    },
  );

  test('unsupported operations do not invoke plugin handlers', () async {
    late PluginGrinder grinder;
    final calls = <PluginDeviceOperation>[];
    grinder = PluginGrinder(
      deviceId: 'grinder',
      name: 'Grinder',
      capabilities: const {},
      invoke: (operation, payload) async {
        calls.add(operation);
        if (operation == PluginDeviceOperation.connect) {
          grinder.publish({
            'state': 'idle',
          }, session: payload['session'] as String);
        }
        return const {};
      },
    );
    addTearDown(grinder.dispose);
    await grinder.onConnect();

    for (final operation in <Future<void> Function()>[
      grinder.start,
      grinder.stop,
      () => grinder.setGrindSetting('12'),
      () => grinder.setRpm(1200),
    ]) {
      await expectLater(
        operation(),
        throwsA(
          isA<GrinderOperationException>().having(
            (error) => error.code,
            'code',
            'unsupported_operation',
          ),
        ),
      );
    }
    expect(calls, [PluginDeviceOperation.connect]);
  });

  test('negative RPM does not invoke the plugin handler', () async {
    late PluginGrinder grinder;
    final calls = <PluginDeviceOperation>[];
    grinder = PluginGrinder(
      deviceId: 'grinder',
      name: 'Grinder',
      capabilities: const {PluginGrinderCapability.rpmControl},
      invoke: (operation, payload) async {
        calls.add(operation);
        if (operation == PluginDeviceOperation.connect) {
          grinder.publish({
            'state': 'idle',
          }, session: payload['session'] as String);
        }
        return const {};
      },
    );
    addTearDown(grinder.dispose);
    await grinder.onConnect();

    await expectLater(
      grinder.setRpm(-1),
      throwsA(
        isA<GrinderOperationException>().having(
          (error) => error.code,
          'code',
          'invalid_argument',
        ),
      ),
    );
    expect(calls, [PluginDeviceOperation.connect]);
  });

  test(
    'reconnect creates a new session and rejects stale publications',
    () async {
      late PluginGrinder grinder;
      final sessions = <String>[];
      grinder = PluginGrinder(
        deviceId: 'grinder',
        name: 'Grinder',
        capabilities: const {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            sessions.add(payload['session'] as String);
            grinder.publish({'state': 'idle'}, session: sessions.last);
          }
          return const {};
        },
      );
      addTearDown(grinder.dispose);

      await grinder.onConnect();
      await grinder.disconnect();
      await grinder.onConnect();

      expect(sessions.toSet(), hasLength(2));
      expect(
        () => grinder.publish({'state': 'grinding'}, session: sessions.first),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.code,
            'code',
            'stale_session',
          ),
        ),
      );
    },
  );
}
