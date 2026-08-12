import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/mmr_address.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../../../../../helpers/barrier_ble_transport.dart';

void main() {
  late _BarrierBleTransport transport;
  late UnifiedDe1 de1;

  setUp(() async {
    transport = _BarrierBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(calFlowEst: 0);
    de1 = UnifiedDe1(transport: transport);
    await de1.onConnect();
    transport.writes.clear();
  });

  test('firmware waits for an already active MMR read', () async {
    final readRequest = transport.nextWrite(Endpoint.readFromMMR.uuid);
    final read = de1.getSteamFlow();
    await readRequest;

    final eraseBarrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.fwMapRequest.uuid, eraseBarrier);
    final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
    final update = de1.updateFirmware(Uint8List(0), onProgress: (_) {});
    final updateFailure = expectLater(update, throwsA(isA<StateError>()));

    await _flushEventQueue();
    expect(transport.writeCount(Endpoint.fwMapRequest.uuid), 0);

    transport.emitMmrResponseInt(MMRItem.targetSteamFlow, 100);
    await read;
    await eraseRequest;

    eraseBarrier.completeError(StateError('erase failed'));
    await updateFailure;
  });

  test('waiting firmware takes priority over later MMR operations', () async {
    final activeMmrBarrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.writeToMMR.uuid, activeMmrBarrier);
    final activeMmrRequest = transport.nextWrite(Endpoint.writeToMMR.uuid);
    final activeMmr = de1.setSteamFlow(1.0);
    await activeMmrRequest;

    final eraseBarrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.fwMapRequest.uuid, eraseBarrier);
    final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
    final update = de1.updateFirmware(Uint8List(0), onProgress: (_) {});
    final updateFailure = expectLater(update, throwsA(isA<StateError>()));
    await _flushEventQueue();

    transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 100);
    final queuedRead = de1.getSteamFlow();
    await _flushEventQueue();
    expect(transport.writeCount(Endpoint.readFromMMR.uuid), 0);

    activeMmrBarrier.complete();
    await activeMmr;
    await eraseRequest;
    expect(transport.writeCount(Endpoint.readFromMMR.uuid), 0);

    eraseBarrier.completeError(StateError('erase failed'));
    await updateFailure;
    await queuedRead;
    expect(transport.writeCount(Endpoint.readFromMMR.uuid), 1);
  });

  test('disconnect while waiting for firmware ownership skips erase', () async {
    final activeMmrRequest = transport.nextWrite(Endpoint.readFromMMR.uuid);
    final activeMmr = de1.getSteamFlow();
    await activeMmrRequest;

    final eraseBarrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.fwMapRequest.uuid, eraseBarrier);
    final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
    final update = de1.updateFirmware(Uint8List(0), onProgress: (_) {});
    await _flushEventQueue();

    await de1.disconnect();
    transport.emitMmrResponseInt(MMRItem.targetSteamFlow, 100);
    await activeMmr;

    final cancellation = expectLater(
      update,
      throwsA(isA<FirmwareUpdateCancelledException>()),
    );
    final outcome = await Future.any([
      cancellation.then((_) => 'cancelled'),
      eraseRequest.then((_) => 'erase'),
    ]);
    if (outcome == 'erase') {
      eraseBarrier.completeError(StateError('unexpected erase'));
      await cancellation;
    }

    expect(outcome, 'cancelled');
    expect(transport.writeCount(Endpoint.fwMapRequest.uuid), 0);

    transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 100);
    await de1.getSteamFlow();
  });

  test('firmware owns the tunnel until failure releases queued MMR', () async {
    final eraseBarrier = Completer<void>();
    transport.pauseNextWrite(Endpoint.fwMapRequest.uuid, eraseBarrier);
    final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
    final update = de1.updateFirmware(Uint8List(0), onProgress: (_) {});
    final updateFailure = expectLater(update, throwsA(isA<StateError>()));
    await eraseRequest;

    transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 100);
    final queuedRead = de1.getSteamFlow();
    await _flushEventQueue();
    expect(transport.writeCount(Endpoint.readFromMMR.uuid), 0);

    eraseBarrier.completeError(StateError('erase failed'));
    await updateFailure;
    await queuedRead;
    expect(transport.writeCount(Endpoint.readFromMMR.uuid), 1);
  });

  test(
    'MMR read holds its permit through retries and retry settling',
    () async {
      transport.dropNextMmrResponses = 1;
      transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 100);
      final firstReadRequest = transport.nextWrite(Endpoint.readFromMMR.uuid);
      final read = de1.getSteamFlow();
      await firstReadRequest;

      final eraseBarrier = Completer<void>();
      transport.pauseNextWrite(Endpoint.fwMapRequest.uuid, eraseBarrier);
      final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
      final update = de1.updateFirmware(Uint8List(0), onProgress: (_) {});
      final updateFailure = expectLater(update, throwsA(isA<StateError>()));
      final retryRequest = transport.nextWrite(Endpoint.readFromMMR.uuid);

      final firstWireOperation = await Future.any([
        retryRequest.then((_) => 'retry'),
        eraseRequest.then((_) => 'erase'),
      ]);
      expect(firstWireOperation, 'retry');

      await read;
      await eraseRequest;
      eraseBarrier.completeError(StateError('erase failed'));
      await updateFailure;
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'MMR issued during firmware follows final firmware traffic',
    () async {
      transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
      transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
      final eraseRequest = transport.nextWrite(Endpoint.fwMapRequest.uuid);
      final update = de1.updateFirmware(
        Uint8List.fromList(List<int>.filled(16, 0xab)),
        onProgress: (_) {},
      );
      await eraseRequest;

      transport.queueMmrResponseInt(MMRItem.targetSteamFlow, 100);
      final read = de1.getSteamFlow();
      await update;
      await read;

      final characteristics = transport.writes
          .map((write) => write.characteristicUUID)
          .toList();
      expect(
        characteristics.indexOf(Endpoint.readFromMMR.uuid),
        greaterThan(characteristics.lastIndexOf(Endpoint.fwMapRequest.uuid)),
      );
      expect(
        characteristics.indexOf(Endpoint.readFromMMR.uuid),
        greaterThan(characteristics.lastIndexOf(Endpoint.writeToMMR.uuid)),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

class _BarrierBleTransport extends BarrierBleTransport {
  int writeCount(String characteristicUuid) => writes
      .where((write) => write.characteristicUUID == characteristicUuid)
      .length;

  void emitMmrResponseInt(MmrAddress item, int value) {
    final response = Uint8List(20);
    final responseData = ByteData.sublistView(response);
    final addressData = ByteData(4)..setInt32(0, item.address, Endian.big);
    responseData.setUint8(1, addressData.getUint8(1));
    responseData.setUint8(2, addressData.getUint8(2));
    responseData.setUint8(3, addressData.getUint8(3));
    responseData.setInt32(4, value, Endian.little);
    subscribers[Endpoint.readFromMMR.uuid]?.call(response);
  }
}

Future<void> _flushEventQueue() => Future<void>.delayed(Duration.zero);
