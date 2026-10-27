import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _BlockingResetTransport extends FakeBleTransport {
  final resetWriteStarted = Completer<void>();
  final releaseResetWrite = Completer<void>();
  bool _blockResetWrite = false;

  void blockNextResetWrite() => _blockResetWrite = true;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final address = MMRItem.steamPurgeMode.address;
    final isResetWrite =
        characteristicUUID == Endpoint.writeToMMR.uuid &&
        data.length >= 4 &&
        data[1] == ((address >> 16) & 0xff) &&
        data[2] == ((address >> 8) & 0xff) &&
        data[3] == (address & 0xff);
    if (_blockResetWrite && isResetWrite) {
      _blockResetWrite = false;
      resetWriteStarted.complete();
      await releaseResetWrite.future;
    }
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

class _RecordingMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> values = {};
  final List<String> reads = [];
  final List<String> updates = [];
  final List<String> clears = [];
  void Function(String identity)? onRead;

  @override
  Future<MachineSettings?> read(String identity) async {
    reads.add(identity);
    onRead?.call(identity);
    return values[identity];
  }

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
  }) async {
    updates.add(identity);
    if (identity.isEmpty) return;
    final current = values[identity];
    values[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
    );
  }

  @override
  Future<void> clear(String identity) async {
    clears.add(identity);
    values.remove(identity);
  }
}

