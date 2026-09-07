import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';

void main() {
  test(
    'immediate disconnect cancels initialization before readiness',
    () async {
      final initialization = Completer<Map<String, dynamic>>();
      final operations = <PluginDeviceOperation>[];
      final scale = PluginScale(
        deviceId: 'scale',
        name: 'Scale',
        capabilities: {},
        invoke: (operation, payload) async {
          operations.add(operation);
          if (operation == PluginDeviceOperation.connect) {
            return initialization.future;
          }
          return {};
        },
      );
      final connecting = scale.onConnect();
      final rejected = expectLater(
        connecting,
        throwsA(isA<PluginDeviceException>()),
      );
      await scale.disconnect();
      await rejected;
      expect(operations, [
        PluginDeviceOperation.connect,
        PluginDeviceOperation.disconnect,
      ]);
      initialization.complete({});
      await scale.dispose();
    },
  );

  test(
    'readiness weight reaches activated ScaleController once with unknown battery',
    () async {
      late PluginScale scale;
      String? firstSession;
      scale = PluginScale(
        deviceId: 'plugin:test:scale:memory',
        name: 'Memory',
        capabilities: {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            firstSession = payload['session'] as String;
            scale.publish({'weight': -1.25}, session: firstSession);
          }
          return {};
        },
      );
      final controller = ScaleController();
      final weights = <double>[];
      final listener = controller.weightSnapshot.listen(
        (sample) => weights.add(sample.weight),
      );
      await controller.connectToScale(scale);
      await Future<void>.delayed(Duration.zero);
      expect(weights, [-1.25]);
      expect(controller.currentWeightSnapshot!.battery, isNull);
      await scale.disconnect();
      await expectLater(scale.tare(), throwsA(isA<PluginDeviceException>()));
      expect(
        () => scale.publish({'weight': 2}, session: firstSession),
        throwsA(isA<PluginDeviceException>()),
      );
      await listener.cancel();
      controller.dispose();
      await scale.dispose();
    },
  );

  test(
    'reconnect rejects old-session publications and optional commands are explicit',
    () async {
      late PluginScale scale;
      final sessions = <String>[];
      final commands = <String>[];
      scale = PluginScale(
        deviceId: 'scale',
        name: 'Scale',
        capabilities: {PluginScaleCapability.tare},
        invoke: (operation, payload) async {
          commands.add(operation.name);
          if (operation == PluginDeviceOperation.connect) {
            sessions.add(payload['session'] as String);
            scale.publish({'weight': 1}, session: sessions.last);
          }
          return {};
        },
      );
      await scale.onConnect();
      await scale.tare();
      await expectLater(
        scale.startTimer(),
        throwsA(
          isA<PluginDeviceException>().having(
            (e) => e.code,
            'code',
            'unsupported_operation',
          ),
        ),
      );
      await scale.disconnect();
      await scale.onConnect();
      expect(sessions.toSet(), hasLength(2));
      expect(
        () => scale.publish({'weight': 50}, session: sessions.first),
        throwsA(isA<PluginDeviceException>()),
      );
      expect(commands.where((name) => name == 'tare'), hasLength(1));
      await scale.disconnect();
      await scale.dispose();
    },
  );

  test(
    'invalid weights and undeclared telemetry cannot satisfy readiness',
    () async {
      late PluginScale scale;
      scale = PluginScale(
        deviceId: 'scale',
        name: 'Scale',
        capabilities: {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            for (final snapshot in <Map<String, dynamic>>[
              {},
              {'weight': double.nan},
              {'weight': double.infinity},
              {'weight': '1'},
              {'weight': 1, 'battery': 80},
              {'weight': 1, 'flow': 2},
              {'weight': 1, 'timestamp': 'forged'},
            ]) {
              expect(
                () => scale.publish(
                  snapshot,
                  session: payload['session'] as String,
                ),
                throwsA(isA<PluginDeviceException>()),
              );
            }
            scale.publish({'weight': 0}, session: payload['session'] as String);
          }
          return {};
        },
      );
      await scale.onConnect();
      await scale.disconnect();
      await scale.dispose();
    },
  );
}
