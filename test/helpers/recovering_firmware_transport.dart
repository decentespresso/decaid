import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/errors.dart';

import 'fake_ble_transport.dart';

int _addressOf(Uint8List request) =>
    (request[1] << 16) | (request[2] << 8) | request[3];

int _wordOf(Uint8List request) =>
    ByteData.sublistView(request).getUint32(4, Endian.little);

class RecoveringFirmwareTransport extends FakeBleTransport {
  final Map<int, int> firmwareWords = {};
  final Map<int, int> readCounts = {};
  final Map<int, List<int>> writesByAddress = {};

  int pendingReadTimeouts = 0;
  int pendingWriteTimeouts = 0;
  int reconnectAttempts = 0;
  int? reconnectBudget;
  bool failCalFlowEstReads = false;
  bool alwaysTimeoutCalFlowEstReads = false;
  bool refuseReconnect = false;
  bool holdCalFlowEstReads = false;

  bool failReleasedCalFlowEstReads = false;

  bool timeoutReleasedCalFlowEstReads = false;
  int heldCalFlowEstResponses = 0;
  int? heldCalFlowEstResponseWord;
  final Completer<void> heldCalFlowEstReadSettled = Completer<void>();
  bool holdNextMmrWrite = false;
  bool holdNextConnect = false;
  bool timeoutNextRequestedStateWrite = false;
  Object? nextCalFlowEstWriteError;
  int calFlowEstWriteAttempts = 0;
  final Completer<void> calFlowEstReadEntered = Completer<void>();
  Completer<void>? _calFlowEstReadRelease;
  final Completer<void> mmrWriteDispatched = Completer<void>();
  Completer<void>? _mmrWriteRelease;
  final Completer<void> connectEntered = Completer<void>();
  Completer<void>? _connectRelease;

  set machineRawCalFlowEst(int raw) {
    firmwareWords[MMRItem.calFlowEst.address] = raw;
  }

  List<int> get calFlowEstWrites =>
      writesByAddress[MMRItem.calFlowEst.address] ?? const <int>[];

  int get calFlowEstReads => readCounts[MMRItem.calFlowEst.address] ?? 0;

  void timeoutNextMmrRead() => pendingReadTimeouts++;

  void timeoutNextMmrWrite() => pendingWriteTimeouts++;

  void releaseCalFlowEstRead() {
    final release = _calFlowEstReadRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseMmrWrite() {
    final release = _mmrWriteRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseConnect() {
    final release = _connectRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  void queueConnectResponses({int serialN = 12345}) {
    queueMmrResponseInt(MMRItem.v13Model, 1);
    queueMmrResponseInt(MMRItem.ghcInfo, 0);
    queueMmrResponseInt(MMRItem.serialN, serialN);
    queueMmrResponseInt(MMRItem.cpuFirmwareBuild, 1300);
    queueMmrResponseInt(MMRItem.heaterV, 230);
    queueMmrResponseInt(MMRItem.refillKitPresent, 0);
  }

  @override
  Future<void> connect() async {
    if (connectCalls > 0) {
      reconnectAttempts++;
      final budget = reconnectBudget;
      if (budget != null && reconnectAttempts > budget) {
        throw StateError('simulated reconnect budget exhausted');
      }
      if (holdNextConnect) {
        holdNextConnect = false;
        if (!connectEntered.isCompleted) connectEntered.complete();
        await (_connectRelease ??= Completer<void>()).future;
      }
    }
    if (refuseReconnect && connectCalls > 0) {
      throw StateError('simulated reconnect failure');
    }
    await super.connect();
    queueConnectResponses();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.readFromMMR.uuid) {
      await _writeMmrRead(data);
      return;
    }
    if (characteristicUUID == Endpoint.writeToMMR.uuid) {
      await _writeMmr(data);
      return;
    }
    if (characteristicUUID == Endpoint.requestedState.uuid &&
        timeoutNextRequestedStateWrite) {
      timeoutNextRequestedStateWrite = false;
      await super.write(
        serviceUUID,
        characteristicUUID,
        data,
        withResponse: withResponse,
        timeout: timeout,
      );
      throw BleTimeoutException('requestedState write after dispatch');
    }
    return super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  Future<void> _writeMmrRead(Uint8List request) async {
    final address = _addressOf(request);
    readCounts[address] = (readCounts[address] ?? 0) + 1;
    if (address == MMRItem.calFlowEst.address) {
      if (holdCalFlowEstReads) {
        if (!calFlowEstReadEntered.isCompleted) {
          calFlowEstReadEntered.complete();
        }
        try {
          await (_calFlowEstReadRelease ??= Completer<void>()).future;
          final raw = firmwareWords[address];
          if (raw != null) {
            heldCalFlowEstResponses++;
            heldCalFlowEstResponseWord = raw;
            _emitResponse(address, raw);
          }
          if (timeoutReleasedCalFlowEstReads) {
            timeoutReleasedCalFlowEstReads = false;
            throw BleTimeoutException('calFlowEst read after dispatch');
          }
          if (failReleasedCalFlowEstReads) {
            throw const DeviceNotConnectedException.machine();
          }
        } finally {
          if (!heldCalFlowEstReadSettled.isCompleted) {
            heldCalFlowEstReadSettled.complete();
          }
        }
        return;
      }
      if (failCalFlowEstReads) {
        throw StateError('simulated calFlowEst read failure');
      }
      if (alwaysTimeoutCalFlowEstReads) {
        _emitResponse(address, firmwareWords[address] ?? 0);
        throw BleTimeoutException('calFlowEst read after dispatch');
      }
    }
    final raw = firmwareWords[address];
    if (raw == null) {
      await super.write(de1ServiceUUID, Endpoint.readFromMMR.uuid, request);
      return;
    }
    _emitResponse(address, raw);
    if (pendingReadTimeouts > 0) {
      pendingReadTimeouts--;
      throw BleTimeoutException('mmr read after dispatch');
    }
  }

  Future<void> _writeMmr(Uint8List request) async {
    final address = _addressOf(request);
    final word = _wordOf(request);
    final isCalFlowEst = address == MMRItem.calFlowEst.address;
    if (isCalFlowEst) {
      calFlowEstWriteAttempts++;
      final error = nextCalFlowEstWriteError;
      if (error != null) {
        nextCalFlowEstWriteError = null;
        throw error;
      }
    }
    writesByAddress.putIfAbsent(address, () => <int>[]).add(word);
    if (isCalFlowEst) {
      machineRawCalFlowEst = word;
    }
    await super.write(de1ServiceUUID, Endpoint.writeToMMR.uuid, request);
    if (holdNextMmrWrite) {
      holdNextMmrWrite = false;
      if (!mmrWriteDispatched.isCompleted) mmrWriteDispatched.complete();
      await (_mmrWriteRelease ??= Completer<void>()).future;
    }
    if (pendingWriteTimeouts > 0) {
      pendingWriteTimeouts--;
      throw BleTimeoutException('mmr write after dispatch');
    }
  }

  void _emitResponse(int address, int word) {
    final response = Uint8List(20);
    final view = ByteData.sublistView(response);
    view.setUint8(0, 0x04);
    view.setUint8(1, (address >> 16) & 0xFF);
    view.setUint8(2, (address >> 8) & 0xFF);
    view.setUint8(3, address & 0xFF);
    view.setInt32(4, word, Endian.little);
    final subscriber = subscribers[Endpoint.readFromMMR.uuid];
    if (subscriber == null) return;
    scheduleMicrotask(() => subscriber(response));
  }
}
