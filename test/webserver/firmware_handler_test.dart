import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/firmware/bundled_firmware_catalog.dart';
import 'package:reaprime/src/services/webserver/firmware_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/mock_device_discovery_service.dart';

final class _FixedController extends De1Controller {
  _FixedController({required super.controller, this.machine});

  De1Interface? machine;

  @override
  De1Interface connectedDe1() {
    return machine ?? (throw const DeviceNotConnectedException.machine());
  }

  @override
  Future<T> runDeviceWrite<T>(
    Future<T> Function(De1Interface device) write, {
    De1ReplayPolicy replayPolicy = De1ReplayPolicy.never,
  }) {
    return write(connectedDe1());
  }
}

final class _FirmwareDe1 extends MockDe1 {
  _FirmwareDe1({required this.version, this.model = 'DE1Pro'});

  final String version;
  final String model;
  var updateCalls = 0;
  var cancelCalls = 0;
  Completer<void>? firmwareStarted;
  Completer<void>? firmwareRelease;

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: version,
    model: model,
    serialNumber: 'firmware-test',
    groupHeadControllerPresent: false,
    extra: const {},
  );

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {
    updateCalls++;
    firmwareStarted?.complete();
    if (firmwareRelease != null) await firmwareRelease!.future;
    await Future<void>.delayed(Duration.zero);
    onProgress(1);
  }

  @override
  Future<void> cancelFirmwareUpload() async {
    cancelCalls++;
    if (firmwareRelease case final release? when !release.isCompleted) {
      release.complete();
    }
  }
}

final class _BlockingFirmwareBundle extends CachingAssetBundle {
  final Completer<void> imageLoadStarted = Completer<void>();
  final Completer<void> imageLoadRelease = Completer<void>();

