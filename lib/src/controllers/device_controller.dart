import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/device_watch.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/services/ble/ble_discovery_service.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';
import 'package:rxdart/rxdart.dart';

class DeviceController
    implements DeviceScanner, DeviceAttachNotifier, UsbAttachProbe {
  final List<DeviceDiscoveryService> _services;

  late Map<DeviceDiscoveryService, List<Device>> _devices;

  final _log = Logger("Device Controller");
  final BehaviorSubject<List<Device>> _deviceStream = BehaviorSubject.seeded(
    [],
  );

  final BehaviorSubject<bool> _scanningStream = BehaviorSubject.seeded(false);

  @override
  Stream<bool> get scanningStream => _scanningStream.stream;
  bool get isScanning => _scanningStream.value;

  final BehaviorSubject<AdapterState> _adapterStateStream =
      BehaviorSubject.seeded(AdapterState.unknown);

  @override
  Stream<AdapterState> get adapterStateStream => _adapterStateStream.stream;

  @override
  AdapterState get currentAdapterState => _adapterStateStream.value;

  final PublishSubject<DeviceAttachedEvent> _deviceAttachedStream =
      PublishSubject<DeviceAttachedEvent>();

  @override
  Stream<DeviceAttachedEvent> get deviceAttached =>
      _deviceAttachedStream.stream;

  final Expando<DeviceDiscoveryService> _attachOrigins = Expando();

  final List<StreamSubscription> _serviceSubscriptions = [];

  TelemetryService? _telemetryService;

  final Map<String, DateTime> _disconnectedAt = {};

  final Set<String> _previousDeviceIds = {};

  final Map<String, String> _deviceNamesById = {};

  set telemetryService(TelemetryService service) {
    _telemetryService = service;
  }

  @override
  Stream<List<Device>> get deviceStream => _deviceStream.stream;

  List<Device>? _flatDevicesCache;

  @override
  List<Device> get devices {
    final cached = _flatDevicesCache;
    if (cached != null) return cached;
    final out = <Device>[];
    for (final list in _devices.values) {
      out.addAll(list);
    }
    final frozen = List<Device>.unmodifiable(out);
    _flatDevicesCache = frozen;
    return frozen;
  }

  void _invalidateDevicesCache() {
    _flatDevicesCache = null;
  }

  DeviceController(this._services) {
    _devices = {};
  }

  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_disposed) return;
    if (_initialized) {
      _log.fine("Already initialized, skipping");
      return;
    }
    _initialized = true;

    for (var service in _services) {
      try {
        if (service case final DeviceAttachNotifier notifier) {
          final attachSub = notifier.deviceAttached.listen((event) {
            _attachOrigins[event] = service;
            _log.info("device attached on $service: $event");
            if (!_deviceAttachedStream.isClosed) {
              _deviceAttachedStream.add(event);
            }
          });
          _serviceSubscriptions.add(attachSub);
        }
        await service.initialize();
        if (_disposed) return;
        final subscription = service.devices.listen(
          (devices) => _serviceUpdate(service, devices),
        );
        _serviceSubscriptions.add(subscription);
        if (service is BleDiscoveryService) {
          final adapterSub = service.adapterStateStream.listen((state) {
            if (!_adapterStateStream.isClosed) {
              _adapterStateStream.add(state);
            }
          });
          _serviceSubscriptions.add(adapterSub);
        }
      } catch (e) {
        _log.warning("Service $service failed to init:", e);
      }
    }
  }

  Future<ScanResult>? _inFlightScan;

  @override
  Future<ScanResult> scanForDevices({ScanFilter? filter}) {
    return _inFlightScan ??= _runScan(filter).whenComplete(() {
      _inFlightScan = null;
    });
  }

  Future<ScanResult> _runScan(ScanFilter? filter) async {
    _scanningStream.add(true);
    final start = DateTime.now();
    try {
      final pairs = <({DeviceDiscoveryService service, Device device})>[];
      for (final entry in _devices.entries) {
        for (final device in entry.value) {
          pairs.add((service: entry.key, device: device));
        }
      }
      final staleFlags = await Future.wait(
        pairs.map((p) async {
          final state = await p.device.connectionState.first.timeout(
            ConnectionTimings.preScanDeviceCheckTimeout,
            onTimeout: () => ConnectionState.disconnected,
          );
          return state != ConnectionState.connected &&
              state != ConnectionState.connecting;
        }),
      );
      for (var i = 0; i < pairs.length; i++) {
        if (staleFlags[i]) {
          _devices[pairs[i].service]?.remove(pairs[i].device);
          _invalidateDevicesCache();
        }
      }
      _previousDeviceIds.clear();
      _previousDeviceIds.addAll(devices.map((d) => d.deviceId));
      _deviceNamesById
        ..clear()
        ..addEntries(devices.map((d) => MapEntry(d.deviceId, d.name)));
      _deviceStream.add(devices);

      final failures = <ServiceScanFailure>[];
      await Future.wait(
        _services.map((service) async {
          try {
            _log.fine("starting scan for $service");
            await service.scanForDevices(filter: filter);
          } catch (e, st) {
            _log.warning("Service $service failed to scan:", e, st);
            failures.add(
              ServiceScanFailure(
                serviceName: service.runtimeType.toString(),
                error: e,
                stackTrace: st,
              ),
            );
          }
        }),
      );

      _log.info("current devices: $devices");
      await Future.delayed(ConnectionTimings.postScanSettleDelay);
      return ScanResult(
        matchedDevices: List.unmodifiable(devices),
        failedServices: List.unmodifiable(failures),
        terminationReason: ScanTerminationReason.completed,
        duration: DateTime.now().difference(start),
      );
    } finally {
      if (!_scanningStream.isClosed) _scanningStream.add(false);
    }
  }

  @override
  void stopScan() {
    for (final service in _services) {
      service.stopScan();
    }
  }

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    for (final service in _services) {
      try {
        final device = await service.tryQuickConnect(remembered);
        if (device != null) return device;
      } catch (e, st) {
        _log.warning('tryQuickConnect failed for service $service', e, st);
      }
    }
    return null;
  }

  @override
  Future<AttachProbeResult> connectAttachedMachine(
    DeviceAttachedEvent event,
  ) async {
    final origin = _attachOrigins[event];
    if (origin case final UsbAttachProbe probe) {
      return probe.connectAttachedMachine(event);
    }
    return const AttachProbeUnavailable();
  }

  Iterable<DeviceWatchCapable> get _watchCapableServices => _services
      .whereType<DeviceWatchCapable>()
      .where((s) => s.supportsDeviceWatch);

  @override
  bool get supportsBackgroundWatch => _watchCapableServices.isNotEmpty;

  @override
  Future<void> startScaleWatch(DeviceWatchFilter filter) async {
    for (final service in _watchCapableServices) {
      await service.startDeviceWatch(filter);
    }
  }

  @override
  Future<void> stopScaleWatch() async {
    for (final service in _watchCapableServices) {
      try {
        await service.stopDeviceWatch();
      } catch (e, st) {
        _log.fine('stopDeviceWatch failed for $service', e, st);
      }
    }
  }

  @override
  Stream<void> get scaleWatchFailures {
    final streams = _services
        .whereType<DeviceWatchCapable>()
        .map((s) => s.deviceWatchFailures)
        .toList();
    if (streams.isEmpty) return const Stream.empty();
    if (streams.length == 1) return streams.single;
    return Rx.merge(streams);
  }

  void _serviceUpdate(DeviceDiscoveryService service, List<Device> devices) {
    _log.fine("$service update: $devices");
    _devices[service] = devices;
    _invalidateDevicesCache();

    final currentDevices = this.devices;
    final currentDeviceIds = currentDevices.map((d) => d.deviceId).toSet();
    for (final d in currentDevices) {
      _deviceNamesById[d.deviceId] = d.name;
    }

    if (!isScanning) {
      final disconnectedIds = _previousDeviceIds.difference(currentDeviceIds);
      for (var deviceId in disconnectedIds) {
        _disconnectedAt[deviceId] = DateTime.now();
        final name = _deviceNamesById[deviceId] ?? deviceId;
        _log.info("Device $name ($deviceId) disconnected");
      }

      for (var deviceId in currentDeviceIds) {
        if (_disconnectedAt.containsKey(deviceId)) {
          final disconnectedTime = _disconnectedAt[deviceId]!;
          final duration = DateTime.now().difference(disconnectedTime);
          final name = _deviceNamesById[deviceId] ?? deviceId;
          _log.info(
            "Device $name ($deviceId) reconnected after ${duration.inSeconds}s",
          );

          _telemetryService?.setCustomKey(
            'reconnection_duration_$deviceId',
            duration.inSeconds,
          );

          _disconnectedAt.remove(deviceId);
        }
      }

      final now = DateTime.now();
      _disconnectedAt.removeWhere((_, timestamp) {
        return now.difference(timestamp).inHours > 24;
      });
    }

    _previousDeviceIds.clear();
    _previousDeviceIds.addAll(currentDeviceIds);

    _deviceStream.add(this.devices);
    _updateDeviceCustomKeys();
  }

  void _updateDeviceCustomKeys() {
    if (_telemetryService == null) return;

    int machineCount = 0;
    int scaleCount = 0;
    int sensorCount = 0;

    for (var device in devices) {
      _telemetryService!.setCustomKey(
        'device_${device.deviceId}_type',
        device.type.name,
      );

      switch (device.type) {
        case DeviceType.machine:
          machineCount++;
          break;
        case DeviceType.scale:
          scaleCount++;
          break;
        case DeviceType.sensor:
          sensorCount++;
          break;
      }
    }

    _telemetryService!.setCustomKey('connected_machines', machineCount);
    _telemetryService!.setCustomKey('connected_scales', scaleCount);
    _telemetryService!.setCustomKey('connected_sensors', sensorCount);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (var subscription in _serviceSubscriptions) {
      subscription.cancel();
    }
    _serviceSubscriptions.clear();
    _deviceStream.close();
    _scanningStream.close();
    _adapterStateStream.close();
    _deviceAttachedStream.close();
  }
}
