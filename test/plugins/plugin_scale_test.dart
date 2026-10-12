import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';

void main() {
  group('Scale session info', () {
    late PluginScale scale;
    late String session;

    setUp(() async {
      scale = PluginScale(
        deviceId: 'info-scale',
        name: 'Info Scale',
        capabilities: {PluginScaleCapability.battery},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            session = payload['session'] as String;
            scale.publish({'weight': 0}, session: session);
          }
          return {};
        },
      );
      addTearDown(scale.dispose);
      await scale.onConnect();
    });

    test(
      'opaque firmware and battery patch, boundaries and clear stream',
      () async {
        scale.publishInfo({
          'firmwareVersion': ' R029 / opaque ',
          'batteryLevel': 0,
        }, session: session);
        expect(scale, isA<DeviceInformationCapable>());
        final information = scale as DeviceInformationCapable;
        expect(information.currentDeviceInformation!.toJson(), {
          'firmwareVersion': ' R029 / opaque ',
          'batteryLevel': 0,
        });
        expect((await information.deviceInformation.first)!.batteryLevel, 0);
        scale.publishInfo({'batteryLevel': 100}, session: session);
        expect(
          information.currentDeviceInformation!.firmwareVersion,
          ' R029 / opaque ',
        );
        scale.publishInfo({'firmwareVersion': null}, session: session);
        expect(information.currentDeviceInformation!.toJson(), {
          'batteryLevel': 100,
        });
        scale.publishInfo({'firmwareVersion': ''}, session: session);
        scale.publishInfo({'batteryLevel': null}, session: session);
        expect(information.currentDeviceInformation!.toJson(), {
          'firmwareVersion': '',
        });
        final cleared = information.deviceInformation.firstWhere(
          (value) => value == null,
        );
        scale.publishInfo({'firmwareVersion': null}, session: session);
        await cleared;
        expect(information.currentDeviceInformation, isNull);
      },
    );

    test('invalid patches leave accepted info unchanged', () {
      scale.publishInfo({
        'firmwareVersion': 'accepted',
        'batteryLevel': 87,
      }, session: session);
      final information = scale as DeviceInformationCapable;
      final accepted = information.currentDeviceInformation;
      for (final update in <Map<String, dynamic>>[
        {},
        {'unknown': null},
        {'firmwareVersion': 29},
        {'firmwareVersion': []},
        {'batteryLevel': -1},
        {'batteryLevel': 101},
        {'batteryLevel': 1.5},
        {'batteryLevel': '87'},
        {'batteryLevel': true},
        {'batteryLevel': {}},
        {'firmwareVersion': 'must not apply', 'batteryLevel': 101},
      ]) {
        expect(
          () => scale.publishInfo(update, session: session),
          throwsA(
            isA<PluginDeviceException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
          reason: '$update',
        );
        expect(information.currentDeviceInformation, same(accepted));
      }
    });

    test(
      'disconnect, reconnect, protocol failure and dispose retire info',
      () async {
        scale.publishInfo({'firmwareVersion': 'old'}, session: session);
        final information = scale as DeviceInformationCapable;
        final oldSession = session;
        await scale.disconnect();
        expect(information.currentDeviceInformation, isNull);
        await scale.onConnect();
        expect(information.currentDeviceInformation, isNull);
        scale.publishInfo({'firmwareVersion': 'new'}, session: session);
        expect(
          () => scale.publishInfo({
            'firmwareVersion': 'stale',
          }, session: oldSession),
          throwsA(
            isA<PluginDeviceException>().having(
              (e) => e.code,
              'code',
              'stale_session',
            ),
          ),
        );
        expect(information.currentDeviceInformation!.firmwareVersion, 'new');
        scale.reportDisconnected(session: session);
        await scale.connectionState.firstWhere(
          (s) => s == ConnectionState.disconnected,
        );
        expect(information.currentDeviceInformation, isNull);
        await scale.onConnect();
        scale.publishInfo({'firmwareVersion': 'dispose'}, session: session);
        await scale.dispose();
        expect(information.currentDeviceInformation, isNull);
        expect(
          () =>
              scale.publishInfo({'firmwareVersion': 'late'}, session: session),
          throwsA(
            isA<PluginDeviceException>().having(
              (e) => e.code,
              'code',
              'stale_session',
            ),
          ),
        );
      },
    );

    test(
      'battery capability mismatch and separate instance isolation',
      () async {
        late PluginScale other;
        late String otherSession;
        other = PluginScale(
          deviceId: 'other',
          name: 'Other',
          capabilities: {},
          invoke: (operation, payload) async {
            if (operation == PluginDeviceOperation.connect) {
              otherSession = payload['session'] as String;
              other.publish({'weight': 1}, session: otherSession);
            }
            return {};
          },
        );
        addTearDown(other.dispose);
        await other.onConnect();
        expect(
          (other as DeviceInformationCapable).currentDeviceInformation,
          isNull,
        );
        scale.publishInfo({
          'firmwareVersion': 'one',
          'batteryLevel': 87,
        }, session: session);
        other.publishInfo({
          'firmwareVersion': 'two',
          'batteryLevel': null,
        }, session: otherSession);
        expect(
          (scale as DeviceInformationCapable).currentDeviceInformation!
              .toJson(),
          {'firmwareVersion': 'one', 'batteryLevel': 87},
        );
        for (final battery in [0, 100]) {
          expect(
            () => other.publishInfo({
              'firmwareVersion': 'invalid',
              'batteryLevel': battery,
            }, session: otherSession),
            throwsA(
              isA<PluginDeviceException>().having(
                (e) => e.code,
                'code',
                'invalid_argument',
              ),
            ),
          );
        }
        await scale.disconnect();
        expect(
          (other as DeviceInformationCapable).currentDeviceInformation!
              .toJson(),
          {'firmwareVersion': 'two'},
        );
      },
    );
  });

  for (final startup in ['info only', 'handler failure']) {
    test('info does not satisfy readiness and clears on $startup', () async {
      late PluginScale scale;
      late String session;
      scale = PluginScale(
        deviceId: 'startup',
        name: 'Startup',
        capabilities: {},
        invocationTimeout: const Duration(milliseconds: 30),
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            session = payload['session'] as String;
            scale.publishInfo({
              'firmwareVersion': 'starting',
            }, session: session);
            expect(
              (scale as DeviceInformationCapable)
                  .currentDeviceInformation!
                  .firmwareVersion,
              'starting',
            );
            if (startup == 'handler failure') {
              throw StateError('startup failed');
            }
          }
          return {};
        },
      );
      addTearDown(scale.dispose);
      await expectLater(
        scale.onConnect(),
        throwsA(
          startup == 'info only' ? isA<TimeoutException>() : isA<StateError>(),
        ),
      );
      expect(
        (scale as DeviceInformationCapable).currentDeviceInformation,
        isNull,
      );
      expect(await scale.connectionState.first, ConnectionState.disconnected);
    });
  }

  test(
    'backward sample time is rejected and reconnect resets ordering',
    () async {
      var timestamp = DateTime.utc(2026);
      late PluginScale scale;
      late String session;
      scale = PluginScale(
        deviceId: 'scale',
        name: 'Scale',
        capabilities: {},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            session = payload['session'] as String;
            scale.publish(
              {'weight': 1},
              session: session,
              timestamp: timestamp,
            );
          }
          return {};
        },
      );
      addTearDown(scale.dispose);
      await scale.onConnect();
      timestamp = timestamp.subtract(const Duration(seconds: 1));
      expect(
        () => scale.publish(
          {'weight': 2},
          session: session,
          timestamp: timestamp,
        ),
        throwsA(
          isA<PluginDeviceException>().having(
            (e) => e.code,
            'code',
            'stale_sample',
          ),
        ),
      );
      await scale.disconnect();
      await scale.onConnect();
    },
  );

  for (final hangs in [false, true]) {
    test(
      'reconnect after ${hangs ? "timed-out" : "throwing"} disconnect',
      () async {
        late PluginScale scale;
        scale = PluginScale(
          deviceId: 'scale',
          name: 'Scale',
          capabilities: {},
          invocationTimeout: const Duration(milliseconds: 30),
          invoke: (operation, payload) async {
            if (operation == PluginDeviceOperation.disconnect) {
              if (hangs) {
                return Completer<Map<String, dynamic>>().future.timeout(
                  const Duration(milliseconds: 60),
                );
              }
              throw StateError('cleanup failed');
            }
            if (operation == PluginDeviceOperation.connect) {
              scale.publish({
                'weight': 1,
              }, session: payload['session'] as String);
            }
            return {};
          },
        );
        addTearDown(scale.dispose);
        await scale.onConnect();
        await expectLater(
          scale.disconnect(),
          throwsA(hangs ? isA<TimeoutException>() : isA<StateError>()),
        );
        await scale.onConnect();
      },
    );
  }

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
      await expectLater(
        scale.tare(),
        throwsA(
          isA<ScaleOperationException>().having(
            (e) => e.code,
            'code',
            'unsupported_operation',
          ),
        ),
      );
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
          isA<ScaleOperationException>().having(
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

  test('plugin command failures become Scale operation errors', () async {
    late PluginScale scale;
    scale = PluginScale(
      deviceId: 'scale',
      name: 'Scale',
      capabilities: {PluginScaleCapability.tare},
      invoke: (operation, payload) async {
        if (operation == PluginDeviceOperation.connect) {
          scale.publish({'weight': 1}, session: payload['session'] as String);
        }
        if (operation == PluginDeviceOperation.tare) {
          throw const PluginDeviceException('busy', code: 'device_busy');
        }
        return {};
      },
    );
    await scale.onConnect();
    await expectLater(
      scale.tare(),
      throwsA(
        isA<ScaleOperationException>()
            .having((e) => e.code, 'code', 'device_busy')
            .having((e) => e.message, 'message', 'busy'),
      ),
    );
    await scale.disconnect();
    await scale.dispose();
  });

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
