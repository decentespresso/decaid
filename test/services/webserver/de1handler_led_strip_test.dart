import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _FailingResetBengle extends MockBengle {
  @override
  Future<LedStripState?> resetLedStrip() async => null;
}

class _UnknownStateBengle extends MockBengle {
  @override
  Future<LedStripState?> getLedStripState() async => null;
}

void main() {
  late Handler handler;
  late De1Controller controller;
  late SettingsController settingsController;
  late TestScaleController scaleController;

  Future<void> wireWith(De1Interface? device) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    controller = De1Controller(controller: deviceController);
    if (device != null) {
      await controller.connectToDe1(device);
    }

    final mockSettings = MockSettingsService();
    settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final testScale = TestScale();
    scaleController = TestScaleController(testScale);

    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    handler = app.call;
  }

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  Future<Response> put(String path, Object body) async => await handler(
    Request(
      'PUT',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Future<Response> post(String path, [Object body = const {}]) async =>
      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          body: jsonEncode(body),
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
        ),
      );

  group('GET /api/v1/machine/capabilities — ledStrip', () {
    test(
      'a current-firmware Bengle exposes the entire capability set',
      () async {
        await wireWith(MockBengle());
        final res = await get('/api/v1/machine/capabilities');
        final body = jsonDecode(await res.readAsString());
        expect(body['capabilities'], [
          'cupWarmer',
          'integratedScale',
          'stopAtWeight',
          'ledStrip',
          'scaleCalibration',
          'preheat',
          'wakeSchedule',
        ]);
      },
    );

    test('does not return ledStrip on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/capabilities');
      final body = jsonDecode(await res.readAsString());
      expect(body['capabilities'], isNot(contains('ledStrip')));
    });
  });

  group('GET /api/v1/machine/ledStrip', () {
    test('200 + hydrated palette on MockBengle', () async {
      await wireWith(MockBengle());
      final res = await get('/api/v1/machine/ledStrip');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], '300020001000');
      expect(body['frontStrip']['awake'], 'FF00F0008000');
      expect(body['backStrip']['sleeping'], '300020001000');
      expect(body['backStrip']['awake'], 'FF00F0008000');
      expect(body['frontSwitch']['awake'], 'FF00F0008000');
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await get('/api/v1/machine/ledStrip');
      expect(res.statusCode, 404);
    });
  });

  group('PUT /api/v1/machine/ledStrip', () {
    test('200 + writes state into MockBengle', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF80000000', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final state = await bengle.getLedStripState();
      expect(state!.frontStrip.sleeping, const Color16(65280, 32768, 0));
      expect(state.frontStrip.awake, Color16.off);
      expect(state.backStrip.awake, const Color16(65280, 65280, 65280));
    });

    test('400 on non-map body', () async {
      await wireWith(MockBengle());
      final res = await put('/api/v1/machine/ledStrip', [1, 2, 3]);
      expect(res.statusCode, 400);
    });

    test('replicated-byte input is stored and echoed canonically', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF22220000', 'awake': 'FF00F0008000'},
        'backStrip': {'sleeping': '300020001000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final putBody = await res.readAsString();
      final echoed = jsonDecode(putBody);
      expect(
        echoed['frontStrip']['sleeping'],
        'FF0022000000',
        reason: 'the PUT 200 body must be the stored canonical spelling',
      );
      expect(echoed['backStrip']['awake'], 'FF00FF00FF00');

      final getRes = await get('/api/v1/machine/ledStrip');
      expect(getRes.statusCode, 200);
      expect(
        await getRes.readAsString(),
        putBody,
        reason: 'a following GET must be byte-identical to the PUT echo',
      );
    });

    test('a replicated-byte write on frontStrip.awake echoes the palette '
        'the machine stored', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'awake': 'FFFF22220000', 'sleeping': '400022000000'},
        'backStrip': {'awake': 'FF00D3008E00', 'sleeping': '400022000000'},
        'frontSwitch': {'awake': 'FFFF22220000', 'sleeping': '400022000000'},
      });
      expect(res.statusCode, 200);

      final echoed = jsonDecode(await res.readAsString());
      expect(
        echoed,
        {
          'frontStrip': {'sleeping': '400022000000', 'awake': 'FF0022000000'},
          'backStrip': {'sleeping': '400022000000', 'awake': 'FF00D3008E00'},
          'frontSwitch': {'sleeping': '400022000000', 'awake': 'FF0022000000'},
        },
        reason:
            'the echo must be the palette the firmware actually stored for '
            'this exact write',
      );
    });

    test('canonical input is echoed byte-identically', () async {
      await wireWith(MockBengle());

      const frontStrip = {'sleeping': 'FF0022000000', 'awake': 'FF00F0008000'};
      const backStrip = {'sleeping': '300020001000', 'awake': 'FF00FF00FF00'};

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': frontStrip,
        'backStrip': backStrip,
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final echoed = jsonDecode(await res.readAsString());
      expect(echoed['frontStrip'], frontStrip);
      expect(echoed['backStrip'], backStrip);
    });

    test(
      'the echoed frontSwitch is the derived palette, not the sent one',
      () async {
        await wireWith(MockBengle());

        final res = await put('/api/v1/machine/ledStrip', {
          'frontStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
          'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
          'frontSwitch': {'sleeping': 'FFFF00000000', 'awake': '0000FFFF0000'},
        });
        expect(res.statusCode, 200);

        final echoed = jsonDecode(await res.readAsString());
        expect(echoed['frontSwitch']['awake'], 'FF00F000C800');
        expect(echoed['frontSwitch']['sleeping'], '550050004300');
      },
    );

    test(
      '200 + acknowledgement when the stored palette is unavailable',
      () async {
        await wireWith(_UnknownStateBengle());

        final res = await put('/api/v1/machine/ledStrip', {
          'frontStrip': {'sleeping': 'FFFF80000000', 'awake': '000000000000'},
          'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
          'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
        });
        expect(res.statusCode, 200);
        expect(jsonDecode(await res.readAsString()), {'status': 'accepted'});
      },
    );

    test('reset after a PUT returns the same canonical body', () async {
      await wireWith(MockBengle());

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF22220000', 'awake': 'FF00F0008000'},
        'backStrip': {'sleeping': '300020001000', 'awake': 'FFFFFFFFFFFF'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);
      final putBody = await res.readAsString();

      final resetRes = await post('/api/v1/machine/ledStrip/reset');
      expect(resetRes.statusCode, 200);
      expect(await resetRes.readAsString(), putBody);
    });

    test('malformed hex defaults to zero', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'XXYY', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 200);

      final state = await bengle.getLedStripState();
      expect(state!.frontStrip.sleeping, Color16.off);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await put('/api/v1/machine/ledStrip', {
        'frontStrip': {'sleeping': 'FFFF80000000', 'awake': '000000000000'},
        'backStrip': {'sleeping': '000000000000', 'awake': '000000000000'},
        'frontSwitch': {'sleeping': '000000000000', 'awake': '000000000000'},
      });
      expect(res.statusCode, 404);
    });
  });

  group('LED preview routes', () {
    const previewPath = '/api/v1/machine/ledStrip/preview';
    const palettePath = '/api/v1/machine/ledStrip';
    const preview = {'frontStrip': '12FF345678AB', 'backStrip': 'ABCD12345678'};
    late FakeBleTransport transport;

    Future<void> connectBengle() async {
      transport = FakeBleTransport();
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0xFF8000);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x302010);
      transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0x00FF00);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x0000FF);
      await wireWith(Bengle(transport: transport));
      transport.queueMmrResponseInt(BengleMmr.frontLedAwake, 0xFF8000);
      transport.queueMmrResponseInt(BengleMmr.frontLedSleep, 0x302010);
      transport.queueMmrResponseInt(BengleMmr.rearLedAwake, 0x00FF00);
      transport.queueMmrResponseInt(BengleMmr.rearLedSleep, 0x0000FF);
      addTearDown(() async {
        await controller.dispose();
        await transport.dispose();
      });
      transport.writes.clear();
    }

    List<(int, int)> mmrWrites() => transport.writes
        .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
        .map((w) {
          expect(w.data[0], 4);
          final address = (w.data[1] << 16) | (w.data[2] << 8) | w.data[3];
          final rgb = ByteData.sublistView(
            w.data,
            4,
            8,
          ).getUint32(0, Endian.little);
          return (address, rgb);
        })
        .toList();

    test('preview writes front and rear only to the live registers', () async {
      await connectBengle();

      final res = await post(previewPath, preview);

      expect(res.statusCode, 202);
      expect(mmrWrites(), [(0x00803890, 0x123478), (0x00803894, 0xAB1256)]);
      expect(
        mmrWrites().map((w) => w.$1),
        isNot(
          anyElement(isIn([0x00803898, 0x0080389C, 0x008038A0, 0x008038A4])),
        ),
      );
    });

    for (final field in ['frontStrip', 'backStrip']) {
      for (final value in <Object?>[
        null,
        '',
        'GGGGGGGGGGGG',
        '123456789AB',
        '123456789ABCD',
        '123456789ABC\n',
        123456789012,
        true,
        <String, dynamic>{},
      ]) {
        test(
          'preview rejects $field=${jsonEncode(value)} before writing',
          () async {
            await connectBengle();

            final res = await post(previewPath, {
              'frontStrip': '123456789ABC',
              'backStrip': 'abcdef012345',
              field: value,
            });

            expect(res.statusCode, 400);
            expect(mmrWrites(), isEmpty);
          },
        );
      }
    }

    test('invalid preview bypasses a saturated machine-write queue', () async {
      await connectBengle();
      final started = Completer<void>();
      final release = Completer<void>();
      final active = controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;
      final pending = List.generate(
        controller.maxPendingDeviceWrites,
        (_) => controller.runDeviceWrite((_) async {}),
      );
      try {
        for (final field in ['frontStrip', 'backStrip']) {
          final res = await post(previewPath, {field: null});
          expect(res.statusCode, 400);
        }
        expect(mmrWrites(), isEmpty);
      } finally {
        release.complete();
        await active;
        await Future.wait(pending);
      }
    });

    test('preview accepts either strip alone and mixed-case hex', () async {
      await connectBengle();

      expect(
        (await post(previewPath, {'frontStrip': 'aBcD12345678'})).statusCode,
        202,
      );
      expect(
        (await post(previewPath, {'backStrip': '12aB34cD56eF'})).statusCode,
        202,
      );

      expect(mmrWrites(), [(0x00803890, 0xAB1256), (0x00803894, 0x123456)]);
    });

    test('GET remains stored-palette-only during a preview', () async {
      await connectBengle();
      final before = await get(palettePath);
      expect(before.statusCode, 200);
      final stored = await before.readAsString();
      expect(jsonDecode(stored)['frontStrip']['awake'], 'FF0080000000');

      expect((await post(previewPath, preview)).statusCode, 202);

      final after = await get(palettePath);
      expect(after.statusCode, 200);
      expect(await after.readAsString(), stored);
    });

    test(
      'clear returns 503 when palette hydration remains unavailable',
      () async {
        transport = FakeBleTransport();
        transport.queueOnConnectResponses(v13Model: 128);
        transport.failMmrReadsForAddresses.addAll([
          BengleMmr.frontLedAwake.address,
          BengleMmr.frontLedSleep.address,
          BengleMmr.rearLedAwake.address,
          BengleMmr.rearLedSleep.address,
        ]);
        await wireWith(Bengle(transport: transport));
        addTearDown(() async {
          await controller.dispose();
          await transport.dispose();
        });

        final res = await post('$previewPath/clear');

        expect(res.statusCode, 503);
        expect(jsonDecode(await res.readAsString()), {
          'error':
              'ledStrip state unavailable (hydration failed or not yet complete)',
        });
      },
    );

    test(
      'clear uses the latest stateInfo after sleep without a shot',
      () async {
        await connectBengle();
        transport.emitNotification(Endpoint.stateInfo, [0x02, 0]);
        await pumpEventQueue();
        transport.emitNotification(Endpoint.bengleShotSample, Uint8List(28));
        await pumpEventQueue();
        expect((await post(previewPath, preview)).statusCode, 202);
        transport.writes.clear();

        transport.emitNotification(Endpoint.stateInfo, [0x00, 0]);
        await pumpEventQueue();
        final res = await post('$previewPath/clear');

        expect(res.statusCode, 202);
        expect(mmrWrites(), [(0x00803890, 0x302010), (0x00803894, 0x0000FF)]);
      },
    );

    for (final asleep in [false, true]) {
      test('preview then clear restores the ${asleep ? 'sleeping' : 'awake'} '
          'palette through live writes', () async {
        await connectBengle();
        transport.emitNotification(Endpoint.stateInfo, [
          asleep ? 0x00 : 0x02,
          0,
        ]);
        await pumpEventQueue();
        transport.emitNotification(Endpoint.bengleShotSample, Uint8List(28));
        await pumpEventQueue();
        expect((await post(previewPath, preview)).statusCode, 202);
        expect(mmrWrites(), hasLength(2));
        transport.writes.clear();

        final res = await post('$previewPath/clear');

        expect(res.statusCode, 202);
        expect(mmrWrites(), [
          (0x00803890, asleep ? 0x302010 : 0xFF8000),
          (0x00803894, asleep ? 0x0000FF : 0x00FF00),
        ]);
        final stored = await get(palettePath);
        expect(stored.statusCode, 200);
        expect(jsonDecode(await stored.readAsString())['frontStrip'], {
          'sleeping': '300020001000',
          'awake': 'FF0080000000',
        });
      });
    }

    for (final path in [previewPath, '$previewPath/clear']) {
      test('$path returns the capability-gate 404 on plain DE1', () async {
        await wireWith(MockDe1());
        addTearDown(controller.dispose);

        final res = await post(path, preview);

        expect(res.statusCode, 404);
        expect(jsonDecode(await res.readAsString()), {
          'error': 'ledStrip not supported',
        });
      });
    }
  });

  group('POST /api/v1/machine/ledStrip/commit', () {
    test('202 on Bengle', () async {
      await wireWith(MockBengle());
      final res = await post('/api/v1/machine/ledStrip/commit');
      expect(res.statusCode, 202);
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await post('/api/v1/machine/ledStrip/commit');
      expect(res.statusCode, 404);
    });
  });

  group('POST /api/v1/machine/ledStrip/reset', () {
    test('200 + returns current state on Bengle (truthful reload)', () async {
      final bengle = MockBengle();
      await wireWith(bengle);

      final written = LedStripState(
        frontStrip: ZoneLedState(
          sleeping: const Color16(65535, 0, 0),
          awake: Color16.off,
        ),
      );
      await bengle.setLedStrip(written);

      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body['frontStrip']['sleeping'], 'FF0000000000');
    });

    test('503 when the reload fails after a successful hydration', () async {
      final bengle = _FailingResetBengle();
      await wireWith(bengle);
      await bengle.setLedStrip(
        LedStripState(
          frontStrip: ZoneLedState(
            sleeping: const Color16(0xFF00, 0x0000, 0x0000),
            awake: Color16.off,
          ),
        ),
      );

      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(
        res.statusCode,
        503,
        reason: 'a failed reset must not return stale cached state as 200',
      );
    });

    test('404 on plain DE1', () async {
      await wireWith(MockDe1());
      final res = await post('/api/v1/machine/ledStrip/reset');
      expect(res.statusCode, 404);
    });
  });
}
