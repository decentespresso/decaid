import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/ble/ble_exception_mapper.dart';
import 'package:reaprime/src/services/ble/ble_lifecycle_gate.dart';
import 'package:rxdart/subjects.dart';
import 'package:universal_ble/universal_ble.dart';

class UniversalBleTransport extends BLETransport {
  final BleDevice _device;

  late Logger _log;

  final BehaviorSubject<device.ConnectionState> _connectionStateSubject =
      BehaviorSubject.seeded(device.ConnectionState.discovered);

  StreamSubscription? _connectionStateSubscription;

  bool _linkDeadDeclared = false;
  int _connectionGeneration = 0;
  int? _maintenanceGeneration;
  bool _disposed = false;
  int? _recoveringQueueGeneration;
  Future<void>? _nativeDisconnectOperation;
  DateTime? _lastAdvertProbe;
  StreamSubscription<BleDevice>? _advertSub;

  static const Duration _linkProbeTimeout = Duration(seconds: 2);
  static const Duration _faultRecoveryPollInterval = Duration(milliseconds: 50);
  static const Duration _notificationResetSettle = Duration(milliseconds: 100);

  static const Duration _advertProbeThrottle = Duration(seconds: 5);

  bool get _isAndroid => _isAndroidOverride ?? Platform.isAndroid;
  bool get _isLinux => _isLinuxOverride ?? Platform.isLinux;

  UniversalBleTransport({
    required BleDevice device,
    Future<void> Function()? stopScan,
    bool requestLargeMtuNonAndroid = false,
    bool? isAndroidOverride,
    bool? isLinuxOverride,
    Duration faultRecoveryGrace = const Duration(seconds: 2),
    Duration faultRecoveryDisconnectTimeout = const Duration(seconds: 5),
    BleLifecycleGate? lifecycleGate,
    Duration bluezPostConnectDelay = const Duration(milliseconds: 500),
    Duration bluezScanSettleDelay = const Duration(seconds: 2),
    Duration bluezCacheRefreshScan = const Duration(seconds: 4),
  }) : _device = device,
       _stopScan = stopScan,
       _requestLargeMtuNonAndroid = requestLargeMtuNonAndroid,
       _isAndroidOverride = isAndroidOverride,
       _isLinuxOverride = isLinuxOverride,
       _faultRecoveryGrace = faultRecoveryGrace,
       _faultRecoveryDisconnectTimeout = faultRecoveryDisconnectTimeout,
       _lifecycleGate = lifecycleGate ?? BleLifecycleGate(),
       _bluezPostConnectDelay = bluezPostConnectDelay,
       _bluezScanSettleDelay = bluezScanSettleDelay,
       _bluezCacheRefreshScan = bluezCacheRefreshScan {
    _log = Logger("BLETransport-${device.deviceId}");
  }

  final Future<void> Function()? _stopScan;
  final bool _requestLargeMtuNonAndroid;
  final bool? _isAndroidOverride;
  final bool? _isLinuxOverride;
  final Duration _faultRecoveryGrace;
  final Duration _faultRecoveryDisconnectTimeout;
  final BleLifecycleGate _lifecycleGate;
  final Duration _bluezPostConnectDelay;
  final Duration _bluezScanSettleDelay;
  final Duration _bluezCacheRefreshScan;

  Future<void> _stopScanViaOwner() =>
      _stopScan?.call() ?? UniversalBle.stopScan();

  static const Duration _androidPostConnectDelay = Duration(milliseconds: 200);

  static const Duration _androidPreConnectSettleDelay = Duration(
    milliseconds: 300,
  );

  @override
  Future<void> connect() =>
      _lifecycleGate.run(_device.deviceId, _connectNative);