  @override
  Future<ByteData> load(String key) async {
    if (key != 'assets/firmware/manifest.json') {
      imageLoadStarted.complete();
      await imageLoadRelease.future;
    }
    return rootBundle.load(key);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    return rootBundle.loadString(key, cache: cache);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Handler handler;
  late _FixedController controller;

  setUp(() async {
    final devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = _FixedController(
      controller: devices,
      machine: _FirmwareDe1(version: '1358'),
    );
    final app = Router().plus;
    FirmwareHandler(
      controller: controller,
      catalog: BundledFirmwareCatalog(bundle: rootBundle),
    ).addRoutes(app);
    handler = app.call;
  });

  test('raw upload rejects an empty body and a missing machine', () async {
    final empty = await _raw(handler, const []);
    expect(empty.statusCode, 400);

    controller.machine = null;
    final unavailable = await _raw(handler, const [1]);
    expect(unavailable.statusCode, 503);
  });

  test('raw upload rejects a declared body over the limit', () async {
    final limited = _firmwareHandler(controller, maxRawBodyBytes: 4);
    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware'),
        headers: {
          'content-type': 'application/octet-stream',
          'content-length': '5',
        },
        body: Stream<List<int>>.error(StateError('body must not be read')),
      ),
    );

    expect(response.statusCode, 413);
  });

  test('raw upload caps buffered firmware at 1 MiB', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware'),
        headers: {
          'content-type': 'application/octet-stream',
          'content-length': '${1024 * 1024 + 1}',
        },
        body: Stream<List<int>>.error(StateError('body must not be read')),
      ),
    );

    expect(response.statusCode, 413);
  });

  test('raw upload rejects a streamed body crossing the limit', () async {
    final limited = _firmwareHandler(controller, maxRawBodyBytes: 4);
    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware'),
        headers: {'content-type': 'application/octet-stream'},
        body: Stream<List<int>>.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
      ),
    );

    expect(response.statusCode, 413);
  });

  test('raw upload returns 408 when the body stalls', () async {
    final body = StreamController<List<int>>();
    var cancelled = false;
    body.onCancel = () => cancelled = true;
    addTearDown(body.close);
    final limited = _firmwareHandler(
      controller,
      maxRawBodyBytes: 4,
      rawBodyReadTimeout: const Duration(milliseconds: 1),
    );

    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware'),
        headers: {'content-type': 'application/octet-stream'},
        body: body.stream,
      ),
    );

    expect(response.statusCode, 408);
    expect(cancelled, isTrue);
  });

  test('managed apply rejects a declared body over the limit', () async {
    final limited = _firmwareHandler(controller, maxManagedBodyBytes: 4);
    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware/apply'),
        headers: {'content-type': 'application/json', 'content-length': '5'},
        body: Stream<List<int>>.error(StateError('body must not be read')),
      ),
    );

    expect(response.statusCode, 413);
  });

  test('managed apply rejects a streamed body crossing the limit', () async {
    final limited = _firmwareHandler(controller, maxManagedBodyBytes: 4);
    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware/apply'),
        headers: {'content-type': 'application/json'},
        body: Stream<List<int>>.fromIterable([
          [1, 2, 3],
          [4, 5],
        ]),
      ),
    );

    expect(response.statusCode, 413);
  });

  test('managed apply returns 408 when the body stalls', () async {
    final body = StreamController<List<int>>();
    var cancelled = false;
    body.onCancel = () => cancelled = true;
    addTearDown(body.close);
    final limited = _firmwareHandler(
      controller,
      maxManagedBodyBytes: 4,
      managedBodyReadTimeout: const Duration(milliseconds: 1),
    );

    final response = await limited(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware/apply'),
        headers: {'content-type': 'application/json'},
        body: body.stream,
      ),
    );

    expect(response.statusCode, 408);
    expect(cancelled, isTrue);
  });

  test('raw upload returns pre-stream 409 while an update is active', () async {
    controller.machine = MockDe1();
    final first = await _raw(handler, const [1]);
    expect(first.statusCode, 200);

    final second = await _raw(handler, const [1]);
    expect(second.statusCode, 409);

    final subscription = first.read().listen((_) {});
    await subscription.cancel();
  });

  test(
    'raw upload returns 503 before streaming when the DE1 queue is full',
    () async {
      final harness = await _governedHandler(maxPendingDeviceWrites: 0);
      addTearDown(harness.controller.dispose);
      final release = Completer<void>();
      final started = Completer<void>();
      final active = harness.controller.runDeviceWrite((_) async {
        started.complete();
        await release.future;
      });
      await started.future;

      final rejected = await _raw(harness.handler, const [1]);
      expect(rejected.statusCode, 503);
      expect(harness.machine.updateCalls, 0);

      release.complete();
      await active;
      final accepted = await _raw(harness.handler, const [1]);
      expect(accepted.statusCode, 200);
      await _readEvents(accepted);
      expect(harness.machine.updateCalls, 1);
    },
  );

  test('DELETE cancels firmware while pending', () async {
    final harness = await _governedHandler();
    addTearDown(harness.controller.dispose);
    final release = Completer<void>();
    final started = Completer<void>();
    final active = harness.controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    await _raw(harness.handler, const [1]);
    final cancellation = await _delete(harness.handler);
    expect(cancellation.statusCode, 202);
    expect(harness.controller.pendingDeviceWriteCount, 0);

    release.complete();
    await active;
    expect(harness.machine.updateCalls, 0);
    expect(harness.machine.cancelCalls, 0);
  });

  test('response cancellation cancels firmware while pending', () async {
    final harness = await _governedHandler();
    addTearDown(harness.controller.dispose);
    final release = Completer<void>();
    final started = Completer<void>();
    final active = harness.controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final response = await _raw(harness.handler, const [1]);
    final subscription = response.read().listen((_) {});
    await subscription.cancel();
    expect(harness.controller.pendingDeviceWriteCount, 0);

    release.complete();
    await active;
    expect(harness.machine.updateCalls, 0);
    expect(harness.machine.cancelCalls, 0);
  });

  test('DELETE forwards cancellation after firmware starts', () async {
    final harness = await _governedHandler();
    addTearDown(harness.controller.dispose);
    harness.machine.firmwareStarted = Completer<void>();
    harness.machine.firmwareRelease = Completer<void>();

    final response = await _raw(harness.handler, const [1]);
    await harness.machine.firmwareStarted!.future;
    final cancellation = await _delete(harness.handler);

    expect(cancellation.statusCode, 202);
    expect(harness.machine.cancelCalls, 1);
    await _readEvents(response);
  });

  test(
    'response cancellation forwards cancellation after firmware starts',
    () async {
      final harness = await _governedHandler();
      addTearDown(harness.controller.dispose);
      harness.machine.firmwareStarted = Completer<void>();
      harness.machine.firmwareRelease = Completer<void>();

      final response = await _raw(harness.handler, const [1]);
      await harness.machine.firmwareStarted!.future;
      final subscription = response.read().listen((_) {});
      await subscription.cancel();

      expect(harness.machine.cancelCalls, 1);
    },
  );

  test('NDJSON stays open until successful verification', () async {
    final transport = FakeBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(seconds: 1),
      firmwareVerificationTimeout: const Duration(seconds: 1),
    );
    await de1.onConnect();
    controller.machine = de1;
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);

    final response = await _raw(handler, List.filled(16, 1));
    final events = response
        .read()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    final iterator = StreamIterator(events);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, {'status': 'erasing', 'progress': 0.0});
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current['status'], 'uploading');

    var terminalArrived = false;
    final terminal = iterator.moveNext().then((value) {
      terminalArrived = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(terminalArrived, isFalse);

    transport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    expect(await terminal, isTrue);
    expect(iterator.current, {'status': 'done', 'progress': 1.0});
    await iterator.cancel();
  });

  test('DELETE is idempotent without a machine', () async {
    controller.machine = null;
    final response = await handler(
      Request('DELETE', Uri.parse('http://localhost/api/v1/machine/firmware')),
    );
    expect(response.statusCode, 202);
    expect(jsonDecode(await response.readAsString()), {
      'operation': {'state': 'idle'},
    });
  });

  test('managed apply rejects malformed JSON and invalid force', () async {
    final malformed = await _apply(handler, '{');
    expect(malformed.statusCode, 400);

    final invalidForce = await _apply(
      handler,
      jsonEncode({'artifactId': 'de1-1352', 'force': 'yes'}),
    );
    expect(invalidForce.statusCode, 400);
  });

  test('managed apply returns 404 for an unknown artifact', () async {
    final response = await _apply(
      handler,
      jsonEncode({'artifactId': 'missing'}),
    );
    expect(response.statusCode, 404);
  });

  test('force allows apply when installed build is unknown', () async {
    controller.machine = _FirmwareDe1(version: 'unknown');
    final response = await _apply(
      handler,
      jsonEncode({'artifactId': 'de1-1352', 'force': true}),
    );

    expect(response.statusCode, 200);
    expect(await _readEvents(response), [
      {'status': 'erasing', 'progress': 0.0},
      {'status': 'uploading', 'progress': 1.0},
      {'status': 'done', 'progress': 1.0},
    ]);
  });

  test('force cannot bypass bundled firmware model compatibility', () async {
    final bengle = _FirmwareDe1(version: '1351', model: 'Bengle');
    controller.machine = bengle;

    final response = await _apply(
      handler,
      jsonEncode({'artifactId': 'de1-1352', 'force': true}),
    );

    expect(response.statusCode, 422);
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(body['reasons'], contains('model_incompatible'));
    expect(bengle.updateCalls, 0);
  });

  test(
    'managed apply revalidates after the connected machine changes',
    () async {
      final bundle = _BlockingFirmwareBundle();
      final harness = await _governedHandler(bundle: bundle);
      addTearDown(harness.controller.dispose);

      final applying = _apply(
        harness.handler,
        jsonEncode({'artifactId': 'de1-1352', 'force': true}),
      );
      await bundle.imageLoadStarted.future;

      harness.machine.simulateDisconnect();
      await Future<void>.delayed(Duration.zero);
      final replacement = _FirmwareDe1(version: '1351', model: 'Bengle');
      await harness.controller.connectToDe1(replacement);
      bundle.imageLoadRelease.complete();

      final response = await applying;
      expect(response.statusCode, 422);
      expect(harness.machine.updateCalls, 0);
      expect(replacement.updateCalls, 0);
    },
  );

  test('verification failure emits error and closes without done', () async {
    final transport = FakeBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await de1.onConnect();
    controller.machine = de1;
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0, 0, 1]);

    final response = await _raw(handler, List.filled(16, 1));
    final events = await _readEvents(response);

    expect(events.map((event) => event['status']), [
      'erasing',
      'uploading',
      'error',
    ]);
    expect(events.last['error'], isNotEmpty);
  });

  test('verification timeout emits error and closes without done', () async {
    final transport = FakeBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await de1.onConnect();
    controller.machine = de1;
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);

    final response = await _raw(handler, List.filled(16, 1));
    final events = await _readEvents(response);

    expect(events.map((event) => event['status']), [
      'erasing',
      'uploading',
      'error',
    ]);
    expect(
      events.last['error'],
      contains('Timed out waiting for firmware verification'),
    );
  });

  test('catalog reports false when connected machine is up to date', () async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/machine/firmware')),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(body['updateAvailable'], isFalse);
    expect(body['recommendedArtifactId'], isNull);
  });
}