const _shotSettings = <int>[
  0,
  150,
  30,
  75,
  50,
  30,
  36,
  94,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

List<int> _mmrWrites(FakeBleTransport transport, MmrAddress address) {
  return transport.writes
      .where(
        (write) =>
            write.characteristicUUID == Endpoint.writeToMMR.uuid &&
            write.data.length >= 8 &&
            write.data[1] == ((address.address >> 16) & 0xff) &&
            write.data[2] == ((address.address >> 8) & 0xff) &&
            write.data[3] == (address.address & 0xff),
      )
      .map(
        (write) => ByteData.sublistView(write.data).getUint32(4, Endian.little),
      )
      .toList();
}

Future<({UnifiedDe1 de1, FakeBleTransport transport})> _newMachine({
  int serialN = 0,
  FakeBleTransport? transport,
}) async {
  final machineTransport = transport ?? FakeBleTransport();
  machineTransport
    ..queueOnConnectResponses(serialN: serialN)
    ..queueRead(
      Endpoint.stateInfo.uuid,
      Uint8List.fromList([2, ...List.filled(19, 0)]),
    )
    ..queueRead(Endpoint.shotSettings.uuid, Uint8List.fromList(_shotSettings));
  final de1 = UnifiedDe1(transport: machineTransport);
  return (de1: de1, transport: machineTransport);
}

void main() {
  test(
    'legacy raw identity survives effective resolution and reconnect',
    () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      final machineSettings = _RecordingMachineSettingsStore();
      final controller = De1Controller(
        controller: deviceController,
        machineSettings: machineSettings,
      );
      final staleDevices = <UnifiedDe1>[];
      addTearDown(() async {
        await controller.dispose();
        for (final device in staleDevices) {
          await device.dispose();
        }
      });

      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      final handlerRouter = Router().plus;
      final de1Handler = De1Handler(
        controller: controller,
        settingsController: settingsController,
        scaleController: TestScaleController(TestScale()),
        workflowController: WorkflowController(),
      );
      de1Handler.addRoutes(handlerRouter);
      final handler = handlerRouter.call;

      Future<Response> post(String path, Object body) async => await handler(
        Request(
          'POST',
          Uri.parse('http://localhost$path'),
          body: jsonEncode(body),
          headers: {'content-type': 'application/json'},
        ),
      );

      final first = await _newMachine();
      final resolved = Completer<void>();
      final publication = controller.de1.listen((device) {
        if (device == first.de1) {
          first.de1.applyEffectiveIdentity(
            serial: 'resolved-serial',
            model: 'DE1Pro',
          );
          resolved.complete();
        }
      });
      addTearDown(publication.cancel);

      await controller.connectToDe1(first.de1);
      await resolved.future;
      expect(first.de1.rawMachineInfo.serialNumber, '0');
      expect(first.de1.machineInfo.serialNumber, 'resolved-serial');
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      expect(
        (await post('/api/v1/machine/settings', {'fan': 42})).statusCode,
        202,
      );
      expect(
        (await post('/api/v1/machine/settings/advanced', {
          'refillKitSetting': 1,
        })).statusCode,
        202,
      );
      expect(machineSettings.updates, ['device:fake-ble', 'device:fake-ble']);
      expect(machineSettings.values, contains('device:fake-ble'));
      expect(machineSettings.values, isNot(contains('serial:resolved-serial')));
      expect(machineSettings.reads, everyElement('device:fake-ble'));

      final second = await _newMachine();
      staleDevices.add(first.de1);
      await controller.connectToDe1(second.de1);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      expect(_mmrWrites(second.transport, MMRItem.fanThreshold).last, 42);
      expect(
        _mmrWrites(second.transport, MMRItem.refillKitPresent).last,
        De1RefillKitSettings.forceOn.hex,
      );

      final third = await _newMachine();
      var observingThirdReads = false;
      String? effectiveSerialAtThirdRead;
      machineSettings.onRead = (_) {
        if (observingThirdReads) {
          effectiveSerialAtThirdRead = third.de1.machineInfo.serialNumber;
        }
      };
      final thirdResolved = Completer<void>();
      final thirdPublication = controller.de1.listen((device) {
        if (device == third.de1) {
          third.de1.applyEffectiveIdentity(
            serial: 'resolved-before-restore',
            model: 'DE1Pro',
          );
          thirdResolved.complete();
        }
      });
      addTearDown(thirdPublication.cancel);
      staleDevices.add(second.de1);
      observingThirdReads = true;
      await controller.connectToDe1(third.de1);
      await thirdResolved.future;
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );
      expect(effectiveSerialAtThirdRead, 'resolved-before-restore');
      expect(machineSettings.reads, everyElement('device:fake-ble'));
      expect(_mmrWrites(third.transport, MMRItem.fanThreshold).last, 42);
      expect(
        _mmrWrites(third.transport, MMRItem.refillKitPresent).last,
        De1RefillKitSettings.forceOn.hex,
      );

      third.de1.clearEffectiveIdentity();
      expect(third.de1.machineInfo.serialNumber, '0');
      expect(
        (await post('/api/v1/machine/settings', {'fan': 42})).statusCode,
        202,
      );
      third.de1.applyEffectiveIdentity(
        serial: 'resolved-a-third-time',
        model: 'DE1Pro',
      );
      expect(
        (await post('/api/v1/machine/settings/advanced', {
          'refillKitSetting': 1,
        })).statusCode,
        202,
      );
      expect(machineSettings.updates, [
        'device:fake-ble',
        'device:fake-ble',
        'device:fake-ble',
        'device:fake-ble',
      ]);
      expect(
        machineSettings.values,
        isNot(contains('serial:resolved-a-third-time')),
      );
      final reset = await handler(
        Request(
          'DELETE',
          Uri.parse('http://localhost/api/v1/machine/settings/reset'),
        ),
      );
      expect(reset.statusCode, 202);
      expect(machineSettings.clears, ['device:fake-ble']);
      expect(
        machineSettings.clears,
        isNot(contains('serial:resolved-a-third-time')),
      );
      expect(_mmrWrites(third.transport, MMRItem.fanThreshold).last, 50);
      expect(
        _mmrWrites(third.transport, MMRItem.refillKitPresent).last,
        De1RefillKitSettings.auto.hex,
      );
    },
  );

  test(
    'adopted effective identity captures raw legacy machine identity',
    () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      final machineSettings = _RecordingMachineSettingsStore()
        ..values['device:fake-ble'] = const MachineSettings(
          fanThreshold: 42,
          refillKitSetting: De1RefillKitSettings.forceOn,
        );
      final controller = De1Controller(
        controller: deviceController,
        machineSettings: machineSettings,
      );
      addTearDown(controller.dispose);

      final adopted = await _newMachine();
      await adopted.de1.onConnect();
      adopted.de1.applyEffectiveIdentity(
        serial: 'already-resolved',
        model: 'DE1Pro',
      );
      controller.adoptDevice(adopted.de1);
      adopted.transport.emitConnectionState(ConnectionState.connected);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      expect(machineSettings.reads, everyElement('device:fake-ble'));
      expect(machineSettings.reads, isNot(contains('serial:already-resolved')));
      expect(_mmrWrites(adopted.transport, MMRItem.fanThreshold).last, 42);
      expect(
        _mmrWrites(adopted.transport, MMRItem.refillKitPresent).last,
        De1RefillKitSettings.forceOn.hex,
      );
    },
  );

  test(
    'reset clears the captured identity if replacement happens mid-write',
    () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      final machineSettings = _RecordingMachineSettingsStore()
        ..values['device:fake-ble'] = const MachineSettings(
          fanThreshold: 42,
          refillKitSetting: De1RefillKitSettings.forceOn,
        );
      final controller = De1Controller(
        controller: deviceController,
        machineSettings: machineSettings,
      );
      final staleDevices = <UnifiedDe1>[];
      addTearDown(() async {
        await controller.dispose();
        for (final device in staleDevices) {
          await device.dispose();
        }
      });

      final blockingTransport = _BlockingResetTransport();
      final first = await _newMachine(transport: blockingTransport);
      staleDevices.add(first.de1);
      await controller.connectToDe1(first.de1);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      blockingTransport.blockNextResetWrite();
      final reset = controller.runDeviceWrite(
        (device) => controller.applySettingsDefaults(device),
      );
      await blockingTransport.resetWriteStarted.future;

      final replacement = MockDe1(deviceId: 'replacement');
      addTearDown(replacement.disconnect);
      final replacing = controller.connectToDe1(replacement);
      blockingTransport.releaseResetWrite.complete();
      await replacing;
      await expectLater(reset, throwsA(isA<StateError>()));
      expect(machineSettings.clears, ['device:fake-ble']);
    },
  );

  test(
    'raw serial remains the settings identity after effective resolution',
    () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      final machineSettings = _RecordingMachineSettingsStore()
        ..values['serial:12345'] = const MachineSettings(
          fanThreshold: 43,
          refillKitSetting: De1RefillKitSettings.forceOff,
        );
      final controller = De1Controller(
        controller: deviceController,
        machineSettings: machineSettings,
      );
      addTearDown(controller.dispose);

      final machine = await _newMachine(serialN: 12345);
      final resolved = Completer<void>();
      final publication = controller.de1.listen((device) {
        if (device == machine.de1) {
          machine.de1.applyEffectiveIdentity(
            serial: 'account-serial',
            model: 'DE1Pro',
          );
          resolved.complete();
        }
      });
      addTearDown(publication.cancel);

      await controller.connectToDe1(machine.de1);
      await resolved.future;
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      expect(machineSettings.reads, everyElement('serial:12345'));
      expect(machineSettings.reads, isNot(contains('serial:account-serial')));
      expect(_mmrWrites(machine.transport, MMRItem.fanThreshold).last, 43);
      expect(
        _mmrWrites(machine.transport, MMRItem.refillKitPresent).last,
        De1RefillKitSettings.forceOff.hex,
      );
    },
  );
}