  Future<void> _connectNative() async {
    if (_disposed) throw StateError('BLE transport is disposed');
    if (UniversalBle.getQueueDiagnostics(_device.deviceId).state ==
        QueueDiagnosticsState.faulted) {
      throw StateError(
        'BLE queue recovery is still pending for ${_device.deviceId}',
      );
    }
    _connectionGeneration++;
    final generation = _connectionGeneration;
    _linkDeadDeclared = false;
    _lastAdvertProbe = null;
    await _listenForConnectionUpdates(generation);
    if (_isLinux) {
      await _connectBlueZ();
      _startAdvertWatch();
      return;
    }
    if (_isAndroid) {
      try {
        _log.fine("stopping scan before connect");
        await _stopScanViaOwner();
      } catch (e) {
        _log.fine("stopScan before connect failed (ignored): $e");
      }
      await Future.delayed(_androidPreConnectSettleDelay);
    }
    try {
      await UniversalBle.connect(
        _device.deviceId,
        timeout: Duration(seconds: 20),
      );
    } on UniversalBleException catch (e) {
      throw mapUniversalConnectError(e);
    }
    _startAdvertWatch();

    if (_isAndroid) {
      await Future.delayed(_androidPostConnectDelay);
    }
    if (!_isLinux && (_isAndroid || _requestLargeMtuNonAndroid)) {
      try {
        await UniversalBle.requestMtu(
          _device.deviceId,
          517,
          timeout: const Duration(seconds: 5),
        );
        _log.fine('MTU negotiation successful');
      } catch (e) {
        _log.fine('MTU negotiation failed (using default): $e');
      }
    }
  }

  Future<void> _connectBlueZ() async {
    try {
      await _doConnectBlueZ();
    } on UniversalBleException catch (e) {
      _log.warning(
        "BlueZ connect failed ($e); refreshing device cache and retrying",
      );
      await _refreshDeviceCache();
      try {
        await _doConnectBlueZ();
      } on UniversalBleException catch (e2) {
        throw mapUniversalConnectError(e2);
      }
    }
  }

  Future<void> _listenForConnectionUpdates(int generation) async {
    await _connectionStateSubscription?.cancel();
    if (_connectionGeneration != generation || _disposed) return;
    _connectionStateSubscription =
        UniversalBle.connectionUpdateStream(_device.deviceId).listen((update) {
          if (_connectionGeneration != generation) return;
          if (update.isConnected) {
            _connectionStateSubject.add(device.ConnectionState.connected);
          } else {
            if (_maintenanceGeneration == generation) return;
            _recoveringQueueGeneration = null;
            final reason = update.error ?? 'unknown';
            _log.warning('Transport disconnected: $reason');
            _publishDisconnected();
          }
        });
  }

  Future<void> _doConnectBlueZ([int? maintenanceGeneration]) async {
    await _stopScanAndSettle(maintenanceGeneration);
    await UniversalBle.connect(
      _device.deviceId,
      timeout: Duration(seconds: 15),
    );
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
    await Future.delayed(_bluezPostConnectDelay);
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
  }

  Future<void> _stopScanAndSettle([int? maintenanceGeneration]) async {
    try {
      await _stopScanViaOwner();
    } catch (e) {
      _log.fine("stopScan before BlueZ connect failed (ignored): $e");
    }
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
    _log.fine(
      "Waiting ${_bluezScanSettleDelay.inSeconds}s for BlueZ to settle "
      "before connect",
    );
    await Future.delayed(_bluezScanSettleDelay);
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
  }

