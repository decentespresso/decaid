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
import 'package:reaprime/src/services/ble/ble_admission_transport.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_ble_service.dart';
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
    PluginBleService Function()? pluginBleService,
    this.scanDuration = const Duration(seconds: 15),
  }) : _watchSupportGate = watchSupportGate ?? (() => Platform.isAndroid),
       requestLargeMtuNonAndroid = requestLargeMtuNonAndroid ?? (() => false),
       _transportFactory = transportFactory ?? _defaultTransportFactory,
       _pluginBleService = pluginBleService;

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
  final Duration scanDuration;
  final BleLifecycleGate _lifecycleGate = BleLifecycleGate();
  final PluginBleService Function()? _pluginBleService;
  PluginBleService? get _plugins => _pluginBleService?.call();
  final BleAdvertisementCache _bleEvidence = BleAdvertisementCache();
  final Map<String, BleDevice> _bleObservations = {};
  final Map<String, PluginBleDecision> _pluginOwnership = {};
  final Set<String> _dirtyObservations = {};
  StreamSubscription<int>? _registrySubscription;
  Future<void> _registryReconciliation = Future.value();
  bool _watchIncludesPluginDrivers = false;

  void _beginBleEvidence() {
    _bleEvidence.beginGeneration(_scanGeneration);
    _bleObservations.clear();
    _pluginOwnership.clear();
  }

  bool _nativeEligible(String id) {
    final plugins = _plugins;
    if (_adapterStateSubject.value != AdapterState.poweredOn) return false;
    if (_disposed || plugins?.registry.acceptingConnections == false) {
      return false;
    }
    if (plugins == null) return true;
    final evidence =
        _bleEvidence.get(id) ??
        BleAdvertisementEvidence(source: BleEvidenceSource.system);
    return plugins.registry.decide(evidence).kind == PluginBleOwnership.native;
  }

  bool _decisionIsCurrent(
    String id,
    PluginBleDecision? decision,
    int generation,
  ) {
    if (_disposed || generation != _scanGeneration) return false;
    final plugins = _plugins;
    if (plugins == null) return true;
    final evidence = _bleEvidence.get(id);
    if (evidence == null ||
        decision?.registryRevision != plugins.registry.revision) {
      return false;
    }
    final current = plugins.registry.decide(evidence);
    return current.kind == decision!.kind &&
        (current.kind != PluginBleOwnership.plugin ||
            identical(current.drivers.single, decision.drivers.single));
  }

  BLETransport _nativeTransport(BleDevice device) {
    final transport = _createTransport(device);
    final plugins = _plugins;
    if (plugins == null) return transport;
    final revision = plugins.registry.revision;
    return BleAdmissionTransport(
      transport: transport,
      reserve: () {
        if (revision != plugins.registry.revision ||
            !_nativeEligible(device.deviceId)) {
          throw StateError('Native BLE candidate ownership changed');
        }
        return plugins.registry.reserveNative(device.deviceId);
      },
      release: (claim) =>
          plugins.registry.releaseNative(device.deviceId, claim),
    );
  }

  Future<void> _reconcilePluginCandidates() async {
    if (_disposed) return;
    final includePlugins = _plugins?.registry.hasDrivers == true;
    if (_watchScanActive &&
        _watchRequested?.namePrefix != null &&
        _watchIncludesPluginDrivers != includePlugins) {
      await _deactivateWatchScan(
        stopOsScan: true,
        context: 'plugin registry change',
      );
      if (_disposed) return;
      await _restartWatchOrReportFailure('plugin registry change');
    }
    for (final entry in _devices.entries.toList()) {
      if (_bleObservations.containsKey(entry.key)) continue;
      final state = await _cachedConnectionState(entry.value);
      if (state == ConnectionState.discovered ||
          state == ConnectionState.disconnected) {
        if (_plugins?.registry.isClaimed(entry.key) == true) continue;
        if (await _evictCachedDevice(entry.key, entry.value)) {
          await _plugins?.discardInactive(entry.value);
        }
      }
    }
    for (final entry in _bleObservations.entries.toList()) {
      await _deviceScanned(entry.value, recordEvidence: false);
    }
  }

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
    await _plugins?.registry.ready;
    if (_disposed || _plugins?.registry.acceptingConnections == false) return;
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
    _beginBleEvidence();
    final generation = _scanGeneration;

    _watchScanSub = UniversalBle.scanStream.listen((result) async {
      await _deviceScanned(result, generation: generation);
    });

    final namePrefix = filter.namePrefix;
    _watchIncludesPluginDrivers = _plugins?.registry.hasDrivers == true;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withNamePrefix: namePrefix != null && !_watchIncludesPluginDrivers
              ? [namePrefix]
              : [],
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
      'pluginOwnership': {
        for (final entry in _pluginOwnership.entries)
          entry.key: {
            'decision': entry.value.kind.name,
            'registryRevision': entry.value.registryRevision,
            'drivers': entry.value.drivers
                .map((driver) => '${driver.pluginId}:${driver.declaration.id}')
                .toList(),
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
    _registrySubscription ??= _plugins?.registry.changes.listen((_) {
      if (_disposed) return;
      _registryReconciliation = _registryReconciliation
          .then((_) => _reconcilePluginCandidates())
          .catchError((Object error, StackTrace stack) {
            log.warning('BLE candidate reconciliation failed', error, stack);
          });
    });
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
      if (mapped != AdapterState.poweredOn && mapped != AdapterState.unknown) {
        _plugins?.revokeSessions();
      }
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
    await _plugins?.registry.ready;
    if (_disposed || _plugins?.registry.acceptingConnections == false) return;
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
    _beginBleEvidence();
    final generation = _scanGeneration;
    _scanStopError = null;
    StreamSubscription<BleDevice>? sub;

    try {
      log.fine("Clearing stale connections");
      _currentlyScanning.clear();

      sub = UniversalBle.scanStream.listen((result) async {
        log.finest(
          "Found: ${result.deviceId}: ${result.name}, adv: ${result.services}",
        );
        await _deviceScanned(result, generation: generation);
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
          await _deviceScanned(
            d,
            source: BleEvidenceSource.system,
            generation: generation,
          );
        }
      } catch (e, st) {
        log.fine('System device check failed', e, st);
      }

      await _waitForScanDuration(scanDuration);
    } finally {
      await sub?.cancel();
      _cancelScanDurationWait();
      for (final entry in _pluginOwnership.entries) {
        if (entry.value.kind == PluginBleOwnership.pending ||
            entry.value.kind == PluginBleOwnership.conflict) {
          log.warning(
            'BLE ownership ${entry.value.kind.name} at scan deadline: ${entry.key}',
          );
        }
      }
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

  Future<ConnectionState?> _cachedConnectionState(Device device) async {
    try {
      return await device.connectionState.first.timeout(
        const Duration(seconds: 2),
      );
    } catch (e, st) {
      log.fine(
        'Cached connection-state check failed for ${device.deviceId}',
        e,
        st,
      );
      return null;
    }
  }

  Future<bool> _evictCachedDevice(String deviceId, Device existing) async {
    if (!identical(_devices[deviceId], existing)) return false;
    _devices.remove(deviceId);
    await _connections.remove(deviceId)?.cancel();
    if (_devices.containsKey(deviceId)) return false;
    _deviceStreamController.add(_devices.values.toList());
    return true;
  }

  Future<void> _adoptCachedDevice(String deviceId, Device device) async {
    _devices[deviceId] = device;
    _deviceStreamController.add(_devices.values.toList());
    await _connections.remove(deviceId)?.cancel();
    if (!identical(_devices[deviceId], device)) return;
    _connections[deviceId] = device.connectionState.listen((state) {
      if (state != ConnectionState.disconnected ||
          !identical(_devices[deviceId], device)) {
        return;
      }
      _devices.remove(deviceId);
      _deviceStreamController.add(_devices.values.toList());
    });
  }

  Future<void> _deviceScanned(
    BleDevice device, {
    BleEvidenceSource source = BleEvidenceSource.advertisement,
    int? generation,
    bool recordEvidence = true,
  }) async {
    final observedGeneration = generation ?? _scanGeneration;
    if (_disposed || observedGeneration != _scanGeneration) return;
    final deviceId = normalizeBleDeviceId(device.deviceId);
    _bleObservations[deviceId] = device;
    if (recordEvidence) {
      _bleEvidence.record(
        deviceId,
        observedGeneration,
        BleAdvertisementEvidence(
          name: device.name,
          serviceUuids: device.services,
          source: source,
          servicesComplete: source == BleEvidenceSource.advertisement,
        ),
      );
      _recordAdvertisement(deviceId, device.name);
    }
    if (_currentlyScanning.contains(deviceId)) {
      if (_plugins != null) _dirtyObservations.add(deviceId);
      return;
    }
    _currentlyScanning.add(deviceId);

    try {
      do {
        _dirtyObservations.remove(deviceId);
        await _processBleObservation(deviceId, observedGeneration);
      } while (observedGeneration == _scanGeneration &&
          _dirtyObservations.remove(deviceId));
    } catch (error, stack) {
      log.warning('BLE candidate failed for $deviceId', error, stack);
    } finally {
      _currentlyScanning.remove(deviceId);
      if (observedGeneration != _scanGeneration &&
          _dirtyObservations.remove(deviceId)) {
        final current = _bleObservations[deviceId];
        if (current != null) {
          await _deviceScanned(current, recordEvidence: false);
        }
      }
    }
  }

  Future<void> _processBleObservation(String deviceId, int generation) async {
    final device = _bleObservations[deviceId];
    if (device == null || generation != _scanGeneration || _disposed) return;
    final evidence = _bleEvidence.get(deviceId)!;
    final plugins = _plugins;
    final previousDecision = _pluginOwnership[deviceId];
    final decision = plugins?.registry.decide(evidence);
    if (decision != null) _pluginOwnership[deviceId] = decision;

    try {
      final name = evidence.name ?? '';

      final existing = _devices[deviceId];
      if (existing != null) {
        final state = await _cachedConnectionState(existing);
        if (!identical(_devices[deviceId], existing)) return;
        if (plugins?.registry.isClaimed(deviceId) == true) return;
        if (state == null ||
            state == ConnectionState.connecting ||
            state == ConnectionState.disconnecting) {
          return;
        }
        if (state == ConnectionState.discovered && plugins == null) return;
        if (state == ConnectionState.connected) {
          var nativeLink = await _nativeLinkState(existing.deviceId);
          if (nativeLink == null ||
              nativeLink == BleConnectionState.connected ||
              nativeLink == BleConnectionState.connecting) {
            return;
          }
          if (!identical(_devices[deviceId], existing)) return;
          final latestState = await _cachedConnectionState(existing);
          if (latestState == null ||
              latestState == ConnectionState.discovered ||
              latestState == ConnectionState.connecting ||
              latestState == ConnectionState.disconnecting) {
            return;
          }
          nativeLink = await _nativeLinkState(existing.deviceId);
          if (nativeLink == null ||
              nativeLink == BleConnectionState.connected ||
              nativeLink == BleConnectionState.connecting) {
            return;
          }
          if (!identical(_devices[deviceId], existing)) return;
          final finalState = await _cachedConnectionState(existing);
          if (finalState == null ||
              finalState == ConnectionState.discovered ||
              finalState == ConnectionState.connecting ||
              finalState == ConnectionState.disconnecting) {
            return;
          }
          if (!identical(_devices[deviceId], existing)) return;
          log.warning(
            'Replacing cached connected device $deviceId; '
            'native link is ${nativeLink.name}',
          );
        }
        if (state == ConnectionState.discovered &&
            decision?.kind == PluginBleOwnership.plugin &&
            plugins!.matchesCandidate(existing, decision!.drivers.single)) {
          return;
        }
        if (state == ConnectionState.discovered &&
            decision?.kind == PluginBleOwnership.native &&
            previousDecision?.registryRevision == decision!.registryRevision &&
            existing.implementation ==
                DeviceMatcher.implementationForName(name)) {
          return;
        }
        if (plugins?.registry.isClaimed(deviceId) == true) return;
        if (!await _evictCachedDevice(deviceId, existing)) return;
        await plugins?.discardInactive(existing);
      }

      if (decision?.kind == PluginBleOwnership.pending ||
          decision?.kind == PluginBleOwnership.conflict) {
        return;
      }
      if (decision?.kind != PluginBleOwnership.plugin && name.isEmpty) return;
      if (!_decisionIsCurrent(deviceId, decision, generation)) {
        _dirtyObservations.add(deviceId);
        return;
      }
      final matchedDevice = await _candidate(
        deviceId,
        () => decision?.kind == PluginBleOwnership.plugin
            ? plugins!.createCandidate(
                driver: decision!.drivers.single,
                physicalId: deviceId,
                evidence: evidence,
                createTransport: () => _createTransport(device),
                admit: () {
                  if (_disposed ||
                      _adapterStateSubject.value != AdapterState.poweredOn) {
                    return false;
                  }
                  final current = _bleEvidence.get(deviceId);
                  if (current == null) return false;
                  final owner = plugins.registry.decide(current);
                  return owner.kind == PluginBleOwnership.plugin &&
                      identical(owner.drivers.single, decision.drivers.single);
                },
              )
            : DeviceMatcher.match(
                transport: _nativeTransport(device),
                advertisedName: name,
              ),
      );

      if (matchedDevice != null && !_devices.containsKey(deviceId)) {
        if (!_decisionIsCurrent(deviceId, decision, generation)) {
          _dirtyObservations.add(deviceId);
          await plugins?.discardInactive(matchedDevice);
          return;
        }
        await _adoptCachedDevice(deviceId, matchedDevice);
        log.fine("found new device: ${device.name}");
      }
    } catch (error, stack) {
      log.warning(
        'BLE observation processing failed for $deviceId',
        error,
        stack,
      );
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
    await _plugins?.registry.ready;
    if (_disposed || remembered.implementation == DeviceImplementation.plugin) {
      return null;
    }
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

    if (!_nativeEligible(deviceId) ||
        _plugins?.registry.isClaimed(deviceId) == true) {
      return null;
    }
    final transport = _nativeTransport(bleDevice);
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
      await _adoptCachedDevice(key, device);
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
    await _registrySubscription?.cancel();
    _registrySubscription = null;
    await _registryReconciliation;
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
