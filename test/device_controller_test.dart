import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';

class _FlakyAttachService extends DeviceDiscoveryService
    implements DeviceAttachNotifier {
  final StreamController<DeviceAttachedEvent> _attachments =
      StreamController<DeviceAttachedEvent>.broadcast();
  late final StreamController<List<Device>> _devices =
      StreamController<List<Device>>.broadcast(
        onListen: () => deviceListens++,
        onCancel: () => deviceCancels++,
      );
  int initializeCalls = 0;
  int deviceListens = 0;
  int deviceCancels = 0;
  bool failNextInitialization = true;

  @override
  Stream<List<Device>> get devices => _devices.stream;

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attachments.stream;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failNextInitialization) {
      failNextInitialization = false;
      throw StateError('scanner unavailable');
    }
  }

  void emitAttach() =>
      _attachments.add(const DeviceAttachedEvent(name: 'test'));

  Future<void> dispose() async {
    await _attachments.close();
    await _devices.close();
  }
}

void main() {
  test('failed scanner initialization does not duplicate attach listeners on retry', () async {
    final service = _FlakyAttachService();
    final controller = DeviceController([service]);
    var attachments = 0;
    final subscription = controller.deviceAttached.listen((_) {
      attachments++;
    });

    await controller.initialize();
    expect(controller.initializationFailures, hasLength(1));

    await controller.initialize();
    service.emitAttach();
    await Future<void>.delayed(Duration.zero);

    expect(service.initializeCalls, 2);
    expect(attachments, 1);

    await subscription.cancel();
    controller.dispose();
    await service.dispose();
  });

  test('startup outcome blocks until the only scanner recovers', () async {
    final service = _FlakyAttachService();
    final controller = DeviceController([service]);

    await controller.initialize();
    expect(controller.startupOutcome.recoveryRequired, isTrue);
    expect(controller.startupOutcome.blocking, isTrue);

    await controller.initialize();
    expect(controller.startupOutcome.recoveryRequired, isFalse);
    expect(controller.startupOutcome.blocking, isFalse);
    expect(service.deviceListens, 1);
    expect(service.deviceCancels, 0);

    controller.dispose();
    expect(service.deviceCancels, 1);
    await service.dispose();
  });
}