  Future<void> _refreshDeviceCache([int? maintenanceGeneration]) async {
    var ownsScan = false;
    try {
      await UniversalBle.stopScan();
      if (maintenanceGeneration != null) {
        _checkMaintenanceGeneration(maintenanceGeneration);
      }
      await Future.delayed(const Duration(milliseconds: 500));
      if (maintenanceGeneration != null) {
        _checkMaintenanceGeneration(maintenanceGeneration);
      }
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: []));
      ownsScan = true;
      if (maintenanceGeneration != null) {
        _checkMaintenanceGeneration(maintenanceGeneration);
      }
      await Future.delayed(_bluezCacheRefreshScan);
      if (maintenanceGeneration != null) {
        _checkMaintenanceGeneration(maintenanceGeneration);
      }
    } on _MaintenanceCancelled {
      rethrow;
    } catch (e) {
      _log.warning("BlueZ cache-refresh scan failed: $e");
      return;
    } finally {
      if (ownsScan) {
        try {
          await UniversalBle.stopScan();
        } catch (e) {
          _log.warning("Failed to stop BlueZ cache-refresh scan: $e");
        }
      }
    }
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
    await Future.delayed(_bluezScanSettleDelay);
    if (maintenanceGeneration != null) {
      _checkMaintenanceGeneration(maintenanceGeneration);
    }
  }

  static const _goneDeviceCodes = {
    UniversalBleErrorCode.deviceNotFound,
    UniversalBleErrorCode.connectionTerminated,
    UniversalBleErrorCode.deviceDisconnected,
  };

  static const _attributeMissingCodes = {
    UniversalBleErrorCode.characteristicNotFound,
    UniversalBleErrorCode.serviceNotFound,
  };

  Never _handleGattError(
    UniversalBleException e,
    String operation,
    String path,
  ) {
    if (_attributeMissingCodes.contains(e.code)) {
      _log.warning(
        'GATT $operation($path) failed — attribute not in GATT database: '
        '${e.code}',
      );
      unawaited(
        _probeAndDeclareIfDead(
          'GATT $operation($path) attribute missing',
          _connectionGeneration,
        ),
      );
      throw GattAttributeUnavailableException(operation: operation, path: path);
    }
    if (_goneDeviceCodes.contains(e.code)) {
      _log.warning('GATT $operation($path) failed — device gone: ${e.code}');
      _connectionStateSubject.add(device.ConnectionState.disconnected);
      _clearQueue(UniversalBleErrorCode.deviceDisconnected);
      throw const DeviceNotConnectedException.unknown();
    }
    if (e.code == UniversalBleErrorCode.gattError) {
      _log.warning(
        'GATT $operation($path) failed — GATT error 133 (transient): $e',
      );
      _clearQueue(UniversalBleErrorCode.operationCancelled);
      throw BleTimeoutException('GATT $operation($path)', e);
    }
    if (e.code == UniversalBleErrorCode.unknownError) {
      _log.warning(
        'GATT $operation($path) failed — unknown error (likely BT off): $e',
      );
      _connectionStateSubject.add(device.ConnectionState.disconnected);
      _clearQueue(UniversalBleErrorCode.deviceDisconnected);
      throw const DeviceNotConnectedException.unknown();
    }
    throw e;
  }

  @override
  Future<device.ConnectionState> getConnectionState() async {
    final state = await UniversalBle.getConnectionState(
      _device.deviceId,
      timeout: const Duration(seconds: 2),
    );
    return switch (state) {
      BleConnectionState.connected => device.ConnectionState.connected,
      BleConnectionState.connecting => device.ConnectionState.connecting,
      BleConnectionState.disconnecting ||
      BleConnectionState.disconnected => device.ConnectionState.disconnected,
    };
  }

  @override
  Stream<device.ConnectionState> get connectionState =>
      _connectionStateSubject.asBroadcastStream();

  @override
  Future<void> disconnect() {
    _connectionGeneration++;
    return _lifecycleGate.run(_device.deviceId, _disconnectLocked);
  }

  Future<void> _disconnectLocked() async {
    _maintenanceGeneration = null;
    await _advertSub?.cancel();
    _advertSub = null;

    final listeners = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final listener in listeners) {
      try {
        await listener.cancel();
      } catch (error, stackTrace) {
        _log.warning(
          'Failed to cancel BLE notification listener',
          error,
          stackTrace,
        );
      }
    }

    try {
      _log.fine("disconnect");
      await _disconnectNative();
      _publishDisconnected();
    } catch (error, stackTrace) {
      _log.warning("failed to disconnect", error, stackTrace);
      if (UniversalBle.getQueueDiagnostics(_device.deviceId).state ==
          QueueDiagnosticsState.faulted) {
        rethrow;
      }
      _publishDisconnected();
    } finally {
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
    }
  }

  Future<void> _disconnectNative() {
    final active = _nativeDisconnectOperation;
    if (active != null) return active;
    late final Future<void> operation;
    operation =
        UniversalBle.disconnect(
          _device.deviceId,
          timeout: _faultRecoveryDisconnectTimeout,
        ).whenComplete(() {
          if (identical(_nativeDisconnectOperation, operation)) {
            _nativeDisconnectOperation = null;
          }
        });
    _nativeDisconnectOperation = operation;
    return operation;
  }

  @override
  Future<List<String>> discoverServices() =>
      _lifecycleGate.run(_device.deviceId, _discoverServicesLocked);

  Future<List<String>> _discoverServicesLocked() async {
    if (!_isLinux) {
      final services = await UniversalBle.discoverServices(
        _device.deviceId,
        timeout: Duration(seconds: 10),
      );
      _log.fine(
        "discovered services: ${services.map((e) => e.toString()).toList().join('\n')}",
      );
      return services.map((s) => s.uuid).toList();
    }

    final generation = _connectionGeneration;
    try {
      return await _discoverServicesBlueZ();
    } on UniversalBleException catch (error) {
      if (error.code != UniversalBleErrorCode.servicesNotResolved) rethrow;
      if (_connectionGeneration != generation || _disposed) {
        throw UniversalBleException(
          code: UniversalBleErrorCode.operationCancelled,
          message: 'BLE service discovery was cancelled',
        );
      }
      return _recoverBlueZServices(generation);
    }
  }

  Future<List<String>> _discoverServicesBlueZ() async {
    final services = await UniversalBle.discoverServices(
      _device.deviceId,
      timeout: const Duration(seconds: 15),
    );
    _log.fine('discovered ${services.length} services');
    return services.map((service) => service.uuid).toList();
  }

  Future<List<String>> _recoverBlueZServices(int generation) async {
    _maintenanceGeneration = generation;
    try {
      await _advertSub?.cancel();
      _advertSub = null;
      _checkMaintenanceGeneration(generation);
      await _stopScanAndSettle(generation);
      await _disconnectNative();
      _checkMaintenanceGeneration(generation);
      await _waitForNativeDisconnect(generation);
      _checkMaintenanceGeneration(generation);
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      _checkMaintenanceGeneration(generation);
      await UniversalBle.clearGattCache(_device.deviceId);
      _checkMaintenanceGeneration(generation);
      await _refreshDeviceCache(generation);
      await _doConnectBlueZ(generation);
      await _listenForConnectionUpdates(generation);
      _checkMaintenanceGeneration(generation);
      final services = await _discoverServicesBlueZ();
      _checkMaintenanceGeneration(generation);
      _startAdvertWatch();
      _maintenanceGeneration = null;
      return services;
    } on _MaintenanceCancelled {
      _maintenanceGeneration = null;
      throw UniversalBleException(
        code: UniversalBleErrorCode.operationCancelled,
        message: 'BLE maintenance recovery was cancelled',
      );
    } catch (_) {
      _maintenanceGeneration = null;
      try {
        await _disconnectNative();
      } catch (_) {}
      _publishDisconnected();
      rethrow;
    }
  }

  Future<void> _waitForNativeDisconnect(int generation) async {
    final deadline = DateTime.now().add(_faultRecoveryDisconnectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      _checkMaintenanceGeneration(generation);
      final state = await UniversalBle.getConnectionState(
        _device.deviceId,
        timeout: const Duration(seconds: 2),
      );
      _checkMaintenanceGeneration(generation);
      if (state == BleConnectionState.disconnected) return;
      await Future<void>.delayed(_faultRecoveryPollInterval);
    }
    throw TimeoutException('Timed out waiting for native BLE disconnect');
  }

  void _checkMaintenanceGeneration(int generation) {
    if (_connectionGeneration != generation || _disposed) {
      throw const _MaintenanceCancelled();
    }
  }

  @override
  String get id => _device.deviceId;

  @override
  String get name => _device.name ?? "Unknown";

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    try {
      final value = await UniversalBle.read(
        _device.deviceId,
        serviceUUID,
        characteristicUUID,
        timeout: timeout,
      );
      return value;
    } on TimeoutException {
      _onOperationTimeout('read', '$serviceUUID/$characteristicUUID');
      rethrow;
    } on UniversalBleException catch (e) {
      _handleGattError(e, 'read', '$serviceUUID/$characteristicUUID');
    }
  }

  void _onOperationTimeout(String operation, String path) {
    _log.warning('GATT $operation($path) timed out — BLE queue faulted');
    final generation = _connectionGeneration;
    unawaited(_probeAndDeclareIfDead('GATT $operation timeout', generation));
    if (_recoveringQueueGeneration == generation) return;
    _recoveringQueueGeneration = generation;
    unawaited(_recoverFaultedQueue(generation, 'GATT $operation($path)'));
  }

  Future<void> _recoverFaultedQueue(int generation, String context) async {
    final deadline = DateTime.now().add(_faultRecoveryGrace);
    var disconnectAttempted = false;
    try {
      while (true) {
        if (_recoveringQueueGeneration != generation) return;
        final diagnostics = UniversalBle.getQueueDiagnostics(_device.deviceId);
        if (diagnostics.state != QueueDiagnosticsState.faulted) return;
        if (diagnostics.activeOperations == 0) {
          _clearQueue(UniversalBleErrorCode.operationCancelled);
          return;
        }
        if (!disconnectAttempted && !DateTime.now().isBefore(deadline)) {
          disconnectAttempted = true;
          _log.warning(
            '$context native operation remained unresolved for '
            '${_faultRecoveryGrace.inMilliseconds}ms — disconnecting',
          );
          try {
            await _disconnectNative();
          } catch (error, stackTrace) {
            _log.warning(
              'Failed to disconnect unresolved BLE link',
              error,
              stackTrace,
            );
          }
        }
        await Future<void>.delayed(_faultRecoveryPollInterval);
      }
    } finally {
      if (_recoveringQueueGeneration == generation) {
        _recoveringQueueGeneration = null;
      }
    }
  }

  void _clearQueue(UniversalBleErrorCode code) {
    UniversalBle.clearQueueWithError(
      _device.deviceId,
      error: UniversalBleException(
        code: code,
        message: code == UniversalBleErrorCode.operationCancelled
            ? 'Cancelled after a preceding BLE operation timed out'
            : 'Cancelled because the BLE device disconnected',
      ),
    );
  }

  void _startAdvertWatch() {
    _advertSub?.cancel();
    _advertSub = UniversalBle.scanStream
        .where((d) => d.deviceId == _device.deviceId)
        .listen(_onOwnAdvertisement);
  }

  void _onOwnAdvertisement(BleDevice _) {
    if (_maintenanceGeneration == _connectionGeneration) return;
    if (_connectionStateSubject.valueOrNull !=
        device.ConnectionState.connected) {
      return;
    }
    final now = DateTime.now();
    final last = _lastAdvertProbe;
    if (last != null && now.difference(last) < _advertProbeThrottle) return;
    _lastAdvertProbe = now;
    _log.warning(
      'Received advertisement while believed connected — probing OS link state',
    );
    unawaited(
      _probeAndDeclareIfDead(
        'advertising while believed connected',
        _connectionGeneration,
      ),
    );
  }

  Future<void> _probeAndDeclareIfDead(String context, int generation) async {
    final BleConnectionState state;
    try {
      state = await UniversalBle.getConnectionState(
        _device.deviceId,
        timeout: _linkProbeTimeout,
      );
    } catch (e) {
      if (generation != _connectionGeneration ||
          _maintenanceGeneration == generation) {
        return;
      }
      _log.fine('Link probe inconclusive ($context): $e');
      return;
    }
    if (generation != _connectionGeneration ||
        _maintenanceGeneration == generation ||
        state == BleConnectionState.connected ||
        state == BleConnectionState.connecting) {
      return;
    }
    _declareLinkDead('$context; OS reports ${state.name}');
  }

  void _declareLinkDead(String reason) {
    if (_linkDeadDeclared) return;
    _linkDeadDeclared = true;
    _recoveringQueueGeneration = null;
    _log.warning('Declaring BLE link dead: $reason');
    _advertSub?.cancel();
    _advertSub = null;
    _clearQueue(UniversalBleErrorCode.deviceDisconnected);
    if (_connectionStateSubject.valueOrNull !=
        device.ConnectionState.disconnected) {
      _publishDisconnected();
    }
  }

  void _publishDisconnected() {
    if (!_connectionStateSubject.isClosed &&
        _connectionStateSubject.valueOrNull !=
            device.ConnectionState.disconnected) {
      _connectionStateSubject.add(device.ConnectionState.disconnected);
    }
  }

  final Map<String, StreamSubscription<Uint8List>> _subscriptions = {};

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    _log.fine("subscribe to: $serviceUUID, $characteristicUUID");
    final key = "$serviceUUID--$characteristicUUID";
    await _subscriptions.remove(key)?.cancel();
    final sub = UniversalBle.characteristicValueStream(
      _device.deviceId,
      characteristicUUID,
    ).listen(callback);
    _subscriptions[key] = sub;

    try {
      await UniversalBle.subscribeNotifications(
        _device.deviceId,
        serviceUUID,
        characteristicUUID,
      );
    } on UniversalBleException catch (e) {
      _handleGattError(e, 'subscribe', '$serviceUUID/$characteristicUUID');
    }
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    final key = "$serviceUUID--$characteristicUUID";
    if (!_subscriptions.containsKey(key)) {
      _subscriptions[key] = UniversalBle.characteristicValueStream(
        _device.deviceId,
        characteristicUUID,
      ).listen(callback);
    }
    try {
      await UniversalBle.unsubscribe(
        _device.deviceId,
        serviceUUID,
        characteristicUUID,
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(_notificationResetSettle);
      await UniversalBle.subscribeNotifications(
        _device.deviceId,
        serviceUUID,
        characteristicUUID,
        timeout: const Duration(seconds: 2),
      );
    } on TimeoutException {
      _onOperationTimeout(
        'reset subscription',
        '$serviceUUID/$characteristicUUID',
      );
      rethrow;
    } on UniversalBleException catch (e) {
      _handleGattError(
        e,
        'reset subscription',
        '$serviceUUID/$characteristicUUID',
      );
    }
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    try {
      await UniversalBle.write(
        _device.deviceId,
        BleUuidParser.string(serviceUUID),
        BleUuidParser.string(characteristicUUID),
        data,
        withoutResponse: !withResponse,
        timeout: timeout,
      );
    } on TimeoutException {
      _onOperationTimeout('write', '$serviceUUID/$characteristicUUID');
      rethrow;
    } on UniversalBleException catch (e) {
      _handleGattError(e, 'write', '$serviceUUID/$characteristicUUID');
    }
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {
    if (!BleCapabilities.supportsConnectionPriorityApi) return;
    try {
      await UniversalBle.requestConnectionPriority(
        _device.deviceId,
        prioritized
            ? BleConnectionPriority.highPerformance
            : BleConnectionPriority.balanced,
      );
    } on UniversalBleException catch (e) {
      _log.fine("requestConnectionPriority not applied: ${e.code}");
    }
  }

  @override
  Future<void> dispose() {
    _connectionGeneration++;
    _disposed = true;
    return _lifecycleGate.run(_device.deviceId, _disposeLocked);
  }

  Future<void> _disposeLocked() async {
    _maintenanceGeneration = null;
    _advertSub?.cancel();
    _advertSub = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    if (!_connectionStateSubject.isClosed) {
      _connectionStateSubject.close();
    }
  }
}

class _MaintenanceCancelled implements Exception {
  const _MaintenanceCancelled();
}
