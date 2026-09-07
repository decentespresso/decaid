import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:uuid/uuid.dart';

import 'plugin_ble_matcher.dart';

enum PluginBleSessionState {
  connecting,
  initializing,
  ready,
  retiring,
  revoked,
  closed,
}

class PluginBleException implements Exception {
  final String code;
  final String message;
  const PluginBleException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

class _BleSubscription {
  final String id = const Uuid().v4();
  final String service;
  final String characteristic;
  final Completer<void> settled = Completer<void>();
  Future<void>? removing;
  _BleSubscription(this.service, this.characteristic);
}

class PluginBleSession {
  final String id = const Uuid().v4();
  final BLETransport transport;
  final bool Function() authorized;
  final bool Function() runtimeAlive;
  final Future<void> Function(Map<String, dynamic>)? eventSink;
  final Duration cleanupTimeout;
  final int maxPendingOperations;
  final int maxSubscriptions;
  final int maxQueuedEvents;
  final int maxQueuedBytes;
  final void Function(void Function()) schedule;
  final Logger _log = Logger('PluginBleSession');
  final Map<(String, String), _BleSubscription> _subscriptions = {};
  final Set<Completer<Object?>> _pending = {};
  final Queue<(Map<String, dynamic>, int)> _notifications = Queue();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _cleanupInterrupted = Completer<void>();
  StreamSubscription<ConnectionState>? _connectionSubscription;
  Completer<void>? _retirement;
  String? _cleanupAuthority;
  PluginBleSessionState _state = PluginBleSessionState.connecting;
  bool _linkLost = false;
  bool _draining = false;
  int _queuedBytes = 0;

  PluginBleSession({
    required this.transport,
    required this.authorized,
    required this.runtimeAlive,
    this.eventSink,
    this.cleanupTimeout = const Duration(seconds: 5),
    this.maxPendingOperations = 16,
    this.maxSubscriptions = 8,
    this.maxQueuedEvents = 256,
    this.maxQueuedBytes = 64 * 1024,
    this.schedule = scheduleMicrotask,
  });

  PluginBleSessionState get state => _state;
  Future<void> get closed => _closed.future;
  int get subscriptionCount => _subscriptions.length;
  int get pendingOperationCount => _pending.length;
  int get queuedEventCount => _notifications.length;
  bool get acceptsPublications =>
      authorized() &&
      runtimeAlive() &&
      (_state == PluginBleSessionState.initializing ||
          _state == PluginBleSessionState.ready);

  Future<void> connect() async {
    if (!authorized() || !runtimeAlive() || _retirement != null) {
      throw const PluginBleException(
        'permission_denied',
        'BLE session is not authorized',
      );
    }
    _connectionSubscription = transport.connectionState.listen((state) {
      if (state == ConnectionState.disconnected) {
        _linkLost = true;
        revoke();
      }
    });
    try {
      await transport.connect();
      if (_retirement != null || !authorized() || !runtimeAlive()) {
        throw const PluginBleException('stale_session', 'BLE connect retired');
      }
      _state = PluginBleSessionState.initializing;
    } catch (_) {
      await retire();
      rethrow;
    }
  }

  void markReady() {
    if (!acceptsPublications || _state != PluginBleSessionState.initializing) {
      throw const PluginBleException(
        'stale_session',
        'BLE initialization retired',
      );
    }
    _state = PluginBleSessionState.ready;
  }

  void _checkAuthority(String authority, String operation) {
    if (!authorized() || !runtimeAlive()) {
      revoke();
      throw const PluginBleException(
        'permission_denied',
        'BLE permission or runtime revoked',
      );
    }
    final normal = authority == id && acceptsPublications;
    final cleanup =
        authority == _cleanupAuthority &&
        _state == PluginBleSessionState.retiring &&
        !_linkLost &&
        const {'discoverServices', 'read', 'write'}.contains(operation);
    if (!normal && !cleanup) {
      throw const PluginBleException(
        'stale_session',
        'Stale or foreign BLE authority',
      );
    }
  }

