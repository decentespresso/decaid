import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_firmwaremodel.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
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
    bool firmwareDiagnostic = false,
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

final class _VerificationTransport extends FakeBleTransport {
  final verificationRequested = Completer<void>();

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (!verificationRequested.isCompleted &&
        characteristicUUID == Endpoint.fwMapRequest.uuid &&
        FWMapRequestData.from(ByteData.sublistView(data)).firmwareToErase ==
            0) {
      verificationRequested.complete();
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

final class _LoadedFirmwareBundle extends CachingAssetBundle {
  _LoadedFirmwareBundle(this.manifest, this.image);

  final ByteData manifest;
  final ByteData image;

  @override
  Future<ByteData> load(String key) async {
    return switch (key) {
      'assets/firmware/manifest.json' => manifest,
      'assets/firmware/de1/de1-1358.bin' => image,
      _ => throw StateError('Unexpected firmware asset: $key'),
    };
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key != 'assets/firmware/manifest.json') {
      throw StateError('Unexpected firmware asset: $key');
    }
    return utf8.decode(
      manifest.buffer.asUint8List(
        manifest.offsetInBytes,
        manifest.lengthInBytes,
      ),
    );
  }
}

final class _BlockingMachineSettingsStore implements MachineSettingsStore {
  final Completer<void> readStarted = Completer<void>();
  final Completer<MachineSettings?> readRelease = Completer<MachineSettings?>();

