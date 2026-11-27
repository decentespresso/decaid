import 'dart:async';

import 'package:logging/logging.dart';

class StorageOperationLimits {
  const StorageOperationLimits({
    this.operationTimeout = const Duration(seconds: 5),
    this.drainTimeout = const Duration(seconds: 5),
    this.maxOutstandingPerNamespace = 32,
  });

  final Duration operationTimeout;
  final Duration drainTimeout;
  final int maxOutstandingPerNamespace;
}

enum StorageErrorCode {
  invalidCommand('invalid_command', 'The storage command is invalid.'),
  capacity('capacity', 'Too many storage operations are outstanding.'),
  quarantined(
    'quarantined',
    'An earlier write to this key has not settled; retry later.',
  ),
  maintenance('maintenance', 'Storage is under maintenance; retry later.'),
  timeout('timeout', 'The storage operation did not complete in time.'),
  writeIndeterminate(
    'write_indeterminate',
    'The write did not settle in time; its outcome is unknown.',
  ),
  storageError('storage_error', 'The storage operation failed.'),
  unresolvedWrites('unresolved_writes', 'Storage has unresolved writes.');

  const StorageErrorCode(this.wireName, this.message);

  final String wireName;
  final String message;

  Map<String, String> toJson() => {'code': wireName, 'message': message};
}

class StorageOperationException implements Exception {
  const StorageOperationException(this.code);

  final StorageErrorCode code;

  @override
  String toString() => 'StorageOperationException(${code.wireName})';
}

class StorageOperationCoordinator {
  StorageOperationCoordinator({this.limits = const StorageOperationLimits()});

  static final _log = Logger('StorageOperationCoordinator');

  final StorageOperationLimits limits;
  final Map<String, int> _outstanding = {};
  final Map<String, Set<Future<void>>> _pendingWrites = {};
  final Map<(String, String), Future<void>> _writeTails = {};
  final Set<(String, String)> _quarantined = {};
  final Set<String> _guarded = {};

  static String _namespace(String namespace) => namespace.toLowerCase();

  int outstanding(String namespace) => _outstanding[_namespace(namespace)] ?? 0;

  bool isQuarantined(String namespace, String key) =>
      _quarantined.contains((_namespace(namespace), key));

  Future<Object?> read(
    String namespace,
    String key,
    Future<Object?> Function() backend,
  ) {
    final ns = _namespace(namespace);
    final rejection = _admissionError(ns);
    if (rejection != null) {
      return Future.error(StorageOperationException(rejection));
    }
    _acquire(ns);
    final operation = Future.sync(backend);
    unawaited(_settled(operation).whenComplete(() => _release(ns)));
    return _bounded(operation, () => StorageErrorCode.timeout);
  }

  Future<void> write(
    String namespace,
    String key,
    Future<void> Function() backend,
  ) {
    final ns = _namespace(namespace);
    final slot = (ns, key);
    final rejection =
        _admissionError(ns) ??
        (_quarantined.contains(slot) ? StorageErrorCode.quarantined : null);
    if (rejection != null) {
      return Future.error(StorageOperationException(rejection));
    }

    final previous = _writeTails[slot];
    var started = false;
    var abandoned = false;
    var quarantinedByThisWrite = false;
    Future<void> run() async {
      if (previous != null) await previous;
      if (abandoned) return;
      started = true;
      await backend();
    }

    final operation = run();
    final settled = _settled(operation);
    _writeTails[slot] = settled;
    final writes = _pendingWrites.putIfAbsent(ns, () => {})..add(settled);
    _acquire(ns);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _release(ns);
      writes.remove(settled);
      if (writes.isEmpty && identical(_pendingWrites[ns], writes)) {
        _pendingWrites.remove(ns);
      }
    }

    unawaited(
      settled.whenComplete(() {
        if (identical(_writeTails[slot], settled)) _writeTails.remove(slot);
        if (quarantinedByThisWrite) _quarantined.remove(slot);
        release();
      }),
    );

    return _bounded(operation, () {
      if (!started) {
        abandoned = true;
        release();
        return StorageErrorCode.timeout;
      }
      quarantinedByThisWrite = true;
      _quarantined.add(slot);
      return StorageErrorCode.writeIndeterminate;
    });
  }

  Future<T> runMaintenance<T>(
    Set<String> namespaces,
    Future<T> Function() action,
  ) async {
    final guarded = namespaces.map(_namespace).toSet();
    if (guarded.any(_guarded.contains)) {
      throw const StorageOperationException(StorageErrorCode.maintenance);
    }
    _guarded.addAll(guarded);
    try {
      final writes = [
        for (final namespace in guarded) ...?_pendingWrites[namespace],
      ];
      await Future.wait(writes).timeout(
        limits.drainTimeout,
        onTimeout: () => throw const StorageOperationException(
          StorageErrorCode.unresolvedWrites,
        ),
      );
      return await action();
    } finally {
      _guarded.removeAll(guarded);
    }
  }

  StorageErrorCode? _admissionError(String namespace) {
    if (_guarded.contains(namespace)) return StorageErrorCode.maintenance;
    if ((_outstanding[namespace] ?? 0) >= limits.maxOutstandingPerNamespace) {
      return StorageErrorCode.capacity;
    }
    return null;
  }

  void _acquire(String namespace) =>
      _outstanding.update(namespace, (n) => n + 1, ifAbsent: () => 1);

  void _release(String namespace) {
    final remaining = _outstanding[namespace]! - 1;
    if (remaining == 0) {
      _outstanding.remove(namespace);
    } else {
      _outstanding[namespace] = remaining;
    }
  }

  static Future<void> _settled(Future<Object?> operation) =>
      operation.then((_) {}, onError: (Object _) {});

  Future<T> _bounded<T>(
    Future<T> operation,
    StorageErrorCode Function() onTimeout,
  ) {
    final result = Completer<T>();
    final timer = Timer(limits.operationTimeout, () {
      if (!result.isCompleted) {
        result.completeError(StorageOperationException(onTimeout()));
      }
    });
    operation.then(
      (value) {
        timer.cancel();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error) {
        timer.cancel();
        _log.warning('Storage backend failed: ${error.runtimeType}');
        if (!result.isCompleted) {
          result.completeError(
            const StorageOperationException(StorageErrorCode.storageError),
          );
        }
      },
    );
    return result.future;
  }
}
