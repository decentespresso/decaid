import 'dart:async';

import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:rxdart/rxdart.dart';

class MockDeviceScanner implements DeviceScanner {
  final _deviceSubject = BehaviorSubject<List<Device>>.seeded([]);
  final _scanningSubject = BehaviorSubject<bool>.seeded(false);
  final _adapterStateSubject = BehaviorSubject<AdapterState>.seeded(
    AdapterState.unknown,
  );
  final List<Device> _devices = [];

  int stopScanCallCount = 0;

  int scanCallCount = 0;

  Completer<void>? scanCompleter;
  final List<Completer<void>> queuedScanCompleters = [];
  final List<List<Device>> queuedScanResults = [];

  Object? failNextScanWith;

  bool supportsWatch = false;

  DeviceWatchFilter? lastWatchFilter;

  int startWatchCallCount = 0;

  int stopWatchCallCount = 0;

  bool watchActive = false;

  Object? failNextWatchWith;

  final _watchFailuresSubject = PublishSubject<void>();

  void emitWatchFailure() {
    watchActive = false;
    _watchFailuresSubject.add(null);
  }

  @override
  Stream<List<Device>> get deviceStream => _deviceSubject.stream;

  @override
  Stream<bool> get scanningStream => _scanningSubject.stream;

  @override
  Stream<AdapterState> get adapterStateStream => _adapterStateSubject.stream;

  @override
  AdapterState get currentAdapterState => _adapterStateSubject.value;

  @override
  List<Device> get devices => List.from(_devices);

  void mockAdapterState(AdapterState state) {
    _adapterStateSubject.add(state);
  }

  void addDevice(Device device) {
    _devices.add(device);
    _deviceSubject.add(List.from(_devices));
  }

  void removeDevice(String deviceId) {
    _devices.removeWhere((d) => d.deviceId == deviceId);
    _deviceSubject.add(List.from(_devices));
  }

  void reset() {
    _devices.clear();
    _deviceSubject.add([]);
    stopScanCallCount = 0;
    scanCallCount = 0;
    scanCompleter = null;
    queuedScanCompleters.clear();
    queuedScanResults.clear();
    failNextScanWith = null;
    quickConnectResult = null;
    quickConnectCallCount = 0;
  }

  void completeScan() {
    scanCompleter?.complete();
    scanCompleter = null;
    _scanningSubject.add(false);
  }

  @override
  Future<ScanResult> scanForDevices({ScanFilter? filter}) async {
    if (failNextScanWith != null) {
      final e = failNextScanWith;
      failNextScanWith = null;
      throw e!;
    }
    scanCallCount++;
    final start = DateTime.now();
    final scanDevices = queuedScanResults.isNotEmpty
        ? queuedScanResults.removeAt(0)
        : _devices;
    _scanningSubject.add(true);
    _deviceSubject.add(List.from(scanDevices));
    final completer = queuedScanCompleters.isNotEmpty
        ? queuedScanCompleters.removeAt(0)
        : scanCompleter;
    if (completer != null) {
      await completer.future;
    } else {
      await Future.delayed(Duration.zero);
      _scanningSubject.add(false);
    }
    return ScanResult(
      matchedDevices: List.unmodifiable(scanDevices),
      failedServices: const [],
      terminationReason: ScanTerminationReason.completed,
      duration: DateTime.now().difference(start),
    );
  }

  @override
  void stopScan() {
    stopScanCallCount++;
  }

  Device? quickConnectResult;

  int quickConnectCallCount = 0;

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    quickConnectCallCount++;
    return quickConnectResult;
  }

  @override
  bool get supportsBackgroundWatch => supportsWatch;

  @override
  Future<void> startScaleWatch(DeviceWatchFilter filter) async {
    if (failNextWatchWith != null) {
      final e = failNextWatchWith;
      failNextWatchWith = null;
      throw e!;
    }
    startWatchCallCount++;
    lastWatchFilter = filter;
    watchActive = true;
  }

  @override
  Future<void> stopScaleWatch() async {
    stopWatchCallCount++;
    watchActive = false;
  }

  @override
  Stream<void> get scaleWatchFailures => _watchFailuresSubject.stream;

  void dispose() {
    _watchFailuresSubject.close();
    _deviceSubject.close();
    _scanningSubject.close();
    _adapterStateSubject.close();
  }
}
