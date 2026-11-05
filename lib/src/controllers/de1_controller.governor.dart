part of 'de1_controller.dart';

enum De1ReplayPolicy { never, sameMachine }

final class _FirmwareDiagnosticContext {
  _FirmwareDiagnosticContext() : stopwatch = Stopwatch()..start();

  final Stopwatch stopwatch;
}

final class _PendingDe1Write<T> {
  const _PendingDe1Write({
    required this.call,
    required this.completer,
    required this.targetMachineIdentity,
    required this.connectionGeneration,
    required this.replayPolicy,
    this.coalescingKey,
    this.firmwareDiagnostic,
  });

  final Future<T> Function(De1Interface device) call;
  final Completer<T> completer;
  final String targetMachineIdentity;
  final int connectionGeneration;
  final De1ReplayPolicy replayPolicy;
  final String? coalescingKey;
  final _FirmwareDiagnosticContext? firmwareDiagnostic;
}

extension De1Governor on De1Controller {
  void _ensureReplaceableDeviceWriteCapacity(Iterable<String> keys) {
    final pendingKeys = _pendingDeviceWrites
        .map((pending) => pending.coalescingKey)
        .whereType<String>()
        .toSet();
    final requiredSlots = keys.toSet().difference(pendingKeys).length;
    final availableSlots =
        maxPendingDeviceWrites -
        _pendingDeviceWrites.length +
        (_activeDeviceWrite == null ? 1 : 0);
    if (requiredSlots > availableSlots) {
      throw De1WriteQueueFullException(maxPendingDeviceWrites);
    }
  }

  Future<T> _enqueueDeviceWrite<T>(
    Future<T> Function(De1Interface device) write, {
    required De1ReplayPolicy replayPolicy,
    String? coalescingKey,
    bool firmwareDiagnostic = false,
  }) {
    connectedDe1();
    final completer = Completer<T>();
    final operation = _PendingDe1Write<T>(
      call: write,
      completer: completer,
      targetMachineIdentity: _connectionMachineIdentity,
      connectionGeneration: _connectionGeneration,
      replayPolicy: replayPolicy,
      coalescingKey: coalescingKey,
      firmwareDiagnostic: firmwareDiagnostic
          ? _FirmwareDiagnosticContext()
          : null,
    );

    if (coalescingKey != null) {
      _PendingDe1Write<dynamic>? replaced;
      final updated = _pendingDeviceWrites
          .map((pending) {
            if (replaced == null && pending.coalescingKey == coalescingKey) {
              replaced = pending;
              return operation;
            }
            return pending;
          })
          .toList(growable: false);
      if (replaced != null) {
        _pendingDeviceWrites
          ..clear()
          ..addAll(updated);
        replaced!.completer.completeError(
          De1WriteSupersededException(coalescingKey),
        );
        return completer.future;
      }
    }

    if (_activeDeviceWrite != null &&
        _pendingDeviceWrites.length >= maxPendingDeviceWrites) {
      completer.completeError(
        De1WriteQueueFullException(maxPendingDeviceWrites),
      );
      return completer.future;
    }

    if (_activeDeviceWrite == null) {
      _activeDeviceWrite = operation;
      unawaited(_executeActiveDeviceWrite());
    } else {
      _pendingDeviceWrites.addLast(operation);
    }
    return completer.future;
  }

  Future<void> _executeActiveDeviceWrite() async {
    final operation = _activeDeviceWrite;
    if (operation == null) return;
    try {
      operation.completer.complete(await _runDeviceWrite(operation));
    } catch (error, stackTrace) {
      operation.completer.completeError(error, stackTrace);
    } finally {
      _activeDeviceWrite = _pendingDeviceWrites.isEmpty
          ? null
          : _pendingDeviceWrites.removeFirst();
      if (_activeDeviceWrite != null) {
        unawaited(_executeActiveDeviceWrite());
      }
    }
  }

