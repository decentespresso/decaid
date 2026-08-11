import 'dart:async';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/test_de1.dart';
import 'plugin_test_helpers.dart';

class _CountingRuntime extends JavascriptRuntime {
  _CountingRuntime(this.delegate, {this.throwOnDispose = false});

  final JavascriptRuntime delegate;
  final bool throwOnDispose;
  int disposeCalls = 0;

  @override
  JsEvalResult callFunction(dynamic fn, dynamic obj) =>
      delegate.callFunction(fn, obj);

  @override
  T? convertValue<T>(JsEvalResult jsValue) => delegate.convertValue(jsValue);

  @override
  void dispose() {
    disposeCalls += 1;
    delegate.dispose();
    if (throwOnDispose) throw StateError('runtime disposal failed');
  }

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) =>
      delegate.evaluate(code, sourceUrl: sourceUrl);

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) =>
      delegate.evaluateAsync(code, sourceUrl: sourceUrl);

  @override
  int executePendingJob() => delegate.executePendingJob();

  @override
  String getEngineInstanceId() => delegate.getEngineInstanceId();

  @override
  void initChannelFunctions() {}

  @override
  String jsonStringify(JsEvalResult jsValue) => delegate.jsonStringify(jsValue);

  @override
  bool setupBridge(
    String channelName,
    JavascriptMessageCallback fn, {
    bool fireAndForget = false,
    Duration timeout = const Duration(seconds: 30),
  }) => delegate.setupBridge(
    channelName,
    fn,
    fireAndForget: fireAndForget,
    timeout: timeout,
  );

  @override
  void setInspectable(bool inspectable) => delegate.setInspectable(inspectable);
}

class _StreamDe1Controller extends De1Controller {
  _StreamDe1Controller(this.machineStream)
    : super(controller: DeviceController(const []));

  final Stream<De1Interface?> machineStream;

  @override
  Stream<De1Interface?> get de1 => machineStream;
}

class _SyncSnapshotDe1 extends TestDe1 {
  _SyncSnapshotDe1({required super.deviceId});

  final StreamController<MachineSnapshot> snapshots =
      StreamController<MachineSnapshot>.broadcast(sync: true);

  @override
  Stream<MachineSnapshot> get currentSnapshot => snapshots.stream;

  @override
  Future<void> dispose() async {
    await snapshots.close();
    await super.dispose();
  }
}

