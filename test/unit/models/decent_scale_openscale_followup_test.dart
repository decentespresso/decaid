import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/profile.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';

import '../../helpers/fake_ble_transport.dart';

const _hdsV258Status = [0x03, 0x0A, 0x00, 0x00, 0x64, 0x02, 0x58];
const _hdsV3114Status = [0x03, 0x0A, 0x00, 0x00, 0x64, 0x03, 0x1E];
const _hdsVoltage = [0x03, 0x22, 0x00, 0x64, 0x00, 0x00, 0x45];

class _OpenScaleBleTransport extends FakeBleTransport {
  _OpenScaleBleTransport({required this.statusNotification});

  List<int> statusNotification;
  bool respondToLedStatus = true;
  bool respondToVoltage = true;

  @override
  String get id => 'openscale-followup-test';

  @override
  String get name => 'OpenScale Follow-up Test';

  @override
  Future<void> connect() async {
    await super.connect();
    emitConnectionState(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    await super.disconnect();
    emitConnectionState(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    DecentScale.serviceIdentifier.long,
  ];

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
    if (data.length == 7 &&
        data[1] == 0x0A &&
        data[2] == 0x01 &&
        respondToLedStatus) {
      scheduleMicrotask(() => emitScaleNotification(statusNotification));
    }
    if (data.length == 7 && data[1] == 0x22 && respondToVoltage) {
      scheduleMicrotask(() => emitScaleNotification(_hdsVoltage));
    }
  }

  void emitScaleNotification(List<int> data) {
    subscribers[DecentScale.dataCharacteristic.long]?.call(
      Uint8List.fromList(data),
    );
  }

  void dropLink() => emitConnectionState(ConnectionState.disconnected);

  bool hasCommand(int command, [int? subcommand, int? parameter]) => writes.any(
    (write) =>
        write.data.length >= 4 &&
        write.data[1] == command &&
        (subcommand == null || write.data[2] == subcommand) &&
        (parameter == null || write.data[3] == parameter),
  );
}

Future<void> _connectAndNegotiate(DecentScale scale) async {
  await scale.onConnect();
  await pumpEventQueue();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await pumpEventQueue();
}

void main() {
  test(
    'display-off reconnect reasserts darkness and retains power-off evidence',
    () async {
      final transport = _OpenScaleBleTransport(
        statusNotification: _hdsV258Status,
      );
      final scale = DecentScale(transport: transport);
      await _connectAndNegotiate(scale);

      expect(scale.debugProfile.identity, DecentScaleIdentity.halfDecentScale);
      expect(scale.debugProfile.capabilities.supportsSoftSleep, isFalse);
      expect(scale.debugProfile.capabilities.supportsPowerOff, isTrue);

      transport.writes.clear();
      await scale.sleepDisplay();
      expect(transport.hasCommand(0x0A, 0x00), isTrue);

      transport.writes.clear();
      transport.dropLink();
      await pumpEventQueue();
      await scale.onConnect();
      await pumpEventQueue();

      expect(transport.hasCommand(0x0A, 0x00), isTrue);
      expect(scale.debugProfile.identity, DecentScaleIdentity.unknown);

      transport.writes.clear();
      await scale.disconnect();
      expect(transport.hasCommand(0x0A, 0x02), isTrue);

      await transport.dispose();
    },
  );

  test('SoftSleep wake waits for a post-wake status frame', () async {
    final transport = _OpenScaleBleTransport(
      statusNotification: _hdsV3114Status,
    );
    final scale = DecentScale(transport: transport);
    await _connectAndNegotiate(scale);
    expect(scale.debugProfile.capabilities.supportsSoftSleep, isTrue);

    await scale.sleepDisplay();
    transport.writes.clear();
    transport.respondToLedStatus = false;

    var wakeCompleted = false;
    final wake = scale.wakeDisplay().whenComplete(() => wakeCompleted = true);
    await pumpEventQueue();

    expect(transport.hasCommand(0x0A, 0x04, 0x00), isTrue);
    expect(transport.hasCommand(0x0A, 0x01), isTrue);
    expect(wakeCompleted, isFalse);

    transport.emitScaleNotification(_hdsV3114Status);
    await wake;
    expect(wakeCompleted, isTrue);

    await scale.disconnectForHandoff();
    await transport.dispose();
  });
}