  Future<dynamic> _runDeviceWrite(_PendingDe1Write<dynamic> operation) async {
    final attempts = operation.replayPolicy == De1ReplayPolicy.sameMachine
        ? 2
        : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final _FirmwareDiagnosticContext? diagnostic =
          operation.firmwareDiagnostic;
      final De1Interface device;
      try {
        device = await _resolveDeviceFor(operation);
      } catch (error, stackTrace) {
        if (diagnostic == null) rethrow;
        Error.throwWithStackTrace(
          FirmwareUpdateStageException(
            stage: 'controller',
            cause: error,
            stackTrace: stackTrace,
          ),
          stackTrace,
        );
      }
      final generation = _connectionGeneration;
      if (diagnostic != null) {
        _log.fine(
          'firmware stage=initialization start '
          'generation=$generation '
          'elapsed=${diagnostic.stopwatch.elapsedMilliseconds}ms',
        );
      }
      try {
        try {
          await _waitForInitialization(device, generation);
        } on TimeoutException catch (error, stackTrace) {
          if (diagnostic == null) rethrow;
          _log.warning(
            'firmware stage=initialization failed '
            'generation=$generation '
            'elapsed=${diagnostic.stopwatch.elapsedMilliseconds}ms '
            'cause=$error',
            error,
            stackTrace,
          );
          Error.throwWithStackTrace(
            FirmwareUpdateStageException(
              stage: 'initialization',
              cause: error,
              stackTrace: stackTrace,
            ),
            stackTrace,
          );
        }
        if (generation != _connectionGeneration ||
            !identical(device, connectedDe1OrNull)) {
          if (attempt + 1 < attempts) continue;
          final error = StateError('Machine changed during device write');
          if (diagnostic != null) {
            final stackTrace = StackTrace.current;
            Error.throwWithStackTrace(
              FirmwareUpdateStageException(
                stage: 'controller',
                cause: error,
                stackTrace: stackTrace,
              ),
              stackTrace,
            );
          }
          break;
        }
        if (diagnostic != null) {
          _log.fine(
            'firmware stage=initialization settled '
            'generation=$generation '
            'elapsed=${diagnostic.stopwatch.elapsedMilliseconds}ms',
          );
        }
        final result = await operation.call(device);
        if (generation == _connectionGeneration &&
            identical(device, connectedDe1OrNull)) {
          return result;
        }
      } catch (_) {
        if (operation.replayPolicy == De1ReplayPolicy.never ||
            attempt + 1 == attempts ||
            (generation == _connectionGeneration &&
                identical(device, connectedDe1OrNull))) {
          rethrow;
        }
      }
    }
    throw StateError('Machine changed during device write');
  }

  Future<De1Interface> _resolveDeviceFor(
    _PendingDe1Write<dynamic> operation,
  ) async {
    if (operation.replayPolicy == De1ReplayPolicy.never &&
        operation.connectionGeneration != _connectionGeneration) {
      throw StateError('Machine changed before device write');
    }

    var device = connectedDe1OrNull;
    if (device == null) {
      if (operation.replayPolicy == De1ReplayPolicy.never) {
        throw const DeviceNotConnectedException.machine();
      }
      device = await _waitForMachineReplacement(machineReplacementTimeout);
      if (device == null) {
        throw MachineReplacementTimeoutException(machineReplacementTimeout);
      }
    }
    if (_connectionMachineIdentity != operation.targetMachineIdentity) {
      throw StateError('Machine changed before device write');
    }
    return device;
  }

  String _machineIdentity(De1Interface device) {
    try {
      final serial = device.machineInfo.serialNumber.trim();
      if (serial.isNotEmpty && serial != '0') return 'serial:$serial';
    } catch (_) {}
    return 'device:${device.deviceId}';
  }

  Future<De1Interface?> _waitForMachineReplacement(Duration timeout) async {
    try {
      return await _de1Controller.stream
          .firstWhere((de1) => de1 != null)
          .timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _waitForInitialization(
    De1Interface device,
    int generation,
  ) async {
    if (_initSettledSubject.valueOrNull == generation) return;
    await _initSettledSubject.stream
        .firstWhere(
          (settled) =>
              settled == generation ||
              generation != _connectionGeneration ||
              !identical(device, connectedDe1OrNull),
        )
        .timeout(ConnectionTimings.initialShotSettingsTimeout);
  }
}