Future<void> _loadPlugin(
  PluginManager manager,
  String id, {
  String onUnload = '',
  String onLoad = '',
  String onEvent = '',
}) {
  return manager.loadPlugin(
    id: id,
    manifest: testManifest(
      id,
      permissions: const {
        PluginPermissions.log,
        PluginPermissions.api,
        PluginPermissions.emit,
        PluginPermissions.pluginStorage,
        PluginPermissions.eventsMachine,
      },
    ),
    settings: const {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$id",
          onLoad() { $onLoad },
          onUnload() { $onUnload },
          onEvent(event) { $onEvent }
        };
      }
    ''',
  );
}

void main() {
  test(
    'empty disposal is shared, terminal, and disposes runtime once',
    () async {
      final runtime = _CountingRuntime(getJavascriptRuntime(xhr: false));
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        js: runtime,
      );
      final streamDone = expectLater(manager.emitStream, emitsDone);

      final first = manager.dispose();
      final second = manager.dispose();

      expect(identical(first, second), isTrue);
      expect(manager.lifecycle, PluginManagerLifecycle.disposing);
      await Future.wait([first, second]);
      await streamDone;
      expect(manager.lifecycle, PluginManagerLifecycle.disposed);
      expect(runtime.disposeCalls, 1);
      expect(runtime.delegate.channelFunctions, isEmpty);
      await manager.dispose();
      expect(runtime.disposeCalls, 1);
    },
  );

  test('failed runtime disposal still leaves the manager disposed', () async {
    final runtime = _CountingRuntime(
      getJavascriptRuntime(xhr: false),
      throwOnDispose: true,
    );
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      js: runtime,
    );

    await expectLater(manager.dispose(), throwsStateError);

    expect(manager.lifecycle, PluginManagerLifecycle.disposed);
    expect(runtime.disposeCalls, 1);
    await expectLater(manager.dispose(), throwsStateError);
    expect(runtime.disposeCalls, 1);
  });

  test('unload deletes registry entry when onUnload throws', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await _loadPlugin(manager, 'throwing.plugin', onUnload: 'throw "boom";');

    await manager.unloadPlugin('throwing.plugin');

    expect(manager.loadedPlugins, isEmpty);
    expect(
      manager.js
          .evaluate('typeof globalThis.__plugins__["throwing.plugin"]')
          .stringResult,
      'undefined',
    );
  });

  test('reload persists storage written during onUnload', () async {
    final store = FakeKeyValueStoreService();
    final manager = PluginManager(kvStore: store);
    addTearDown(manager.dispose);
    await _loadPlugin(
      manager,
      'storage.plugin',
      onUnload: '''
        host.storage({
          type: "write",
          key: "lastEstimation",
          data: { value: 42 }
        });
      ''',
    );

    await _loadPlugin(manager, 'storage.plugin');

    expect(
      await store.get(namespace: 'storage.plugin', key: 'lastEstimation'),
      {'value': 42},
    );
  });

  test('dispose unloads every plugin and clears owned resources', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    await _loadPlugin(
      manager,
      'first.plugin',
      onLoad: 'setTimeout(() => {}, 60000);',
      onUnload: 'throw "boom";',
    );
    await _loadPlugin(manager, 'second.plugin');
    final pendingHttp = expectLater(
      manager.registerPendingHttp('second.plugin', 'pending'),
      throwsA(isA<PluginHttpError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await manager.dispose();
    await pendingHttp;

    expect(manager.loadedPlugins, isEmpty);
    expect(manager.activeTimerCount, 0);
    expect(manager.activePendingOpCount, 0);
    expect(manager.activeSubscriptionCount, 0);
    expect(manager.trackedPluginGenerationCount, 0);
    expect(manager.bridgeTokenCount, 0);
    expect(manager.de1Controller, isNull);
  });

  test('mutations fail as soon as disposal starts', () async {
    final releaseCancellation = Completer<void>();
    final controllerStream = StreamController<De1Interface?>(
      onCancel: () => releaseCancellation.future,
    );
    final controller = _StreamDe1Controller(controllerStream.stream);
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    await manager.attachDe1Controller(controller);

    final disposal = manager.dispose();
    var disposalDone = false;
    disposal.then((_) => disposalDone = true);

    expect(manager.lifecycle, PluginManagerLifecycle.disposing);
    expect(
      () => manager.dispatchEvent('missing', 'event', const {}),
      throwsStateError,
    );
    await expectLater(_loadPlugin(manager, 'late.plugin'), throwsStateError);
    expect(() => manager.attachDe1Controller(null), throwsStateError);
    expect(
      () => manager.registerPendingHttp('late.plugin', 'request'),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(disposalDone, isFalse);

    releaseCancellation.complete();
    await disposal;
    await controllerStream.close();
    await controller.dispose();
  });

  test('controller replacement only dispatches the newest generation', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final firstMachines = StreamController<De1Interface?>.broadcast(sync: true);
    final secondMachines = StreamController<De1Interface?>.broadcast(
      sync: true,
    );
    final firstController = _StreamDe1Controller(firstMachines.stream);
    final secondController = _StreamDe1Controller(secondMachines.stream);
    final firstMachine = TestDe1(deviceId: 'first');
    final secondMachine = TestDe1(deviceId: 'second');
    final values = <double>[];

    await _loadPlugin(
      manager,
      'events.plugin',
      onEvent:
          'if (event.name === "stateUpdate") host.emit("state", event.payload.groupTemperature);',
    );
    final eventSubscription = manager.emitStream.listen((event) {
      if (event['event'] == 'state') {
        values.add((event['payload'] as num).toDouble());
      }
    });

    await manager.attachDe1Controller(firstController);
    firstMachines.add(firstMachine);
    await Future<void>.delayed(Duration.zero);
    values.clear();

    await manager.attachDe1Controller(secondController);
    firstMachine.emitSnapshot(
      firstMachine.snapshotSubject.value.copyWith(groupTemperature: 11),
    );
    secondMachines.add(secondMachine);
    await Future<void>.delayed(Duration.zero);
    secondMachine.emitSnapshot(
      secondMachine.snapshotSubject.value.copyWith(groupTemperature: 22),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(values, isNot(contains(11)));
    expect(values, contains(22));
    expect(manager.attachmentGeneration, 2);
    expect(manager.activeSubscriptionCount, 2);

    await manager.dispose();
    await eventSubscription.cancel();
    await firstMachines.close();
    await secondMachines.close();
    await firstController.dispose();
    await secondController.dispose();
    await firstMachine.dispose();
    await secondMachine.dispose();
  });

  test(
    'machine replacement invalidates snapshots before queue cleanup',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final machines = StreamController<De1Interface?>.broadcast(sync: true);
      final controller = _StreamDe1Controller(machines.stream);
      final firstMachine = _SyncSnapshotDe1(deviceId: 'first');
      final secondMachine = TestDe1(deviceId: 'second');
      final values = <double>[];

      await _loadPlugin(
        manager,
        'events.plugin',
        onEvent:
            'if (event.name === "stateUpdate") host.emit("state", event.payload.groupTemperature);',
      );
      final eventSubscription = manager.emitStream.listen((event) {
        if (event['event'] == 'state') {
          values.add((event['payload'] as num).toDouble());
        }
      });

      await manager.attachDe1Controller(controller);
      machines.add(firstMachine);
      await Future<void>.delayed(Duration.zero);
      values.clear();

      machines.add(secondMachine);
      firstMachine.snapshots.add(
        firstMachine.snapshotSubject.value.copyWith(groupTemperature: 11),
      );
      await Future<void>.delayed(Duration.zero);
      secondMachine.emitSnapshot(
        secondMachine.snapshotSubject.value.copyWith(groupTemperature: 22),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(values, isNot(contains(11)));
      expect(values, contains(22));

      await manager.dispose();
      await eventSubscription.cancel();
      await machines.close();
      await controller.dispose();
      await firstMachine.dispose();
      await secondMachine.dispose();
    },
  );

  test('rapid controller replacements serialize', () async {
    final firstMachines = StreamController<De1Interface?>.broadcast();
    final secondMachines = StreamController<De1Interface?>.broadcast();
    final thirdMachines = StreamController<De1Interface?>.broadcast();
    final first = _StreamDe1Controller(firstMachines.stream);
    final second = _StreamDe1Controller(secondMachines.stream);
    final third = _StreamDe1Controller(thirdMachines.stream);
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());

    final firstAttach = manager.attachDe1Controller(first);
    final secondAttach = manager.attachDe1Controller(second);
    final thirdAttach = manager.attachDe1Controller(third);
    await Future.wait([firstAttach, secondAttach, thirdAttach]);
    expect(manager.de1Controller, same(third));
    expect(manager.attachmentGeneration, 3);
    expect(manager.activeSubscriptionCount, 1);

    await manager.dispose();
    await firstMachines.close();
    await secondMachines.close();
    await thirdMachines.close();
    await first.dispose();
    await second.dispose();
    await third.dispose();
  });

  test(
    'old plugin generation host messages are ignored after reload',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final events = <String>[];
      final subscription = manager.emitStream.listen(
        (event) => events.add(event['event'] as String),
      );
      addTearDown(subscription.cancel);
      await _loadPlugin(manager, 'generation.plugin');
      final oldGeneration = manager.pluginGeneration('generation.plugin');
      await manager.unloadPlugin('generation.plugin');
      await _loadPlugin(manager, 'generation.plugin');

      manager.js.evaluate('''
      sendMessage("host", JSON.stringify({
        pluginId: "generation.plugin",
        generation: $oldGeneration,
        type: "emit",
        event: "stale",
        payload: null
      }));
    ''');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, isEmpty);
    },
  );
}
