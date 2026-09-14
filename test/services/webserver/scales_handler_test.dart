import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/test_scale.dart';

class _PrimaryScaleController extends ScaleController {
  TestScale? scale;

  _PrimaryScaleController([this.scale]);

  @override
  Scale connectedScale() {
    final connected = scale;
    if (connected == null) throw const DeviceNotConnectedException.scale();
    return connected;
  }
}

void main() {
  late Handler handler;
  late _PrimaryScaleController primary;
  late AuxiliaryScaleRegistry auxiliary;
  late TestScale primaryScale;
  late TestScale auxiliaryScale;

  Future<void> wire({
    bool withPrimary = true,
    String auxiliaryId = 'aux-1',
  }) async {
    primaryScale = TestScale(deviceId: 'primary-1', name: 'Primary');
    auxiliaryScale = TestScale(deviceId: auxiliaryId, name: 'Auxiliary');

    primary = _PrimaryScaleController(withPrimary ? primaryScale : null);
    auxiliary = AuxiliaryScaleRegistry();
    await auxiliary.connect(auxiliaryScale);

    final app = Router().plus;
    ScalesHandler(primary: primary, auxiliary: auxiliary).addRoutes(app);
    handler = app.call;
  }

  Future<void> rewire({
    bool withPrimary = true,
    String auxiliaryId = 'aux-1',
  }) async {
    primary.dispose();
    await auxiliary.dispose();
    await wire(withPrimary: withPrimary, auxiliaryId: auxiliaryId);
  }

  setUp(() => wire());

  tearDown(() async {
    await auxiliary.dispose();
    primary.dispose();
  });

  Future<Response> send(Request request) async => await handler(request);

  Future<Response> tare(String id) => send(
    Request('PUT', Uri.parse('http://localhost/api/v1/scales/$id/tare')),
  );

  group('PUT /api/v1/scales/<id>/tare', () {
    test('tares the primary scale by its own id', () async {
      final res = await tare('primary-1');
      expect(res.statusCode, 200);
      expect(primaryScale.tareCallCount, 1);
      expect(auxiliaryScale.tareCallCount, 0);
    });

    test('tares an auxiliary scale without touching the primary', () async {
      final res = await tare('aux-1');
      expect(res.statusCode, 200);
      expect(auxiliaryScale.tareCallCount, 1);
      expect(primaryScale.tareCallCount, 0);
    });

    test('an auxiliary scale answers with no primary connected', () async {
      await rewire(withPrimary: false);

      final res = await tare('aux-1');
      expect(res.statusCode, 200);
      expect(auxiliaryScale.tareCallCount, 1);
    });

    test('an id nothing is holding is 404', () async {
      final res = await tare('nobody-1');
      expect(res.statusCode, 404);
      expect(
        jsonDecode(await res.readAsString())['error'],
        contains('nobody-1'),
      );
    });

    test('an unknown command is 404', () async {
      final res = await send(
        Request('PUT', Uri.parse('http://localhost/api/v1/scales/aux-1/sleep')),
      );
      expect(res.statusCode, 404);
      expect(auxiliaryScale.tareCallCount, 0);
    });

    // A literal percent in the id is the discriminating case: decoding it a
    // second time would not name the device, or would throw outright.
    test('an id encoded once is decoded exactly once', () async {
      await rewire(auxiliaryId: 'wifi:hds.local/a%b');

      final res = await tare(Uri.encodeComponent('wifi:hds.local/a%b'));
      expect(res.statusCode, 200);
      expect(auxiliaryScale.tareCallCount, 1);
    });

    test('a malformed id is a client error, not a crash', () async {
      final res = await tare('%ZZ');
      expect(res.statusCode, inInclusiveRange(400, 499));
    });
  });

  group('GET /ws/v1/scales/<id>/snapshot', () {
    test('a malformed id is a client error, not a crash', () async {
      final res = await send(
        Request('GET', Uri.parse('http://localhost/ws/v1/scales/%ZZ/snapshot')),
      );
      expect(res.statusCode, inInclusiveRange(400, 499));
    });

    test('a plain GET is refused rather than served as JSON', () async {
      final res = await send(
        Request(
          'GET',
          Uri.parse('http://localhost/ws/v1/scales/aux-1/snapshot'),
        ),
      );
      expect(res.statusCode, isNot(200));
    });
  });
}
