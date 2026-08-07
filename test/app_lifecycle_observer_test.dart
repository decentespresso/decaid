import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' as app;
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';

import 'helpers/test_de1.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {
  final disposed = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<void> dispose() {
    disposeCalls += 1;
    return disposed.future;
  }
}

class _StreamDe1Controller extends De1Controller {
  _StreamDe1Controller(this.machineStream)
    : super(controller: DeviceController(const []));

  final Stream<De1Interface?> machineStream;

  @override
  Stream<De1Interface?> get de1 => machineStream;
}

class _SlowCancelDe1 extends TestDe1 {
  _SlowCancelDe1(this.releaseCancellation);

  final Completer<void> releaseCancellation;
  late final StreamController<MachineSnapshot> snapshots =
      StreamController<MachineSnapshot>(
        onCancel: () => releaseCancellation.future,
      );

  @override
  Stream<MachineSnapshot> get currentSnapshot => snapshots.stream;

  @override
  Future<void> dispose() async {
    await snapshots.close();
    await super.dispose();
  }
}

void main() {
  testWidgets('detached disposes the process plugin loader', (tester) async {
    final loader = _FakePluginLoaderService();
    final observer = app.AppLifecycleObserver(pluginLoaderService: loader);

    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(loader.disposeCalls, 0);

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(loader.disposeCalls, 1);

    loader.disposed.complete();
    await tester.pump();
  });

  testWidgets('detached cannot install a replacement state subscription', (
    tester,
  ) async {
    final loader = _FakePluginLoaderService();
    final releaseCancellation = Completer<void>();
    final firstMachine = _SlowCancelDe1(releaseCancellation);
    final secondMachine = TestDe1(deviceId: 'second');
    final machines = StreamController<De1Interface?>.broadcast(sync: true);
    final controller = _StreamDe1Controller(machines.stream);
    final observer = app.AppLifecycleObserver(
      de1Controller: controller,
      pluginLoaderService: loader,
    );

    machines.add(firstMachine);
    expect(firstMachine.snapshots.hasListener, isTrue);
    loader.disposed.complete();

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);
    machines.add(secondMachine);
    releaseCancellation.complete();
    await tester.pump();
    await tester.pump();

    expect(secondMachine.snapshotSubject.hasListener, isFalse);

    await machines.close();
    await controller.dispose();
    await firstMachine.dispose();
    await secondMachine.dispose();
  });
}