  Future<Object?> call(
    String authority,
    String operation,
    Map<String, dynamic> args,
  ) async {
    _checkAuthority(authority, operation);
    if (_pending.length >= maxPendingOperations) {
      throw const PluginBleException(
        'resource_limit',
        'Pending GATT operation limit reached',
      );
    }
    final result = Completer<Object?>();
    _pending.add(result);
    unawaited(() async {
      try {
        final value = await _dispatch(authority, operation, args);
        _checkAuthority(authority, operation);
        if (!result.isCompleted) result.complete(value);
      } catch (error, stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
        if (error is TimeoutException) revoke();
      } finally {
        _pending.remove(result);
      }
    }());
    return result.future;
  }

  Future<Object?> _dispatch(
    String authority,
    String operation,
    Map<String, dynamic> args,
  ) async {
    if (operation == 'discoverServices') {
      return (await transport.discoverServices())
          .map(normalizePluginBleUuid)
          .toList();
    }
    if (operation == 'unsubscribe') {
      final subscriptionId = args['subscription'];
      if (subscriptionId is! String) {
        throw const PluginBleException(
          'invalid_argument',
          'Invalid subscription ID',
        );
      }
      for (final entry in _subscriptions.entries.toList()) {
        if (entry.value.id != subscriptionId) continue;
        final existingRemoval = entry.value.removing;
        if (existingRemoval != null) {
          await existingRemoval;
          return null;
        }
        final removal = Completer<void>();
        entry.value.removing = removal.future;
        try {
          await entry.value.settled.future;
          _checkAuthority(authority, operation);
          await transport.unsubscribe(entry.key.$1, entry.key.$2);
        } finally {
          if (identical(_subscriptions[entry.key], entry.value)) {
            _subscriptions.remove(entry.key);
          }
          removal.complete();
        }
        return null;
      }
      return null;
    }
    final service = _uuid(args['service']);
    final characteristic = _uuid(args['characteristic']);
    switch (operation) {
      case 'read':
        final bytes = await transport.read(service, characteristic);
        if (bytes.length > 16 * 1024) {
          throw const PluginBleException(
            'resource_limit',
            'Read exceeds 16 KiB',
          );
        }
        return base64Encode(bytes);
      case 'write':
        final encoded = args['data'];
        if (encoded is! String) {
          throw const PluginBleException(
            'invalid_argument',
            'Write requires base64',
          );
        }
        if (encoded.length > ((16 * 1024 + 2) ~/ 3) * 4) {
          throw const PluginBleException(
            'resource_limit',
            'Write exceeds 16 KiB',
          );
        }
        final Uint8List bytes;
        try {
          bytes = base64Decode(encoded);
        } on FormatException {
          throw const PluginBleException('invalid_argument', 'Invalid base64');
        }
        if (bytes.length > 16 * 1024) {
          throw const PluginBleException(
            'resource_limit',
            'Write exceeds 16 KiB',
          );
        }
        final withResponse = args['withResponse'] ?? true;
        if (withResponse is! bool) {
          throw const PluginBleException(
            'invalid_argument',
            'Invalid write acknowledgement',
          );
        }
        await transport.write(
          service,
          characteristic,
          bytes,
          withResponse: withResponse,
        );
        return null;
      case 'subscribe':
        final key = (service, characteristic);
        final previous = _subscriptions[key];
        if (previous == null && _subscriptions.length >= maxSubscriptions) {
          throw const PluginBleException(
            'resource_limit',
            'Subscription limit reached',
          );
        }
        final subscription = _BleSubscription(service, characteristic);
        _subscriptions[key] = subscription;
        try {
          if (previous != null) {
            await previous.settled.future;
            await previous.removing;
          }
          _checkAuthority(authority, operation);
          if (!identical(_subscriptions[key], subscription)) {
            throw const PluginBleException(
              'operation_cancelled',
              'Subscription replaced',
            );
          }
          final subscribe = previous == null
              ? transport.subscribe
              : transport.resetSubscription;
          await subscribe(service, characteristic, (bytes) {
            final current = _subscriptions[key];
            if (current == null ||
                current.removing != null ||
                !acceptsPublications) {
              return;
            }
            _enqueue(current.id, bytes);
          });
          return subscription.id;
        } catch (_) {
          if (identical(_subscriptions[key], subscription)) {
            _subscriptions.remove(key);
          }
          rethrow;
        } finally {
          subscription.settled.complete();
        }
      default:
        throw const PluginBleException(
          'invalid_argument',
          'Unknown GATT operation',
        );
    }
  }