  @override
  Future<MachineSettings?> read(String identity) async {
    if (!readStarted.isCompleted) readStarted.complete();
    return readRelease.future;
  }

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
    int? refillLevel,
  }) async {}

  @override
  Future<void> clear(String identity) async {}

  @override
  Future<void> clearResetOverrides(String identity) async {}

  void release() {
    if (!readRelease.isCompleted) readRelease.complete();
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

  test('raw upload accepts firmware larger than 1 MiB', () async {
    final response = await _raw(handler, List.filled(1024 * 1024 + 1, 1));

    expect(response.statusCode, 200);
    await response.readAsString();
  });

  test('raw upload caps buffered firmware at 16 MiB', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/machine/firmware'),
        headers: {
          'content-type': 'application/octet-stream',
          'content-length': '${16 * 1024 * 1024 + 1}',
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
    final transport = _VerificationTransport();
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

    await transport.verificationRequested.future;
    expect(de1.firmwareUpdateState, FirmwareUpdateState.verifying);
    var terminalArrived = false;
    final terminal = iterator.moveNext().then((value) {
      terminalArrived = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
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

  for (final model in ['Unknown', 'Bengle', 'DE1Turbo']) {
    test('force rejects bundled firmware model $model', () async {
      final machine = _FirmwareDe1(version: '1351', model: model);
      controller.machine = machine;

      final response = await _apply(
        handler,
        jsonEncode({'artifactId': 'de1-1352', 'force': true}),
      );

      expect(response.statusCode, 422);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(
        body['reasons'],
        contains(
          model == 'Unknown' ? 'machine_model_unknown' : 'model_incompatible',
        ),
      );
      expect(machine.updateCalls, 0);
    });
  }

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

  test('managed apply diagnostic captures injected requested-state '
      'sleep-write timeout boundary', () async {
    final previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = <LogRecord>[];
    final logSubscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    final transport = FakeBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(
      v13Model: 3,
      cpuFirmwareBuild: 1333,
      calFlowEst: 0,
    );
    transport.requestedStateSleepWriteTimeout = const Duration(seconds: 2);
    final de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(seconds: 1),
      firmwareVerificationTimeout: const Duration(seconds: 1),
    );
    await de1.onConnect();
    transport.trace.clear();
    transport.writes.clear();
    controller.machine = de1;

    final bundle = await _loadFirmwareBundle();
    final timedHandler = _handlerWithBundle(controller, bundle);
    final time = FakeAsync();
    final response = await _flushVirtual(
      time,
      'managed sleep-write timeout request',
      time.run(
        (_) => _apply(timedHandler, jsonEncode({'artifactId': 'de1-1358'})),
      ),
    );
    final events = <Map<String, dynamic>>[];
    var closed = false;
    final done = time.run((_) => Completer<void>());
    time.run(
      (_) => response
          .read()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => events.add(jsonDecode(line) as Map<String, dynamic>),
            onDone: () {
              closed = true;
              done.complete();
            },
          ),
    );
    time.flushMicrotasks();
    expect(events.map((event) => event['status']), ['erasing']);
    expect(closed, isFalse);
    expect(
      transport.writes.where(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      isEmpty,
    );
    time.elapse(const Duration(seconds: 2) - const Duration(microseconds: 1));
    expect(events.map((event) => event['status']), ['erasing']);
    expect(closed, isFalse);
    time.elapse(const Duration(microseconds: 1));
    await _flushVirtual(
      time,
      'managed sleep-write timeout response close',
      done.future,
    );
    expect(closed, isTrue);
    expect(time.nonPeriodicTimerCount, 0);
    expect(time.periodicTimerCount, 0);
    final catalogResponse = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/machine/firmware')),
    );
    final catalog = jsonDecode(
      await catalogResponse.readAsString(),
    ) as Map<String, dynamic>;
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 1000);
    expect(await de1.getFlowEstimation(), 1.0);

    expect(response.statusCode, 200);
    expect(events.map((event) => event['status']), ['erasing', 'error']);
    expect(events.where((event) => event['status'] == 'error'), hasLength(1));
    expect(events.last['error'], contains('TimeoutException'));
    expect(events.last['stage'], 'sleep');
    expect(events.last['cause'], events.last['error']);
    final handlerFailureLogs = logs
        .where(
          (record) =>
              record.loggerName == 'FirmwareHandler' &&
              record.message.contains('firmware upload failed stage=sleep'),
        )
        .toList();
    expect(handlerFailureLogs, hasLength(1));
    final handlerFailureLog = handlerFailureLogs.first;
    expect(handlerFailureLog.message, contains('stage=sleep'));
    expect(handlerFailureLog.message, contains('cause=TimeoutException'));
    expect(handlerFailureLog.error, isA<TimeoutException>());
    expect(handlerFailureLog.stackTrace, isNotNull);
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    expect((catalog['operation'] as Map<String, dynamic>)['state'], 'idle');
    expect(
      transport.writes.any(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      isFalse,
    );
    expect(
      transport.writes.any(
        (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
      ),
      isFalse,
    );
  });

  test('managed apply waits for real controller initialization before starting firmware', () async {
    final previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = <LogRecord>[];
    final logSubscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    final harness = await _blockedInitializationHandler();
    addTearDown(() async {
      harness.settings.release();
      await harness.controller.dispose();
    });

    harness.transport.queueMmrResponseInt(MMRItem.calFlowEst, 1000);
    expect(await harness.machine.getFlowEstimation(), 1.0);
    harness.transport.writes.clear();
    harness.transport.trace.clear();

    final bundle = await _loadFirmwareBundle();
    final timedHandler = _handlerWithBundle(harness.controller, bundle);
    final time = FakeAsync();
    final response = await _flushVirtual(
      time,
      'managed initialization timeout request',
      time.run(
        (_) => _apply(timedHandler, jsonEncode({'artifactId': 'de1-1358'})),
      ),
    );
    var finished = false;
    final reading = time.run(
      (_) => _readEvents(response).then((events) {
        finished = true;
        return events;
      }),
    );
    time.flushMicrotasks();
    expect(finished, isFalse);
    expect(
      logs.any(
        (record) =>
            record.message.contains('firmware stage=initialization start'),
      ),
      isTrue,
    );
    expect(harness.transport.writes, isEmpty);
    time.elapse(const Duration(seconds: 2) - const Duration(microseconds: 1));
    expect(finished, isFalse);
    expect(harness.transport.writes, isEmpty);
    time.elapse(const Duration(microseconds: 1));
    final events = await _flushVirtual(
      time,
      'managed initialization timeout response close',
      reading,
    );
    expect(time.nonPeriodicTimerCount, 0);
    expect(time.periodicTimerCount, 0);
    final catalogResponse = await harness.handler(
      Request('GET', Uri.parse('http://localhost/api/v1/machine/firmware')),
    );
    final catalog = jsonDecode(
      await catalogResponse.readAsString(),
    ) as Map<String, dynamic>;
    final operation = catalog['operation'] as Map<String, dynamic>;
    final writesBeforePostTimeoutProbe = List.of(harness.transport.writes);
    harness.transport.queueMmrResponseInt(MMRItem.calFlowEst, 1000);
    expect(await harness.machine.getFlowEstimation(), 1.0);
    harness.settings.release();
    await harness.controller.initSettled.firstWhere(
      (generation) => generation == harness.controller.connectionGeneration,
    );
    expect(harness.machine.firmwareUpdateState, FirmwareUpdateState.idle);
    harness.transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    harness.transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await harness.controller.updateFirmware(Uint8List(16), onProgress: (_) {});
    expect(harness.machine.firmwareUpdateState, FirmwareUpdateState.idle);
    expect(
      harness.transport.writes.where(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      hasLength(2),
    );
    expect(
      harness.transport.writes.where(
        (write) =>
            write.characteristicUUID == Endpoint.writeToMMR.uuid &&
            write.data.length == 20 &&
            write.data[0] == 16 &&
            write.data[1] == 0 &&
            write.data[2] == 0 &&
            write.data[3] == 0,
      ),
      hasLength(1),
    );
    final failureLogs = logs
        .where(
          (record) =>
              record.loggerName == 'FirmwareHandler' &&
              record.message.contains('firmware upload failed'),
        )
        .toList();
    final failureLog = failureLogs.single;
    final transcript = [
      'connectionGeneration=${harness.controller.connectionGeneration}',
      'events=$events',
      'transportTrace=${harness.transport.trace}',
      'failureLog=${failureLog.message}',
      'initializationTimeoutCallsite=de1_controller.governor.dart',
      'originalStack=${failureLog.stackTrace}',
    ].join('\\n');

    expect(response.statusCode, 200);
    expect(events, hasLength(1));
    expect(events.single['status'], 'error');
    expect(
      events.single['error'],
      'TimeoutException after 0:00:02.000000: Future not completed',
    );
    expect(events.single['cause'], events.single['error']);
    expect(events.single['stage'], isNot('erasing'));
    expect(operation['state'], 'idle');
    expect(
      writesBeforePostTimeoutProbe.any(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      isFalse,
    );
    expect(
      writesBeforePostTimeoutProbe.any(
        (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
      ),
      isFalse,
    );
    expect(
      failureLog.stackTrace.toString(),
      allOf(
        contains('_waitForInitialization'),
        contains('de1_controller.governor.dart'),
      ),
    );
    expect(events.single['stage'], 'initialization', reason: transcript);
  });

  test('managed apply logs the governed successful stage order', () async {
    final previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = <LogRecord>[];
    final logSubscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    final harness = await _blockedInitializationHandler();
    addTearDown(() async {
      harness.settings.release();
      await harness.controller.dispose();
    });
    harness.settings.release();
    await harness.controller.initSettled.firstWhere(
      (generation) => generation == harness.controller.connectionGeneration,
    );
    harness.transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    harness.transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);

    final response = await _apply(
      harness.handler,
      jsonEncode({'artifactId': 'de1-1358'}),
    );
    final events = await _readEvents(response);
    expect(response.statusCode, 200);
    expect(events.last['status'], 'done');

    final messages = logs.map((record) => record.message).toList();
    int messageIndex(String text, [int start = 0]) {
      return messages.indexWhere((message) => message.contains(text), start);
    }

    final admission = messageIndex('firmware stage=admission');
    final initialization = messageIndex('firmware stage=initialization start');
    final settled = messageIndex('firmware stage=initialization settled');
    final onStart = messageIndex('firmware stage=onStart');
    final sleep = messageIndex('firmware stage=sleep start');
    final preflight = messageIndex('firmware stage=preflight start');
    final gate = messageIndex('firmware stage=firmware-gate waiting');
    final map = messageIndex('about to write to fwMapRequest');
    final image = messageIndex('about to write to writeToMMR', map);
    final stageOrder = [
      admission,
      initialization,
      settled,
      onStart,
      sleep,
      preflight,
      gate,
      map,
      image,
    ];
    expect(stageOrder, everyElement(greaterThanOrEqualTo(0)));
    for (var index = 1; index < stageOrder.length; index++) {
      expect(stageOrder[index], greaterThan(stageOrder[index - 1]));
    }
  });

  test(
    'cancellation while initialization is pending settles as cancellation',
    () async {
      final harness = await _blockedInitializationHandler();
      addTearDown(() async {
        harness.settings.release();
        await harness.controller.dispose();
      });
      harness.transport.writes.clear();

      final response = await _apply(
        harness.handler,
        jsonEncode({'artifactId': 'de1-1358'}),
      );
      await harness.controller.cancelFirmwareUpload();
      harness.settings.release();
      final events = await _readEvents(response);
      expect(response.statusCode, 200);
      expect(events, hasLength(1));
      expect(events.single['status'], 'error');
      expect(events.single.containsKey('stage'), isFalse);
      expect(events.single.containsKey('cause'), isFalse);
      expect(
        harness.transport.writes.any(
          (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
        ),
        isFalse,
      );
      expect(harness.machine.firmwareUpdateState, FirmwareUpdateState.idle);
      expect(
        events.single['error'],
        contains('FirmwareUpdateCancelledException'),
      );
    },
  );

  test(
    'disconnect while initialization is pending is not an erase failure',
    () async {
      final harness = await _blockedInitializationHandler();
      addTearDown(() async {
        harness.settings.release();
        await harness.controller.dispose();
      });
      harness.transport.writes.clear();

      final operation = harness.controller.updateFirmware(
        Uint8List(16),
        onProgress: (_) {},
      );
      harness.transport.emitConnectionState(ConnectionState.disconnected);

      Object? failure;
      StackTrace? failureStack;
      try {
        await operation;
      } catch (error, stackTrace) {
        failure = error;
        failureStack = stackTrace;
      }
      expect(failure, isA<FirmwareUpdateStageException>());
      final stageFailure = failure as FirmwareUpdateStageException;
      expect(stageFailure.stage, 'controller');
      expect(stageFailure.cause, isA<StateError>());
      expect(stageFailure.stackTrace.toString(), contains('_runDeviceWrite'));
      expect(failureStack, isNotNull);
      expect(
        harness.transport.writes.any(
          (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
        ),
        isFalse,
      );
      expect(
        harness.transport.writes.any(
          (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
        ),
        isFalse,
      );
      expect(harness.machine.firmwareUpdateState, FirmwareUpdateState.idle);
    },
  );

  test('HTTP disconnect during initialization reports controller origin and closes cleanly', () async {
    final previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = <LogRecord>[];
    final logSubscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    final harness = await _blockedInitializationHandler();
    addTearDown(() async {
      harness.settings.release();
      await harness.controller.dispose();
    });
    harness.transport.writes.clear();
    final response = await _apply(
      harness.handler,
      jsonEncode({'artifactId': 'de1-1358'}),
    );
    harness.transport.emitConnectionState(ConnectionState.disconnected);
    final events = await _readEvents(response);
    expect(response.statusCode, 200);
    expect(events, hasLength(1));
    expect(events.single['status'], 'error');
    expect(events.single['stage'], 'controller');
    expect(events.single['cause'], contains('Machine changed'));
    expect(events.single['error'], contains('Machine changed'));
    expect(
      events.single['error'],
      isNot(contains('FirmwareUpdateCancelledException')),
    );
    expect(
      harness.transport.writes.any(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      isFalse,
    );
    expect(harness.machine.firmwareUpdateState, FirmwareUpdateState.idle);
    final handlerFailureLogs = logs
        .where(
          (record) =>
              record.loggerName == 'FirmwareHandler' &&
              record.message.contains('stage=controller'),
        )
        .toList();
    expect(handlerFailureLogs, hasLength(1));
    expect(handlerFailureLogs.single.error, isA<StateError>());
    expect(handlerFailureLogs.single.stackTrace, isNotNull);
  });

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
    final transport = _VerificationTransport();
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

    final time = FakeAsync();
    final response = await _flushVirtual(
      time,
      'verification timeout request',
      time.run((_) => _raw(handler, List.filled(16, 1))),
    );
    var finished = false;
    final reading = time.run(
      (_) => _readEvents(response).then((events) {
        finished = true;
        return events;
      }),
    );
    time.elapse(Duration.zero);
    await _flushVirtual(
      time,
      'verification write reached firmware map request',
      transport.verificationRequested.future,
    );
    expect(de1.firmwareUpdateState, FirmwareUpdateState.verifying);
    time.elapse(
      const Duration(milliseconds: 100) - const Duration(microseconds: 1),
    );
    await _flushVirtual(
      time,
      'verification timeout pre-deadline microtasks',
      time.run((_) => Future<void>.value()),
    );
    expect(finished, isFalse);
    time.elapse(const Duration(microseconds: 1));
    final events = await _flushVirtual(
      time,
      'verification timeout response close',
      reading,
    );
    expect(finished, isTrue);
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
    expect(events.map((event) => event['status']), [
      'erasing',
      'uploading',
      'error',
    ]);
    expect(
      events.last['error'],
      contains('Timed out waiting for firmware verification'),
    );
    expect(
      time.nonPeriodicTimerCount,
      2,
      reason:
          'expected 2 pending 250 ms polling timers owned by UnifiedDe1 '
          'firmware polling (erase + verification); ownership: production '
          'Future.any losers, see unified_de1.firmware.dart:203-206',
    );
    expect(time.periodicTimerCount, 0);

    time.elapse(const Duration(milliseconds: 150));
    expect(time.nonPeriodicTimerCount, 0);
    expect(time.periodicTimerCount, 0);

    await _flushVirtual(
      time,
      'verification timeout device disposal',
      time.run((_) => de1.dispose()),
    );
    expect(time.nonPeriodicTimerCount, 0);
    expect(time.periodicTimerCount, 0);
  });

  for (final model in ['DE1', 'DE1Plus', 'DE1Cafe']) {
    test('model $model recommends 1358 and managed apply starts', () async {
      final machine = _FirmwareDe1(version: '1333', model: model);
      controller.machine = machine;

      final catalogResponse = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/machine/firmware')),
      );
      final catalog = jsonDecode(
        await catalogResponse.readAsString(),
      ) as Map<String, dynamic>;

      expect(catalog['updateAvailable'], isTrue);
      expect(catalog['recommendedArtifactId'], 'de1-1358');
      final artifacts = catalog['artifacts'] as List<dynamic>;
      for (final id in ['de1-1352', 'de1-1358']) {
        final artifact = artifacts.singleWhere(
          (artifact) => artifact['id'] == id,
        ) as Map<String, dynamic>;
        expect(artifact['eligibility'], {
          'status': 'applicable',
          'reasons': <dynamic>[],
        }, reason: 'artifact $id should be applicable for $model');
      }

      final response = await _apply(
        handler,
        jsonEncode({'artifactId': 'de1-1358'}),
      );
      expect(response.statusCode, 200);
      expect(await _readEvents(response), [
        {'status': 'erasing', 'progress': 0.0},
        {'status': 'uploading', 'progress': 1.0},
        {'status': 'done', 'progress': 1.0},
      ]);
      expect(machine.updateCalls, 1);
    });
  }

  for (final (model, version, notNewer) in [
    ('DE1Plus', '1358', true),
    ('DE1Turbo', '1333', false),
  ]) {
    test('catalog reports no update for $model at $version without conflating '
        'eligibility reasons', () async {
      controller.machine = _FirmwareDe1(version: version, model: model);

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/machine/firmware')),
      );
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(body['updateAvailable'], isFalse);
      expect(body['recommendedArtifactId'], isNull);
      final expected = notNewer ? 'not_newer' : 'model_incompatible';
      final unexpected = notNewer ? 'model_incompatible' : 'not_newer';
      for (final artifact in body['artifacts'] as List<dynamic>) {
        final entry = artifact as Map<String, dynamic>;
        final eligibility = entry['eligibility'] as Map<String, dynamic>;
        final reasons = eligibility['reasons'] as List<dynamic>;
        expect(eligibility['status'], 'notApplicable');
        expect(
          reasons,
          contains(expected),
          reason: 'artifact ${entry['id']} for $model at $version',
        );
        expect(
          reasons,
          isNot(contains(unexpected)),
          reason: 'artifact ${entry['id']} for $model at $version',
        );
      }
    });
  }
}

Handler _firmwareHandler(
  _FixedController controller, {
  int maxRawBodyBytes = 16 * 1024 * 1024,
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

Future<_LoadedFirmwareBundle> _loadFirmwareBundle() async {
  final manifest = await rootBundle.load('assets/firmware/manifest.json');
  final image = await rootBundle.load('assets/firmware/de1/de1-1358.bin');
  return _LoadedFirmwareBundle(manifest, image);
}

Handler _handlerWithBundle(De1Controller controller, AssetBundle bundle) {
  final app = Router().plus;
  FirmwareHandler(
    controller: controller,
    catalog: BundledFirmwareCatalog(bundle: bundle),
  ).addRoutes(app);
  return app.call;
}

Future<
  ({
    Handler handler,
    De1Controller controller,
    UnifiedDe1 machine,
    FakeBleTransport transport,
    _BlockingMachineSettingsStore settings,
  })
>
_blockedInitializationHandler() async {
  final devices = DeviceController([MockDeviceDiscoveryService()]);
  await devices.initialize();
  final settings = _BlockingMachineSettingsStore();
  final controller = De1Controller(
    controller: devices,
    machineSettings: settings,
  );
  final transport = FakeBleTransport(traceEnabled: true);
  transport.queueOnConnectResponses(
    v13Model: 3,
    cpuFirmwareBuild: 1333,
    calFlowEst: 0,
  );
  for (final item in [
    MMRItem.targetSteamFlow,
    MMRItem.hotWaterFlowRate,
    MMRItem.flushFlowRate,
    MMRItem.flushTimeout,
    MMRItem.flushTemp,
  ]) {
    transport.queueMmrResponseInt(item, 0);
  }
  final machine = UnifiedDe1(transport: transport);
  await controller.connectToDe1(machine);
  await settings.readStarted.future;
  final app = Router().plus;
  FirmwareHandler(
    controller: controller,
    catalog: BundledFirmwareCatalog(bundle: rootBundle),
  ).addRoutes(app);
  return (
    handler: app.call,
    controller: controller,
    machine: machine,
    transport: transport,
    settings: settings,
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

const _flushVirtualIterationLimit = 100;

Future<T> _flushVirtual<T>(
  FakeAsync time,
  String phase,
  Future<T> future,
) async {
  var completed = false;
  var failed = false;
  Object? error;
  StackTrace? errorStack;
  future.then<void>(
    (_) {
      completed = true;
    },
    onError: (Object caught, StackTrace stack) {
      completed = true;
      failed = true;
      error = caught;
      errorStack = stack;
    },
  );
  for (var turn = 0; turn < _flushVirtualIterationLimit && !completed; turn++) {
    time.flushMicrotasks();
    await Future<void>.delayed(Duration.zero);
  }
  time.flushMicrotasks();
  if (!completed) {
    fail(
      'Operation "$phase" did not settle without advancing time '
      '(non-periodic timers: ${time.nonPeriodicTimerCount}, '
      'periodic timers: ${time.periodicTimerCount})',
    );
  }
  if (failed) {
    Error.throwWithStackTrace(
      StateError(
        'Operation "$phase" completed with error: $error '
        '(non-periodic timers: ${time.nonPeriodicTimerCount}, '
        'periodic timers: ${time.periodicTimerCount})',
      ),
      errorStack!,
    );
  }
  return future;
}
