part of 'unified_de1.dart';

const _firmwareMapPollInterval = Duration(milliseconds: 250);

extension UnifiedDe1Firmware on UnifiedDe1 {
  Future<void> _updateFirmware(
    Uint8List fwImage,
    void Function(double) onProgress,
    _FirmwareCancellationToken cancelToken,
  ) async {
    try {
      await _updateFirmwareBody(fwImage, onProgress, cancelToken);
      _log.info('firmware terminal outcome=success');
    } catch (error, stackTrace) {
      final outcome = error is FirmwareUpdateCancelledException
          ? 'cancelled'
          : 'failure';
      _log.info('firmware terminal outcome=$outcome cause=$error');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _updateFirmwareBody(
    Uint8List fwImage,
    void Function(double) onProgress,
    _FirmwareCancellationToken cancelToken,
  ) async {
    _throwIfFirmwareCancelled(cancelToken);
    late final De1FirmwareImageClassification imageClassification;
    try {
      imageClassification = De1FirmwareHeader.validateUpload(fwImage);
    } on FormatException catch (error, stackTrace) {
      _log.warning(
        'firmware stage=validation failed cause=$error',
        error,
        stackTrace,
      );
      rethrow;
    }
    final classification = switch (imageClassification) {
      De1FirmwareImageClassification.canonicalDe1 => 'canonical-de1',
      De1FirmwareImageClassification.unrecognizedAtLeastHeader =>
        'unrecognized-at-least-header',
      De1FirmwareImageClassification.unrecognizedShort => 'unrecognized-short',
    };
    final log =
        'firmware image classification=$classification '
        'byteLength=${fwImage.length} sha256=${sha256.convert(fwImage)}';
    _log.info(log);
    if (imageClassification != De1FirmwareImageClassification.canonicalDe1) {
      _log.warning(
        'firmware image format validation skipped '
        'classification=$classification byteLength=${fwImage.length}',
      );
    }
    await _runFirmwareStage('sleep', () => requestState(MachineState.sleeping));
    _throwIfFirmwareCancelled(cancelToken);
    await _runFirmwareStage('preflight', beforeFirmwareUpload);
    _throwIfFirmwareCancelled(cancelToken);

    final gateStopwatch = Stopwatch()..start();
    _log.fine('firmware stage=firmware-gate waiting elapsed=0ms');
    await _firmwareMmrGate.runFirmwareExclusive(() async {
      _log.fine(
        'firmware stage=firmware-gate acquired '
        'elapsed=${gateStopwatch.elapsedMilliseconds}ms',
      );
      _throwIfFirmwareCancelled(cancelToken);
      await _updateFirmwareExclusive(fwImage, onProgress, cancelToken);
    });
  }

  Future<void> _runFirmwareStage(
    String stage,
    Future<void> Function() operation,
  ) async {
    final stopwatch = Stopwatch()..start();
    _log.info('firmware stage=$stage start elapsed=0ms');
    try {
      final result = await operation();
      _log.info(
        'firmware stage=$stage complete '
        'elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
      return result;
    } catch (error, stackTrace) {
      if (error is FirmwareUpdateCancelledException) rethrow;
      _log.warning(
        'firmware stage=$stage failed '
        'elapsed=${stopwatch.elapsedMilliseconds}ms cause=$error',
        error,
        stackTrace,
      );
      if (error is FirmwareUpdateStageException) rethrow;
      Error.throwWithStackTrace(
        FirmwareUpdateStageException(
          stage: stage,
          cause: error,
          stackTrace: stackTrace,
        ),
        stackTrace,
      );
    }
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
      _log.info('firmware stage=erase start');
      try {
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
        _log.info('firmware stage=erase complete');
      } catch (error, stackTrace) {
        if (error is! FirmwareUpdateCancelledException) {
          _log.warning(
            'firmware stage=erase failed cause=$error',
            error,
            stackTrace,
          );
        }
        rethrow;
      }

      _throwIfFirmwareCancelled(cancelToken);
      _firmwareUpdateState = FirmwareUpdateState.uploading;
      _log.info('firmware stage=upload start');
      try {
        await _uploadFirmwareBytes(fwImage, onProgress, cancelToken);
        _log.info('firmware stage=upload complete');
      } catch (error, stackTrace) {
        if (error is! FirmwareUpdateCancelledException) {
          _log.warning(
            'firmware stage=upload failed cause=$error',
            error,
            stackTrace,
          );
        }
        rethrow;
      }

      _throwIfFirmwareCancelled(cancelToken);
      _firmwareUpdateState = FirmwareUpdateState.verifying;
      _log.info('firmware stage=verify start');
      try {
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
        _log.info('firmware stage=verify complete');
      } catch (error, stackTrace) {
        if (error is! FirmwareUpdateCancelledException) {
          _log.warning(
            'firmware stage=verify failed cause=$error',
            error,
            stackTrace,
          );
        }
        rethrow;
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
        error: Uint8List.fromList(
          firmwareToErase == 1 ? [0, 0, 0] : [0xff, 0xff, 0xff],
        ),
      ).asData().buffer.asUint8List(),
      retryOnTimeout: false,
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

  Future<FWMapRequestData> _waitForFirmwareResponse(
    Future<FWMapRequestData> response,
    _FirmwareCancellationToken cancelToken,
    Duration timeout,
    String timeoutMessage,
    bool Function(FWMapRequestData response) predicate,
  ) async {
    final stop = Completer<void>();
    try {
      // Future.any marks every branch handled, so a losing branch that errors
      // raises no unhandled async error.
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
      if (!stop.isCompleted) stop.complete();
    }
  }

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
      } on GattAttributeUnavailableException catch (error) {
        _log.info(
          'firmware map polling unavailable; using notifications: $error',
        );
        return Completer<FWMapRequestData>().future;
      } catch (e) {
        _log.fine('firmware map poll read failed: $e');
      }
      await Future.any<void>([
        Future<void>.delayed(_firmwareMapPollInterval),
        stop,
        cancelToken.cancelled,
      ]);
    }
    // A never-completing future: as a losing Future.any branch it must
    // produce no late result once another branch has won.
    return Completer<FWMapRequestData>().future;
  }

  bool _isEraseComplete(FWMapRequestData response) {
    return response.windowIncrement == 0 &&
        response.firmwareToErase == 0 &&
        response.firmwareToMap == 1 &&
        _hasFirmwareError(response, const [0, 0, 0]);
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
        Iterable<int>.generate(expected.length)
            .every((index) => response.error[index] == expected[index]);
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
    var loggedProgress = -1;
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

      await _transport.writeWithResponse(
        Endpoint.writeToMMR,
        data,
        retryOnTimeout: false,
      );
      _throwIfFirmwareCancelled(cancelToken);
      chunkNum++;
      if (batchPause > Duration.zero && chunkNum % batchSize == 0) {
        await _waitFirmwarePacing(batchPause, cancelToken);
      }
      final progress = min((offset + chunkLength) / total, 1.0);
      onProgress(progress);
      final progressBucket = (progress * 10).floor();
      if (progressBucket > loggedProgress) {
        loggedProgress = progressBucket;
        _log.info('firmware stage=upload progress=${progressBucket * 10}%');
      }
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