  String _uuid(Object? value) {
    if (value is! String) {
      throw const PluginBleException(
        'invalid_argument',
        'UUID must be a string',
      );
    }
    try {
      return normalizePluginBleUuid(value);
    } on FormatException {
      throw const PluginBleException('invalid_argument', 'Invalid BLE UUID');
    }
  }

  void _enqueue(String subscription, Uint8List bytes) {
    if (_notifications.length >= maxQueuedEvents ||
        _queuedBytes + bytes.length > maxQueuedBytes) {
      _log.warning(
        'BLE notification overflow session=$id device=${transport.id}',
      );
      revoke();
      return;
    }
    _notifications.add((
      {
        'type': 'notification',
        'session': id,
        'subscription': subscription,
        'data': base64Encode(bytes),
      },
      bytes.length,
    ));
    _queuedBytes += bytes.length;
    if (_draining) return;
    _draining = true;
    schedule(() => unawaited(_drain()));
  }

  Future<void> _drain() async {
    try {
      while (_notifications.isNotEmpty && acceptsPublications) {
        final event = _notifications.first;
        await eventSink?.call(event.$1);
        if (_notifications.isEmpty) break;
        _notifications.removeFirst();
        _queuedBytes -= event.$2;
      }
    } catch (error) {
      _log.warning('BLE notification dispatch failed session=$id', error);
      revoke();
    } finally {
      _draining = false;
    }
  }

  void revoke() {
    _cleanupAuthority = null;
    if (!_cleanupInterrupted.isCompleted) _cleanupInterrupted.complete();
    unawaited(retire());
  }

  Future<void> retire({Future<void> Function(String)? cleanup}) {
    final existing = _retirement;
    if (existing != null) return existing.future;
    final retirement = Completer<void>();
    _retirement = retirement;
    final initialized =
        _state == PluginBleSessionState.initializing ||
        _state == PluginBleSessionState.ready;
    _state = PluginBleSessionState.retiring;
    _notifications.clear();
    _queuedBytes = 0;
    _rejectPending();
    unawaited(
      _retire(
        initialized ? cleanup : null,
      ).then(retirement.complete, onError: retirement.completeError),
    );
    return retirement.future;
  }

  Future<void> _retire(Future<void> Function(String)? cleanup) async {
    if (cleanup != null &&
        !_linkLost &&
        authorized() &&
        runtimeAlive() &&
        !_cleanupInterrupted.isCompleted) {
      final authority = const Uuid().v4();
      _cleanupAuthority = authority;
      try {
        await Future.any([
          Future.sync(() => cleanup(authority)),
          _cleanupInterrupted.future,
        ]).timeout(cleanupTimeout);
      } catch (error) {
        _log.warning(
          'BLE protocol cleanup failed session=$id device=${transport.id}',
          error,
        );
      }
    }
    _cleanupAuthority = null;
    _state = PluginBleSessionState.revoked;
    _rejectPending();
    _subscriptions.clear();
    if (runtimeAlive()) {
      try {
        await eventSink
            ?.call({'type': 'disconnect', 'session': id})
            .timeout(cleanupTimeout);
      } catch (error) {
        _log.warning('BLE terminal callback failed session=$id', error);
      }
    }
    unawaited(_teardown());
  }

  void _rejectPending() {
    for (final result in _pending) {
      if (!result.isCompleted) {
        result.completeError(
          const PluginBleException('stale_session', 'BLE session retired'),
        );
      }
    }
  }

  Future<void> _teardown() async {
    try {
      await transport.disconnectConfirmed();
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      await transport.dispose();
      _state = PluginBleSessionState.closed;
      _closed.complete();
    } catch (error, stackTrace) {
      _log.severe(
        'BLE ownership retained after teardown failure session=$id device=${transport.id}',
        error,
        stackTrace,
      );
    }
  }
}
