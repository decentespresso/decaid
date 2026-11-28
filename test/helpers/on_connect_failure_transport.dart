import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import 'recovering_firmware_transport.dart';

class OnConnectFailureTransport extends RecoveringFirmwareTransport {
  int pendingConnectFailures = 0;

  bool delayNextConnectFailure = false;
  final Completer<void> connectDispatched = Completer<void>();
  Completer<void>? _delayedConnectRelease;

  bool holdNextRequestedStateWrite = false;
  final Completer<void> requestedStateWriteDispatched = Completer<void>();
  Completer<void>? _requestedStateWriteRelease;

  void releaseDelayedConnectFailure() {
    final release = _delayedConnectRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseRequestedStateWrite() {
    final release = _requestedStateWriteRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<void> connect() async {
    if (pendingConnectFailures > 0) {
      pendingConnectFailures--;
      throw StateError('simulated transport connect failure');
    }
    if (delayNextConnectFailure) {
      delayNextConnectFailure = false;
      if (!connectDispatched.isCompleted) connectDispatched.complete();
      await (_delayedConnectRelease ??= Completer<void>()).future;
      throw StateError('simulated delayed transport connect failure');
    }
    await super.connect();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.requestedState.uuid &&
        holdNextRequestedStateWrite) {
      holdNextRequestedStateWrite = false;
      await super.write(
        serviceUUID,
        characteristicUUID,
        data,
        withResponse: withResponse,
        timeout: timeout,
      );
      if (!requestedStateWriteDispatched.isCompleted) {
        requestedStateWriteDispatched.complete();
      }
      await (_requestedStateWriteRelease ??= Completer<void>()).future;
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
}
