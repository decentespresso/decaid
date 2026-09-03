import 'dart:async';
import 'dart:io' show Platform;
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/ble_connect_exception.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/scan_filter.dart' as domain;
import 'package:reaprime/src/services/ble/ble_discovery_service.dart';
import 'package:reaprime/src/services/ble/ble_lifecycle_gate.dart';
import 'package:reaprime/src/services/ble/universal_ble_transport.dart';
import 'package:reaprime/src/services/device_factory.dart';
import 'package:reaprime/src/services/device_matcher.dart';
import 'package:reaprime/src/models/device/device_watch.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/models/device/watch_state.dart';
import 'package:reaprime/src/models/device/ble_scan_state.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';
import 'package:universal_ble/universal_ble.dart';
import '../models/device/device.dart';
import '../models/device/machine.dart';
import '../models/device/impl/de1/de1.models.dart';
import 'package:logging/logging.dart' as logging;

typedef BleTransportFactory =
    BLETransport Function({
      required BleDevice device,
      required Future<void> Function() stopScan,
      required bool requestLargeMtuNonAndroid,
      required BleLifecycleGate lifecycleGate,
    });

class _AdvertisementStats {
  int count = 0;
  DateTime? lastSeen;
  String? name;
}

class UniversalBleDiscoveryService extends BleDiscoveryService
    implements DeviceWatchCapable {
  UniversalBleDiscoveryService({
    bool Function()? watchSupportGate,
    bool Function()? requestLargeMtuNonAndroid,
    BleTransportFactory? transportFactory,
  }) : _watchSupportGate = watchSupportGate ?? (() => Platform.isAndroid),
       requestLargeMtuNonAndroid = requestLargeMtuNonAndroid ?? (() => false),
       _transportFactory = transportFactory ?? _defaultTransportFactory;

  static BLETransport _defaultTransportFactory({
    required BleDevice device,
    required Future<void> Function() stopScan,
    required bool requestLargeMtuNonAndroid,
    required BleLifecycleGate lifecycleGate,
  }) {
    return UniversalBleTransport(
      device: device,
      stopScan: stopScan,
      requestLargeMtuNonAndroid: requestLargeMtuNonAndroid,
      lifecycleGate: lifecycleGate,
    );
  }

  final bool Function() _watchSupportGate;
  final BleTransportFactory _transportFactory;
  final BleLifecycleGate _lifecycleGate = BleLifecycleGate();

  bool Function() requestLargeMtuNonAndroid;

  BLETransport _createTransport(BleDevice device) {
    return _transportFactory(
      device: device,
      stopScan: _stopScanForConnect,
      requestLargeMtuNonAndroid: requestLargeMtuNonAndroid(),
      lifecycleGate: _lifecycleGate,
    );
  }

  @override
  bool get supportsDeviceWatch => _watchSupportGate();

  DeviceWatchFilter? _watchRequested;
  BleScanOwner _scanOwner = BleScanOwner.none;
  BleScanPhase _scanPhase = BleScanPhase.idle;
  int _scanGeneration = 0;
  int _watchRequestGeneration = 0;
  StreamSubscription<BleDevice>? _watchScanSub;
  Timer? _watchRefreshTimer;

  int _watchAdapterGeneration = 0;
  AdapterState? _lastWatchAdapterState;
  bool _adapterOffBoundaryPending = false;

  bool _watchStartNeedsRetry = false;

  static const _watchRefreshInterval = Duration(minutes: 25);

  static const _watchLivenessInterval = Duration(seconds: 90);
  Timer? _watchLivenessTimer;

  final StreamController<void> _watchFailureController =
      StreamController.broadcast();
  final BehaviorSubject<DeviceWatchState> _watchStateSubject =
      BehaviorSubject.seeded(DeviceWatchState.inactive);

  @override
  Stream<void> get deviceWatchFailures => _watchFailureController.stream;

  @override
  Stream<DeviceWatchState> get deviceWatchState => _watchStateSubject.stream;

  BleScanOwner get scanOwner => _scanOwner;
  BleScanPhase get scanPhase => _scanPhase;
  int get scanGeneration => _scanGeneration;
  DeviceWatchState get currentDeviceWatchState => _watchStateSubject.value;
  bool get watchDeviceSubscriptionInstalled => _watchScanSub != null;
  int get scanFailureCount => _scanFailureCount;
  String? get latestScanFailure => _latestScanFailure;
  DateTime? get latestScanFailureAt => _latestScanFailureAt;

  int _scanFailureCount = 0;
  String? _latestScanFailure;
  DateTime? _latestScanFailureAt;

  Future<void>? _watchStartInFlight;

  bool get _isScanning =>
      _scanOwner == BleScanOwner.burst ||
      (_scanOwner == BleScanOwner.watch && _scanPhase == BleScanPhase.stopping);
  bool get _watchScanActive =>
      _scanOwner == BleScanOwner.watch && _scanPhase == BleScanPhase.active;

  void _setWatchState(DeviceWatchState state) {
    if (_watchStateSubject.value == state) return;
    _watchStateSubject.add(state);
  }

  void _recordScanFailure(Object error) {
    _scanFailureCount++;
    _latestScanFailure = error.toString();
    _latestScanFailureAt = DateTime.now().toUtc();
  }

  @override
  Future<DeviceWatchStartResult> startDeviceWatch(
    DeviceWatchFilter filter,
  ) async {
    _watchRequested = filter;
    final requestGeneration = ++_watchRequestGeneration;
    if (_isScanning) {
      _setWatchState(DeviceWatchState.queued);
      log.fine('Burst scan in flight; watch starts when it completes');
      return DeviceWatchStartResult.queuedBehindBurst;
    }
    try {
      await _startWatchScan();
    } catch (e) {
      if (requestGeneration == _watchRequestGeneration &&
          identical(_watchRequested, filter)) {
        _watchRequested = null;
        _scanOwner = BleScanOwner.none;
        _scanPhase = BleScanPhase.faulted;
        _setWatchState(DeviceWatchState.faulted);
      }
      return DeviceWatchStartResult.failed;
    }
    return _watchScanActive
        ? DeviceWatchStartResult.active
        : DeviceWatchStartResult.queuedBehindBurst;
  }

  @override
  Future<void> stopDeviceWatch() async {
    _watchRequested = null;
    _watchRequestGeneration++;
    await _awaitInFlightWatchStart();
    await _deactivateWatchScan(
      stopOsScan: _watchScanActive && !_isScanning,
      context: 'stopDeviceWatch',
    );
  }

  Future<void> _awaitInFlightWatchStart() async {
    final inflight = _watchStartInFlight;
    if (inflight == null) return;
    try {
      await inflight;
    } catch (_) {}
  }

  void _cancelWatchScanSub() {
    final sub = _watchScanSub;
    _watchScanSub = null;
    unawaited(sub?.cancel());
  }

  Future<void> _deactivateWatchScan({
    required bool stopOsScan,
    required String context,
  }) async {
    _watchRefreshTimer?.cancel();
    _watchRefreshTimer = null;
    _watchLivenessTimer?.cancel();
    _watchLivenessTimer = null;
    _cancelWatchScanSub();
    if (_scanOwner == BleScanOwner.watch) {
      _scanPhase = stopOsScan ? BleScanPhase.stopping : BleScanPhase.idle;
      _scanGeneration++;
    }
    if (stopOsScan) {
      try {
        await UniversalBle.stopScan();
      } catch (e, st) {
        _recordScanFailure(e);
        _scanPhase = BleScanPhase.faulted;
        _setWatchState(DeviceWatchState.faulted);
        log.warning('$context: stopScan failed', e, st);
        rethrow;
      }
    }
    if (_scanOwner == BleScanOwner.watch) {
      _scanOwner = BleScanOwner.none;
      _scanPhase = BleScanPhase.idle;
    }
    if (_scanPhase != BleScanPhase.faulted) {
      _setWatchState(DeviceWatchState.inactive);
    }
  }

  Future<void> _restartWatchOrReportFailure(String context) async {
    try {
      await _startWatchScan();
    } catch (e, st) {
      log.warning('$context: watch restart failed — reporting', e, st);
      _watchRequested = null;
      _setWatchState(DeviceWatchState.faulted);
      await _deactivateWatchScan(stopOsScan: false, context: context);
      if (!_watchFailureController.isClosed) {
        _watchFailureController.add(null);
      }
    }
  }

  Future<void> _startWatchScan() {
    final existing = _watchStartInFlight;
    if (existing != null) return existing;
    final start = _runWatchScanStart();
    _watchStartInFlight = start;
    return start.whenComplete(() {
      if (identical(_watchStartInFlight, start)) {
        _watchStartInFlight = null;
      }
      if (_watchStartNeedsRetry) {
        _watchStartNeedsRetry = false;
        unawaited(_restartWatchOrReportFailure('adapter-transition retry'));
      }
    });
  }

  Future<void> _runWatchScanStart() async {
    final filter = _watchRequested;
    if (filter == null || _watchScanActive) return;
    if (_scanPhase == BleScanPhase.faulted) {
      throw StateError('BLE scan ownership is faulted');
    }
    if (_scanOwner == BleScanOwner.burst) {
      _setWatchState(DeviceWatchState.queued);
      return;
    }
    if (_adapterStateSubject.value != AdapterState.poweredOn) {
      _setWatchState(DeviceWatchState.queued);
      log.fine('Adapter not powered on; watch pends adapter recovery');
      return;
    }
    final adapterGen = _watchAdapterGeneration;
    _scanOwner = BleScanOwner.watch;
    _scanPhase = BleScanPhase.starting;
    _scanGeneration++;

    _watchScanSub = UniversalBle.scanStream.listen((result) async {
      if (_currentlyScanning.contains(normalizeBleDeviceId(result.deviceId))) {
        return;
      }
      await _deviceScanned(result);
    });

    final namePrefix = filter.namePrefix;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withNamePrefix: namePrefix != null ? [namePrefix] : [],
          withServices: [],
        ),
        platformConfig: PlatformConfig(
          android: AndroidOptions(
            scanMode: AndroidScanMode.balanced,
            matchMode: AndroidScanMatchMode.aggressive,
            numOfMatches: AndroidScanNumOfMatches.max,
          ),
        ),
      );
    } catch (e) {
      _cancelWatchScanSub();
      _recordScanFailure(e);
      if (_scanOwner == BleScanOwner.watch) {
        _scanOwner = BleScanOwner.none;
        _scanPhase = BleScanPhase.faulted;
      }
      _setWatchState(DeviceWatchState.faulted);
      rethrow;
    }
    if (_watchRequested == null) {
      log.fine('Watch stopped during start; undoing scan');
      await _deactivateWatchScan(stopOsScan: true, context: 'start-undo');
      return;
    }
    if (_isScanning) {
      log.fine('Burst scan raced watch start; standing down until it ends');
      await _deactivateWatchScan(stopOsScan: false, context: 'start-burst');
      return;
    }
    if (adapterGen != _watchAdapterGeneration) {
      log.fine('Adapter transitioned during watch start; discarding start');
      await _deactivateWatchScan(
        stopOsScan: true,
        context: 'start-adapter-transition',
      );
      _watchStartNeedsRetry = true;
      return;
    }
    _scanPhase = BleScanPhase.active;
    _setWatchState(DeviceWatchState.active);
    _armWatchRefresh();
    _armWatchLiveness();
    log.info('Background device watch started (prefix: $namePrefix)');
  }

  void _armWatchLiveness() {
    _watchLivenessTimer?.cancel();
    _watchLivenessTimer = Timer(_watchLivenessInterval, () async {
      _watchLivenessTimer = null;
      if (!_watchScanActive || _isScanning) return;
      bool alive;
      try {
        alive = await UniversalBle.isScanning();
      } catch (e, st) {
        log.fine('Watch liveness probe failed', e, st);
        alive = true;
      }
      if (!_watchScanActive || _isScanning) return;
      if (alive) {
        _armWatchLiveness();
        return;
      }
      log.warning('Watch scan died silently (isScanning=false); restarting');
      await _deactivateWatchScan(stopOsScan: false, context: 'liveness');
      await _restartWatchOrReportFailure('liveness restart');
    });
  }

  void _armWatchRefresh() {
    _watchRefreshTimer?.cancel();
    _watchRefreshTimer = Timer(_watchRefreshInterval, () async {
      _watchRefreshTimer = null;
      if (!_watchScanActive || _isScanning) return;
      log.fine('Refreshing watch scan (30-min opportunistic-downgrade guard)');
      await _deactivateWatchScan(stopOsScan: true, context: 'watch-refresh');
      await _restartWatchOrReportFailure('watch-refresh');
    });
  }

  Future<void> _pauseWatchForBurst() async {
    await _awaitInFlightWatchStart();
    if (_scanOwner != BleScanOwner.watch ||
        (_scanPhase != BleScanPhase.active &&
            _scanPhase != BleScanPhase.stopping)) {
      return;
    }
    log.fine('Pausing background watch for burst scan');
    await _deactivateWatchScan(stopOsScan: true, context: 'watch-pause');
  }

  Future<void> _resumeWatchAfterBurst() async {
    if (_watchRequested == null) return;
    await _restartWatchOrReportFailure('post-burst resume');
  }

  void _onAdapterStateForWatch(AdapterState state) {
    if (state == _lastWatchAdapterState) return;
    _lastWatchAdapterState = state;
    _watchAdapterGeneration++;
    if (state == AdapterState.poweredOff) {
      _adapterOffBoundaryPending = true;
      if (_watchScanActive) {
        unawaited(
          _deactivateWatchScan(stopOsScan: false, context: 'adapter-off'),
        );
      }
      return;
    }
    if (state != AdapterState.poweredOn) return;

    if (_adapterOffBoundaryPending && _scanPhase == BleScanPhase.faulted) {
      _adapterOffBoundaryPending = false;
      _watchStartNeedsRetry = false;
      _scanOwner = BleScanOwner.none;
      _scanPhase = BleScanPhase.idle;
      _scanStopError = null;
      _scanGeneration++;
      _setWatchState(
        _watchRequested == null
            ? DeviceWatchState.inactive
            : DeviceWatchState.queued,
      );
    }
    _adapterOffBoundaryPending = false;
    if (_watchRequested != null && !_watchScanActive && !_isScanning) {
      unawaited(_restartWatchOrReportFailure('adapter recovery'));
    }
  }

  final Map<String, Device> _devices = {};
  final Map<String, _AdvertisementStats> _advertisements = {};
  final Map<String, Future<Device?>> _candidateInFlight = {};

  final log = logging.Logger("UniversalBleDeviceService");

  final StreamController<List<Device>> _deviceStreamController =
      StreamController.broadcast();

  final Map<String, StreamSubscription<ConnectionState>> _connections = {};

  final Set<String> _currentlyScanning = {};
  StreamSubscription<AvailabilityState>? _availabilitySubscription;
  bool _disposed = false;

  Future<void>? _burstStartInFlight;
  Future<void>? _burstStopInFlight;
  ({Object error, StackTrace stackTrace})? _scanStopError;

  Timer? _scanDurationTimer;
  Completer<void>? _scanDurationCompleter;

  final BehaviorSubject<AdapterState> _adapterStateSubject =
      BehaviorSubject.seeded(AdapterState.unknown);

  @override
  Stream<AdapterState> get adapterStateStream => _adapterStateSubject.stream;

  @override
  Stream<List<Device>> get devices => _deviceStreamController.stream;

  @override
  Future<Map<String, Object?>> diagnostics() async {
    Object? nativeIsScanning;
    String? nativeScanError;
    try {
      nativeIsScanning = await UniversalBle.isScanning().timeout(
        const Duration(seconds: 2),
      );
    } catch (e) {
      nativeScanError = e.toString();
    }

    final cache = <Map<String, Object?>>[];
    for (final entry in _devices.entries) {
      String state;
      try {
        state = (await entry.value.connectionState.first.timeout(
          const Duration(seconds: 2),
          onTimeout: () => ConnectionState.disconnected,
        )).name;
      } catch (e) {
        state = 'error: $e';
      }
      cache.add({
        'deviceId': entry.key,
        'name': entry.value.name,
        'type': entry.value.type.name,
        'implementation': entry.value.implementation.name,
        'transport': entry.value.transportType.name,
        'connectionState': state,
        'instanceId': identityHashCode(entry.value),
      });
    }

    return {
      'serviceInstanceId': identityHashCode(this),
      'adapterState': _adapterStateSubject.value.name,
      'scan': {
        'owner': _scanOwner.name,
        'phase': _scanPhase.name,
        'generation': _scanGeneration,
        'nativeIsScanning': nativeIsScanning,
        'nativeIsScanningError': nativeScanError,
      },
      'watch': {
        'state': _watchStateSubject.value.name,
        'requested': _watchRequested != null,
        'filterNamePrefix': _watchRequested?.namePrefix,
        'deviceSubscriptionInstalled': _watchScanSub != null,
        'refreshTimerActive': _watchRefreshTimer != null,
        'livenessTimerActive': _watchLivenessTimer != null,
      },
      'cache': cache,
      'advertisements': {
        for (final entry in _advertisements.entries)
          entry.key: {
            'count': entry.value.count,
            'lastSeen': entry.value.lastSeen?.toIso8601String(),
            'name': entry.value.name,
          },
      },
      'scanFailures': {
        'count': _scanFailureCount,
        'latest': _latestScanFailure,
        'latestAt': _latestScanFailureAt?.toIso8601String(),
      },
    };
  }

  @override
  Future<void> initialize() async {
    if (_availabilitySubscription != null) return;
    _disposed = false;
    UniversalBle.queueType = QueueType.perDevice;

    var initialState = await UniversalBle.getBluetoothAvailabilityState();

    if (Platform.isIOS && initialState == AvailabilityState.unknown) {
      log.info('iOS adapter state is unknown; requesting BLE permissions');
      await UniversalBle.requestPermissions();
      initialState = await UniversalBle.getBluetoothAvailabilityState();
    }

    final mappedInitialState = _mapAvailabilityState(initialState);
    _adapterStateSubject.add(mappedInitialState);
    _lastWatchAdapterState = mappedInitialState;

    _availabilitySubscription = UniversalBle.availabilityStream.listen((state) {
      if (_disposed) return;
      log.info("BLE Adapter state: ${state.name}");
      final mapped = _mapAvailabilityState(state);
      _adapterStateSubject.add(mapped);
      _onAdapterStateForWatch(mapped);
    });

    if (initialState != AvailabilityState.poweredOn) {
      log.warning(
        "Bluetooth not supported on this platform, state: ${initialState.name}",
      );
    }
  }

  static AdapterState _mapAvailabilityState(AvailabilityState state) {
    switch (state) {
      case AvailabilityState.poweredOn:
        return AdapterState.poweredOn;
      case AvailabilityState.poweredOff:
        return AdapterState.poweredOff;
      case AvailabilityState.unsupported:
        return AdapterState.unavailable;
      case AvailabilityState.unauthorized:
        return AdapterState.unauthorized;
      default:
        return AdapterState.unknown;
    }
  }

  @override
  void stopScan() {
    if (!_isScanning) {
      if (_watchScanActive) {
        log.fine('stopScan ignored: only the background watch is running');
      }
      return;
    }
    _scanPhase = BleScanPhase.stopping;
    unawaited(_stopBurstScan());
  }

  Future<void> _stopScanForConnect() async {
    if (_scanOwner == BleScanOwner.burst) {
      _scanPhase = BleScanPhase.stopping;
      await _stopBurstScan();
      final stopError = _scanStopError;
      if (stopError != null) {
        Error.throwWithStackTrace(stopError.error, stopError.stackTrace);
      }
      return;
    }
    await UniversalBle.stopScan();
  }

  Future<void> _stopBurstScan() {
    final existing = _burstStopInFlight;
    if (existing != null) return existing;
    late final Future<void> stop;
    stop = _stopBurstScanImpl().whenComplete(() {
      if (identical(_burstStopInFlight, stop)) _burstStopInFlight = null;
    });
    _burstStopInFlight = stop;
    return stop;
  }

  Future<void> _stopBurstScanImpl() async {
    final start = _burstStartInFlight;
    if (start != null) {
      try {
        await start;
      } catch (_) {}
    }
    try {
      await UniversalBle.stopScan();
    } catch (e, st) {
      _recordScanFailure(e);
      _scanStopError = (error: e, stackTrace: st);
      _scanPhase = BleScanPhase.faulted;
      log.warning('Burst stopScan failed', e, st);
    } finally {
      final c = _scanDurationCompleter;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  void _cancelScanDurationWait() {
    _scanDurationTimer?.cancel();
    _scanDurationTimer = null;
    _scanDurationCompleter = null;
  }

  Future<void> _waitForScanDuration(Duration duration) async {
    final completer = Completer<void>();
    _scanDurationCompleter = completer;
    _scanDurationTimer = Timer(duration, () {
      _scanPhase = BleScanPhase.stopping;
      unawaited(_stopBurstScan());
    });
    await completer.future;
    final stopError = _scanStopError;
    if (stopError != null) {
      Error.throwWithStackTrace(stopError.error, stopError.stackTrace);
    }
  }

  @override
  Future<void> scanForDevices({domain.ScanFilter? filter}) async {
    final state = _adapterStateSubject.value;
    if (state != AdapterState.poweredOn) {
      log.warning("Cannot scan, adapter state is $state");
      _deviceStreamController.add(_devices.values.toList());
      return;
    }
    if (_scanPhase == BleScanPhase.faulted) {
      throw StateError('BLE scan ownership is faulted');
    }
    await _awaitInFlightWatchStart();
    if (_scanOwner == BleScanOwner.burst) {
      log.warning('Scan already in progress, ignoring request');
      return;
    }
    if (_scanOwner == BleScanOwner.watch) {
      _scanPhase = BleScanPhase.stopping;
    }
    await _pauseWatchForBurst();
    if (_scanPhase == BleScanPhase.faulted) {
      throw StateError('BLE scan ownership is faulted');
    }

    _scanOwner = BleScanOwner.burst;
    _scanPhase = BleScanPhase.starting;
    _scanGeneration++;
    _scanStopError = null;
    StreamSubscription<BleDevice>? sub;

    try {
      log.fine("Clearing stale connections");
      _currentlyScanning.clear();

      sub = UniversalBle.scanStream.listen((result) async {
        log.finest(
          "Found: ${result.deviceId}: ${result.name}, adv: ${result.services}",
        );
        if (_currentlyScanning.contains(
          normalizeBleDeviceId(result.deviceId),
        )) {
          return;
        }
        await _deviceScanned(result);
      });

      final scanFilter = ScanFilter(withServices: []);

      final platformConfig = Platform.isAndroid
          ? PlatformConfig(
              android: AndroidOptions(
                scanMode: AndroidScanMode.lowLatency,
                matchMode: AndroidScanMatchMode.aggressive,
                numOfMatches: AndroidScanNumOfMatches.max,
              ),
            )
          : null;
      final start = UniversalBle.startScan(
        scanFilter: scanFilter,
        platformConfig: platformConfig,
      );
      _burstStartInFlight = start;
      try {
        await start;
      } catch (e) {
        _recordScanFailure(e);
        _scanPhase = BleScanPhase.faulted;
        rethrow;
      } finally {
        if (identical(_burstStartInFlight, start)) {
          _burstStartInFlight = null;
        }
      }
      if (_scanPhase == BleScanPhase.faulted) {
        throw StateError('BLE scan ownership is faulted');
      }
      _scanPhase = BleScanPhase.active;

      try {
        final systemDevices = await UniversalBle.getSystemDevices(
          withServices: [],
        );
        for (var d in systemDevices) {
          await _deviceScanned(d);
        }
      } catch (e, st) {
        log.fine('System device check failed', e, st);
      }

      await _waitForScanDuration(const Duration(seconds: 15));
    } finally {
      await sub?.cancel();
      _cancelScanDurationWait();
      _deviceStreamController.add(_devices.values.toList());
      final faulted = _scanPhase == BleScanPhase.faulted;
      if (_scanOwner == BleScanOwner.burst) {
        _scanOwner = BleScanOwner.none;
        _scanPhase = faulted ? BleScanPhase.faulted : BleScanPhase.idle;
      }
      if (!faulted) await _resumeWatchAfterBurst();
    }
  }

  void _recordAdvertisement(String deviceId, String? name) {
    final stats = _advertisements.putIfAbsent(
      deviceId,
      _AdvertisementStats.new,
    );
    stats.count++;
    stats.lastSeen = DateTime.now().toUtc();
    stats.name = name;
  }

  Future<BleConnectionState?> _nativeLinkState(String deviceId) async {
    try {
      return await UniversalBle.getConnectionState(
        deviceId,
        timeout: const Duration(seconds: 2),
      );
    } catch (e, st) {
      log.fine('Native link check failed for $deviceId', e, st);
      return null;
    }
  }

  Future<void> _deviceScanned(BleDevice device) async {
    final deviceId = normalizeBleDeviceId(device.deviceId);
    if (_currentlyScanning.contains(deviceId)) return;
    _currentlyScanning.add(deviceId);
    _recordAdvertisement(deviceId, device.name);

    try {
      final name = device.name ?? '';
      if (name.isEmpty &&
          !DeviceMatcher.advertisesKnownService(device.services)) {
        return;
      }

      final existing = _devices[deviceId];
      if (existing != null) {
        final state = await existing.connectionState.first.timeout(
          const Duration(seconds: 2),
          onTimeout: () => ConnectionState.disconnected,
        );
        if (state == ConnectionState.connected ||
            state == ConnectionState.connecting) {
          final nativeLink = await _nativeLinkState(existing.deviceId);
          if (nativeLink == null ||
              nativeLink == BleConnectionState.connected ||
              nativeLink == BleConnectionState.connecting) {
            return;
          }
          log.warning(
            'Replacing cached connected device $deviceId; '
            'native link is ${nativeLink.name}',
          );
        }
        _devices.remove(deviceId);
        await _connections.remove(deviceId)?.cancel();
        try {
          await existing.disconnect();
        } catch (e, st) {
          log.fine('Failed to discard stale device $deviceId', e, st);
        }
        _deviceStreamController.add(_devices.values.toList());
      }

      final matchedDevice = await _candidate(
        deviceId,
        () => DeviceMatcher.match(
          transport: _createTransport(device),
          advertisedName: name,
          advertisedServices: device.services,
        ),
      );

      if (matchedDevice != null) {
        _devices[deviceId] = matchedDevice;
        _deviceStreamController.add(_devices.values.toList());
        log.fine("found new device: ${device.name}");

        await _connections.remove(deviceId)?.cancel();
        _connections[deviceId] = matchedDevice.connectionState.listen((
          connectionState,
        ) {
          if (connectionState == ConnectionState.disconnected) {
            _devices.remove(deviceId);
            _deviceStreamController.add(_devices.values.toList());
          }
        });
      }
    } finally {
      _currentlyScanning.remove(deviceId);
    }
  }

  Future<Device?> _candidate(
    String deviceId,
    Future<Device?> Function() create,
  ) {
    final key = normalizeBleDeviceId(deviceId);
    final existing = _candidateInFlight[key];
    if (existing != null) return existing;
    late final Future<Device?> candidate;
    candidate = create().whenComplete(() {
      if (identical(_candidateInFlight[key], candidate)) {
        _candidateInFlight.remove(key);
      }
    });
    _candidateInFlight[key] = candidate;
    return candidate;
  }

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    final impl = remembered.implementation;
    final tt = remembered.transportType;
    if (impl == null || tt == null || tt != TransportType.ble) {
      return null;
    }

    return _candidate(
      remembered.id,
      () => _tryQuickConnectCandidate(remembered, impl),
    );
  }

  Future<Device?> _tryQuickConnectCandidate(
    RememberedDevice remembered,
    DeviceImplementation impl,
  ) async {
    final deviceId = remembered.id;
    final key = normalizeBleDeviceId(deviceId);

    BleDevice? bleDevice;
    if (Platform.isIOS || Platform.isMacOS) {
      bleDevice = await _findSystemDevice(deviceId);
      if (bleDevice == null) {
        log.info('Quick-connect: device $deviceId not in system cache');
        return null;
      }
    } else {
      bleDevice = BleDevice(deviceId: deviceId, name: remembered.name);
    }

    final transport = _createTransport(bleDevice);
    final device = DeviceFactory.createBle(impl, transport);
    if (device == null) {
      log.warning('Quick-connect: DeviceFactory returned null for $impl');
      return null;
    }

    try {
      await _connectWithRetry(device);
      if (device is Machine) {
        final model = device.machineInfo.model;
        final expectedBengle = impl == DeviceImplementation.bengle;
        final actualBengle = model == DecentMachineModel.Bengle.name;
        if (expectedBengle != actualBengle) {
          log.warning(
            'Quick-connect: identity mismatch for $deviceId '
            '(expected ${impl.name}, got model=$model)',
          );
          if (expectedBengle && !actualBengle) {
            try {
              await device.disconnect();
            } catch (_) {}
            try {
              await transport.dispose();
            } catch (_) {}
            return null;
          }
        }
      }
      _devices[key] = device;
      _deviceStreamController.add(_devices.values.toList());
      await _connections.remove(key)?.cancel();
      _connections[key] = device.connectionState.listen((state) {
        if (state == ConnectionState.disconnected) {
          _devices.remove(key);
          _deviceStreamController.add(_devices.values.toList());
        }
      });
      log.info('Quick-connect succeeded for $deviceId');
      return device;
    } catch (e, st) {
      log.warning('Quick-connect failed for $deviceId', e, st);
      try {
        await device.disconnect();
      } catch (_) {}
      try {
        await transport.dispose();
      } catch (_) {}
      return null;
    }
  }

  Future<BleDevice?> _findSystemDevice(String deviceId) async {
    try {
      final systemDevices = await UniversalBle.getSystemDevices(
        withServices: [],
      );
      for (final d in systemDevices) {
        if (normalizeBleDeviceId(d.deviceId) ==
            normalizeBleDeviceId(deviceId)) {
          return d;
        }
      }
    } catch (e, st) {
      log.fine('getSystemDevices failed during quick-connect', e, st);
    }
    return null;
  }

  Future<void> _connectWithRetry(Device device) async {
    final timeout = Platform.isLinux
        ? const Duration(seconds: 60)
        : const Duration(seconds: 10);
    try {
      await device.onConnect().timeout(timeout);
    } on BleConnectException catch (e) {
      log.info('Quick-connect GATT error ($e), retrying once after 1s');
      await Future.delayed(const Duration(seconds: 1));
      try {
        await device.disconnect();
      } catch (_) {}
      await device.onConnect().timeout(timeout);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _availabilitySubscription?.cancel();
    _availabilitySubscription = null;
    _cancelScanDurationWait();
    await stopDeviceWatch();
    for (final subscription in _connections.values) {
      await subscription.cancel();
    }
    _connections.clear();
    if (!_deviceStreamController.isClosed) {
      await _deviceStreamController.close();
    }
    if (!_adapterStateSubject.isClosed) await _adapterStateSubject.close();
    if (!_watchFailureController.isClosed) {
      await _watchFailureController.close();
    }
    if (!_watchStateSubject.isClosed) await _watchStateSubject.close();
  }
}
