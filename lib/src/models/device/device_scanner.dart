import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/scan_result.dart';
import 'package:reaprime/src/models/device/watch_filter.dart';
import 'package:reaprime/src/models/device/watch_state.dart';

export 'package:reaprime/src/models/device/scan_result.dart';

abstract class DeviceScanner {
  Stream<List<Device>> get deviceStream;
  Stream<bool> get scanningStream;
  bool get isScanning;
  List<Device> get devices;

  Future<ScanResult> scanForDevices({ScanFilter? filter});

  void stopScan();

  Stream<AdapterState> get adapterStateStream;

  AdapterState get currentAdapterState;

  Future<Device?> tryQuickConnect(RememberedDevice remembered);

  bool get supportsBackgroundWatch;

  Stream<DeviceWatchState> get scaleWatchState;

  Future<DeviceWatchStartResult> startScaleWatch(DeviceWatchFilter filter);

  Future<void> stopScaleWatch();

  Stream<void> get scaleWatchFailures;
}
