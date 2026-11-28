import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  late FakeBleTransport transport;
  late UnifiedDe1 de1;
  late List<De1RawMessage> notifications;
  late List<De1RawMessage> connectionNotifications;
  late StreamSubscription<De1RawMessage> rawSubscription;

  setUp(() async {
    transport = FakeBleTransport()..queueOnConnectResponses();
    de1 = UnifiedDe1(transport: transport);
    notifications = [];
    rawSubscription = de1.rawOutStream
        .where((message) => message.operation == De1RawOperationType.notify)
        .listen(notifications.add);
    await de1.onConnect();
    await pumpEventQueue();
    connectionNotifications = List.of(notifications);
    notifications.clear();
  });

  test('initial characteristic reads are not notifications', () {
    expect(
      connectionNotifications.where(
        (message) =>
            message.characteristicUUID == Endpoint.stateInfo.uuid ||
            message.characteristicUUID == Endpoint.shotSettings.uuid,
      ),
      isEmpty,
    );
  });

  tearDown(() async {
    await rawSubscription.cancel();
    await de1.dispose();
  });

  test('water notifications do not depend on typed listeners', () async {
    transport.emitNotification(Endpoint.waterLevels, [0, 42, 0, 12]);
    await pumpEventQueue();

    expect(notifications, hasLength(1));
    expect(notifications.single.characteristicUUID, Endpoint.waterLevels.uuid);
    expect(notifications.single.payload, '002A000C');

    final first = de1.waterLevels.listen((_) {});
    final second = de1.waterLevels.listen((_) {});
    await pumpEventQueue();
    expect(notifications, hasLength(1));

    for (var i = 0; i < 3; i++) {
      await de1.waterLevels.first;
    }
    expect(notifications, hasLength(1));

    transport.emitNotification(Endpoint.waterLevels, [0, 43, 0, 12]);
    await pumpEventQueue();
    expect(notifications, hasLength(2));
    expect(notifications.last.payload, '002B000C');
    await first.cancel();
    await second.cancel();
  });

  test(
    'settings replay and local writes are not received notifications',
    () async {
      final settings = await de1.shotSettings.first;
      await de1.shotSettings.first;
      await de1.updateShotSettings(settings);
      await pumpEventQueue();
      expect(
        notifications.where(
          (message) => message.characteristicUUID == Endpoint.shotSettings.uuid,
        ),
        isEmpty,
      );

      transport.emitNotification(Endpoint.shotSettings, List<int>.filled(9, 0));
      await pumpEventQueue();
      await de1.shotSettings.first;
      expect(
        notifications.where(
          (message) => message.characteristicUUID == Endpoint.shotSettings.uuid,
        ),
        hasLength(1),
      );
    },
  );

  test('reconnect ends old water listeners and drops old replay', () async {
    final oldValues = <Object>[];
    var oldDone = false;
    final oldSubscription = de1.waterLevels.listen(
      oldValues.add,
      onDone: () => oldDone = true,
    );
    final staleNotification = transport.subscribers[Endpoint.waterLevels.uuid]!;
    transport.emitNotification(Endpoint.waterLevels, [0, 42, 0, 12]);
    await pumpEventQueue();
    await de1.disconnect();
    await pumpEventQueue();
    expect(oldDone, isTrue);

    transport.queueOnConnectResponses();
    await de1.onConnect();
    final newValues = <Object>[];
    final newSubscription = de1.waterLevels.listen(newValues.add);
    staleNotification(Uint8List.fromList([0, 44, 0, 12]));
    await pumpEventQueue();
    expect(newValues, isEmpty);

    transport.emitNotification(Endpoint.waterLevels, [0, 43, 0, 12]);
    await pumpEventQueue();
    expect(oldValues, hasLength(1));
    expect(newValues, hasLength(1));
    await oldSubscription.cancel();
    await newSubscription.cancel();
  });
}