Handler _firmwareHandler(
  _FixedController controller, {
  int maxRawBodyBytes = 1024 * 1024,
  Duration rawBodyReadTimeout = const Duration(seconds: 1),
  int maxManagedBodyBytes = 64 * 1024,
  Duration managedBodyReadTimeout = const Duration(seconds: 1),
}) {
  final app = Router().plus;
  FirmwareHandler(
    controller: controller,
    catalog: BundledFirmwareCatalog(bundle: rootBundle),
    maxRawBodyBytes: maxRawBodyBytes,
    rawBodyReadTimeout: rawBodyReadTimeout,
    maxManagedBodyBytes: maxManagedBodyBytes,
    managedBodyReadTimeout: managedBodyReadTimeout,
  ).addRoutes(app);
  return app.call;
}

Future<Response> _raw(Handler handler, List<int> body) async {
  return await handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/machine/firmware'),
      headers: {'content-type': 'application/octet-stream'},
      body: body,
    ),
  );
}

Future<Response> _apply(Handler handler, String body) async {
  return await handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/machine/firmware/apply'),
      headers: {'content-type': 'application/json'},
      body: body,
    ),
  );
}

Future<Response> _delete(Handler handler) async {
  return await handler(
    Request('DELETE', Uri.parse('http://localhost/api/v1/machine/firmware')),
  );
}

Future<({Handler handler, De1Controller controller, _FirmwareDe1 machine})>
_governedHandler({int maxPendingDeviceWrites = 2, AssetBundle? bundle}) async {
  final devices = DeviceController([MockDeviceDiscoveryService()]);
  await devices.initialize();
  final controller = De1Controller(
    controller: devices,
    maxPendingDeviceWrites: maxPendingDeviceWrites,
  );
  final machine = _FirmwareDe1(version: '1358');
  await controller.connectToDe1(machine);
  final app = Router().plus;
  FirmwareHandler(
    controller: controller,
    catalog: BundledFirmwareCatalog(bundle: bundle ?? rootBundle),
  ).addRoutes(app);
  return (handler: app.call, controller: controller, machine: machine);
}

Future<List<Map<String, dynamic>>> _readEvents(Response response) async {
  return response
      .read()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
}
