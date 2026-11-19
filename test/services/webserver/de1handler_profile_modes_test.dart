import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

/// POST /api/v1/machine/profile is the machine-push choke point for the
/// capability refusal gate. A profile with a Power/Lever step must land as a
/// CLEAN 400 (with the refusal message) when the machine has not advertised the
/// matching caps bit — not the opaque 500 the withDe1 catch-all would otherwise
/// produce — and go through (200) when it has.
class _FixedDe1Controller extends De1Controller {
  _FixedDe1Controller({required super.controller, this.device});

  De1Interface? device;

  @override
  De1Interface connectedDe1() {
    final d = device;
    if (d == null) throw const DeviceNotConnectedException.machine();
    return d;
  }

  // runDeviceWrite also identity-checks the machine against this before and
  // after the write; without the override it stays null, the write is skipped
  // as "machine changed", and every response becomes a 500.
  @override
  De1Interface? get connectedDe1OrNull => device;
}

void main() {
  late Handler handler;

  Future<void> wireWith(De1Interface? device) async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    final controller = _FixedDe1Controller(
      controller: deviceController,
      device: device,
    );

    final mockSettings = MockSettingsService();
    final settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    final scaleController = TestScaleController(TestScale());

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

  /// Connect a real Bengle over the fake transport, advertising [caps].
  Future<Bengle> connectedBengle(int caps) async {
    final transport = FakeBleTransport();
    final bengle = Bengle(transport: transport);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
    transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: caps);
    // Bengle.onConnect also hydrates the LED palette. Without a queued answer
    // that read waits out its fail-closed timeout - 12.6 s per test, and this
    // file was the slowest in the whole suite because of it.
    transport.queuePaletteHydrationResponses();
    await bengle.onConnect();
    addTearDown(transport.dispose);
    return bengle;
  }

  Future<Response> postProfile(Map<String, dynamic> profile) async => handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/machine/profile'),
      body: jsonEncode(profile),
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    ),
  );

  Map<String, dynamic> leverProfile() => {
    'version': '2',
    'title': 'Lever demo',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'lever',
        'pump': 'lever',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 40,
        'temperature': 92,
        'sensor': 'coffee',
        'pressure': 9.0,
        'leverSpring': 0.9,
        'leverGive': 1.5,
      },
    ],
    'tank_temperature': 90.0,
    'target_weight': 36.0,
    'target_volume_count_start': 0,
  };

  Map<String, dynamic> powerProfileNoLimiter() => {
    'version': '2',
    'title': 'Power (bad)',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'power',
        'pump': 'power',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 25,
        'temperature': 93,
        'sensor': 'coffee',
        'power': 2.0,
      },
    ],
    'tank_temperature': 90.0,
    'target_volume_count_start': 0,
  };

  group('POST /api/v1/machine/profile — capability refusal gate', () {
    test(
      '400 (not 500) with the refusal message when caps are absent',
      () async {
        await wireWith(await connectedBengle(0));

        final res = await postProfile(leverProfile());

        expect(res.statusCode, 400);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'Unsupported profile');
        expect(body['message'], contains('Lever'));
        expect(body['message'], contains('does not support'));
      },
    );

    test(
      '200 when the machine advertises the Lever capability (0x3)',
      () async {
        await wireWith(await connectedBengle(0x3));

        final res = await postProfile(leverProfile());

        expect(res.statusCode, 200);
      },
    );

    test(
      '400 for a power step missing its mandatory limiter (FormatException)',
      () async {
        await wireWith(await connectedBengle(0x3));

        final res = await postProfile(powerProfileNoLimiter());

        expect(res.statusCode, 400);
        final body =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(body['error'], 'Invalid profile');
      },
    );
  });
}
