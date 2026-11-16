import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';

class _FlakyAttachService extends DeviceDiscoveryService
    implements DeviceAttachNotifier {
  final StreamController<DeviceAttachedEvent> _attachments =
      StreamController<DeviceAttachedEvent>.broadcast();
  int initializeCalls = 0;
  bool failNextInitialization = true;

  @override
  Stream<List<Device>> get devices => const Stream.empty();

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

  Future<void> dispose() => _attachments.close();
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
}
