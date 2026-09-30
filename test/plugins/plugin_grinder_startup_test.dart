import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';

void main() {
  test(
    'network Grinder initialization can take more than five seconds',
    () async {
      final service = PluginDeviceService();
      addTearDown(service.dispose);
      late PluginGrinder grinder;
      grinder = await _registerGrinder(service, (operation, payload) async {
        if (operation == PluginDeviceOperation.connect) {
          await Future<void>.delayed(const Duration(seconds: 6));
          grinder.publish({
            'state': 'idle',
          }, session: payload['session'] as String);
        }
        return const {};
      });

      fakeAsync((time) {
        var connected = false;
        Object? failure;
        grinder.onConnect().then<void>(
          (_) {
            connected = true;
          },
          onError: (Object error) {
            failure = error;
          },
        );
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 5));
        expect(connected, isFalse);
        expect(failure, isNull);
        time.elapse(const Duration(seconds: 1));
        expect(connected, isTrue);
        expect(failure, isNull);
      });
    },
  );

  test('network Grinder startup still times out after ten seconds', () async {
    final service = PluginDeviceService();
    addTearDown(service.dispose);
    late String session;
    final grinder = await _registerGrinder(service, (operation, payload) async {
      if (operation == PluginDeviceOperation.connect) {
        session = payload['session'] as String;
      }
      return const {};
    });

    fakeAsync((time) {
      var connected = false;
      Object? failure;
      grinder.onConnect().then<void>(
        (_) {
          connected = true;
        },
        onError: (Object error) {
          failure = error;
        },
      );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 9));
      expect(connected, isFalse);
      expect(failure, isNull);
      time.elapse(const Duration(seconds: 1));
      expect(connected, isFalse);
      expect(failure, isA<TimeoutException>());
      expect(
        () => grinder.publish({'state': 'idle'}, session: session),
        throwsA(
          isA<PluginDeviceException>().having(
            (error) => error.code,
            'code',
            'stale_session',
          ),
        ),
      );
    });
  });

  for (final scaleTimeout in const [
    Duration(seconds: 5),
    Duration(milliseconds: 20),
  ]) {
    test(
      'Grinder budget is independent of scale budget $scaleTimeout',
      () async {
        final service = PluginDeviceService(
          scaleInvocationTimeout: scaleTimeout,
        );
        addTearDown(service.dispose);
        final grinder = await _registerGrinder(
          service,
          (_, _) async => const {},
        );
        await service.register(
          pluginId: 'test',
          generation: 1,
          registrationHandle: 'scale',
          definition: const {
            'driverId': 'scale',
            'instanceId': 'one',
            'name': 'Scale',
          },
          driver: PluginDriverDeclaration(
            id: 'scale',
            type: PluginDriverType.scale,
          ),
          invoke: (_, _) async => const {},
        );
        final devices = await service.devices.first;
        final scale = devices.whereType<PluginScale>().single;
        expect(grinder.invocationTimeout, const Duration(seconds: 10));
        expect(scale.invocationTimeout, scaleTimeout);
      },
    );
  }
}

Future<PluginGrinder> _registerGrinder(
  PluginDeviceService service,
  PluginDeviceInvoker invoke,
) async {
  await service.register(
    pluginId: 'test',
    generation: 1,
    registrationHandle: 'grinder',
    definition: const {
      'driverId': 'grinder',
      'instanceId': 'one',
      'name': 'Grinder',
    },
    driver: PluginDriverDeclaration(
      id: 'grinder',
      type: PluginDriverType.grinder,
    ),
    invoke: invoke,
  );
  return (await service.devices.first).single as PluginGrinder;
}
