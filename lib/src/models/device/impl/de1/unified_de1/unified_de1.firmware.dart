part of 'unified_de1.dart';

/// Cadence of the firmware-verify poll fallback: fast enough to complete
/// promptly on firmware that never emits the terminal notify, slow enough to
/// add negligible traffic alongside the notify path.
const _firmwareMapPollInterval = Duration(milliseconds: 250);

extension UnifiedDe1Firmware on UnifiedDe1 {
  Future<void> _updateFirmware(
    Uint8List fwImage,
    void Function(double) onProgress,
    _FirmwareCancellationToken cancelToken,
  ) async {
    _throwIfFirmwareCancelled(cancelToken);
    await requestState(MachineState.sleeping);
    _throwIfFirmwareCancelled(cancelToken);
    await beforeFirmwareUpload();
    _throwIfFirmwareCancelled(cancelToken);

    await _firmwareMmrGate.runFirmwareExclusive(() async {
      _throwIfFirmwareCancelled(cancelToken);
      await _updateFirmwareExclusive(fwImage, onProgress, cancelToken);
    });
  }

  Future<void> _updateFirmwareExclusive(
    Uint8List fwImage,
    void Function(double) onProgress,
    _FirmwareCancellationToken cancelToken,
  ) async {
    var firmwareMapSequence = 0;
    final coordinator = _FirmwareResponseCoordinator();
    final subscription = _transport.fwMapRequest.listen((data) {
      firmwareMapSequence++;
      final response = FWMapRequestData.from(data);
      _log.info(
        'FW map recv: ${response.windowIncrement}, '
        '${response.firmwareToErase}, ${response.firmwareToMap}, '
        'err: 0x${response.error.map((value) => value.toRadixString(16).padLeft(2, '0')).join()}',
      );
      coordinator.handle(firmwareMapSequence, response);
    });

    try {
      await Future<void>.delayed(Duration.zero);
      _throwIfFirmwareCancelled(cancelToken);
      late Future<FWMapRequestData> eraseResponse;
      await _writeFirmwareMap(
        coordinator: coordinator,
        firmwareMapSequence: () => firmwareMapSequence,
        cancelToken: cancelToken,
        firmwareToErase: 1,
        predicate: _isEraseComplete,
        onResponseArmed: (response) => eraseResponse = response,
      );
      await _waitForFirmwareResponse(
        eraseResponse,
        cancelToken,
        firmwareEraseTimeout,
        'Timed out waiting for firmware erase',
        _isEraseComplete,
      );

      _throwIfFirmwareCancelled(cancelToken);
      _firmwareUpdateState = FirmwareUpdateState.uploading;
      await _uploadFirmwareBytes(fwImage, onProgress, cancelToken);

      _throwIfFirmwareCancelled(cancelToken);
      _firmwareUpdateState = FirmwareUpdateState.verifying;
      late Future<FWMapRequestData> verificationResponse;
      await _writeFirmwareMap(
        coordinator: coordinator,
        firmwareMapSequence: () => firmwareMapSequence,
        cancelToken: cancelToken,
        firmwareToErase: 0,
        predicate: _isTerminalVerificationResponse,
        onResponseArmed: (response) => verificationResponse = response,
      );
      final verification = await _waitForFirmwareResponse(
        verificationResponse,
        cancelToken,
        firmwareVerificationTimeout,
        'Timed out waiting for firmware verification',
        _isTerminalVerificationResponse,
      );
      if (!_isSuccessfulFirmwareVerification(verification)) {
        throw StateError(
          'Firmware verification failed at 0x'
          '${verification.error.map((value) => value.toRadixString(16).padLeft(2, '0')).join()}',
        );
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _writeFirmwareMap({
    required _FirmwareResponseCoordinator coordinator,
    required int Function() firmwareMapSequence,
    required _FirmwareCancellationToken cancelToken,
    required int firmwareToErase,
    required bool Function(FWMapRequestData response) predicate,
    required void Function(Future<FWMapRequestData> response) onResponseArmed,
  }) {
    return _transport.writeWithResponse(
      Endpoint.fwMapRequest,
      FWMapRequestData(
        windowIncrement: 0,
        firmwareToErase: firmwareToErase,
        firmwareToMap: 1,
        error: Uint8List.fromList([0xff, 0xff, 0xff]),
      ).asData().buffer.asUint8List(),
      beforeDispatch: () {
        _throwIfFirmwareCancelled(cancelToken);
        onResponseArmed(
          coordinator.waitFor(
            minimumSequence: firmwareMapSequence() + 1,
            predicate: predicate,
          ),
        );
      },
    );
  }

  /// Await the terminal firmware-map response for a stage (erase or verify).
  ///
  /// Races the existing NOTIFY future against a POLL loop. Firmware that pushes
  /// the terminal `[I]`/A009 notification completes [response] through the
  /// untouched notify path; firmware that never emits that post-erase /
  /// post-verify notify is served instead by [_pollFirmwareResponse], which
  /// actively reads `fwMapRequest` until [predicate] matches. Whichever
  /// produces a matching terminal response first wins. Both branches, plus
  /// cancellation, are bounded by the single [timeout], so firmware that does
  /// notify completes exactly as before.
  Future<FWMapRequestData> _waitForFirmwareResponse(
    Future<FWMapRequestData> response,
    _FirmwareCancellationToken cancelToken,
    Duration timeout,
    String timeoutMessage,
    bool Function(FWMapRequestData response) predicate,
  ) async {
    final stop = Completer<void>();
    try {
      // Attaching each future to Future.any marks it handled, so a losing
      // branch that errors or never completes later raises no unhandled async
      // error.
      return await Future.any([
        response,
        cancelToken.cancelled.then<FWMapRequestData>(
          (_) => throw const FirmwareUpdateCancelledException(),
        ),
        _pollFirmwareResponse(predicate, cancelToken, stop.future),
      ]).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(timeoutMessage),
      );
    } finally {
      // Whichever branch won, stop the poll loop so it issues no further reads.
      if (!stop.isCompleted) stop.complete();
    }
  }

  /// Poll `fwMapRequest` every [_firmwareMapPollInterval] until [predicate]
  /// matches, [stop] fires (notify won or the outer timeout elapsed), or the
  /// update is cancelled. On a match returns the response; otherwise resolves
  /// to a never-completing future so, as a losing Future.any branch, it
  /// produces no late result once another branch has won.
  Future<FWMapRequestData> _pollFirmwareResponse(
    bool Function(FWMapRequestData response) predicate,
    _FirmwareCancellationToken cancelToken,
    Future<void> stop,
  ) async {
    var stopped = false;
    unawaited(stop.then((_) => stopped = true));
    while (!stopped && !cancelToken.isCancelled) {
      try {
        final data = await _transport.readFwMapRequestFresh();
        if (stopped || cancelToken.isCancelled) break;
        final response = FWMapRequestData.from(data);
        if (predicate(response)) return response;
      } catch (e) {
        // A read failure (short frame, transient GATT error) is expected on
        // some cycles - log it and keep polling.
        _log.fine('firmware map poll read failed: $e');
      }
      await Future.any<void>([
        Future<void>.delayed(_firmwareMapPollInterval),
        stop,
        cancelToken.cancelled,
      ]);
    }
    return Completer<FWMapRequestData>().future;
  }

  bool _isEraseComplete(FWMapRequestData response) {
    return response.windowIncrement == 0 &&
        response.firmwareToErase == 0 &&
        response.firmwareToMap == 1 &&
        _hasFirmwareError(response, const [0xff, 0xff, 0xff]);
  }

  bool _isTerminalVerificationResponse(FWMapRequestData response) {
    return response.windowIncrement == 0 &&
        response.firmwareToErase == 0 &&
        response.firmwareToMap == 1 &&
        !_hasFirmwareError(response, const [0xff, 0xff, 0xff]);
  }

  bool _isSuccessfulFirmwareVerification(FWMapRequestData response) {
    return _hasFirmwareError(response, const [0xff, 0xff, 0xfd]);
  }

  bool _hasFirmwareError(FWMapRequestData response, List<int> expected) {
    return response.error.length == expected.length &&
        Iterable<int>.generate(
          expected.length,
        ).every((index) => response.error[index] == expected[index]);
  }

  void _throwIfFirmwareCancelled(_FirmwareCancellationToken token) {
    if (token.isCancelled) {
      throw const FirmwareUpdateCancelledException();
    }
  }

  Future<void> _waitFirmwarePacing(
    Duration duration,
    _FirmwareCancellationToken token,
  ) async {
    if (duration == Duration.zero) return;
    await Future.any([
      Future<void>.delayed(duration),
      token.cancelled.then<void>(
        (_) => throw const FirmwareUpdateCancelledException(),
      ),
    ]);
  }

  Future<void> _uploadFirmwareBytes(
    Uint8List list,
    void Function(double) onProgress,
    _FirmwareCancellationToken cancelToken,
  ) async {
    final total = list.length;
    var chunkNum = 0;
    final batchSize = firmwareUploadBatchSize;
    final batchPause = firmwareUploadBatchPause;
    for (var offset = 0; offset < list.length; offset += 16) {
      _throwIfFirmwareCancelled(cancelToken);
      final chunkLength = min(16, list.length - offset);
      final data = Uint8List(4 + chunkLength);
      final address = encodeU24P0(offset);
      data[0] = chunkLength;
      data[1] = address[0];
      data[2] = address[1];
      data[3] = address[2];
      data.setRange(4, 4 + chunkLength, list, offset);

      await _transport.writeWithResponse(Endpoint.writeToMMR, data);
      _throwIfFirmwareCancelled(cancelToken);
      chunkNum++;
      if (batchPause > Duration.zero && chunkNum % batchSize == 0) {
        await _waitFirmwarePacing(batchPause, cancelToken);
      }
      onProgress(min((offset + chunkLength) / total, 1.0));
    }
  }
}

final class _FirmwareResponseCoordinator {
  _FirmwareResponseWaiter? _waiter;

  Future<FWMapRequestData> waitFor({
    required int minimumSequence,
    required bool Function(FWMapRequestData response) predicate,
  }) {
    final waiter = _FirmwareResponseWaiter(
      minimumSequence: minimumSequence,
      predicate: predicate,
    );
    _waiter = waiter;
    return waiter.completer.future;
  }

  void handle(int sequence, FWMapRequestData response) {
    final waiter = _waiter;
    if (waiter == null ||
        waiter.completer.isCompleted ||
        sequence < waiter.minimumSequence ||
        !waiter.predicate(response)) {
      return;
    }
    waiter.completer.complete(response);
  }
}

final class _FirmwareResponseWaiter {
  _FirmwareResponseWaiter({
    required this.minimumSequence,
    required this.predicate,
  });

  final int minimumSequence;
  final bool Function(FWMapRequestData response) predicate;
  final Completer<FWMapRequestData> completer = Completer<FWMapRequestData>();
}
