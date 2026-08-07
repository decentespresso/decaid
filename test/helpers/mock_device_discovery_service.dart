import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/ble/ble_discovery_service.dart';
import 'package:rxdart/rxdart.dart';

class MockDeviceDiscoveryService implements DeviceDiscoveryService {
  final _controller = BehaviorSubject<List<Device>>.seeded([]);
  final List<Device> _devices = [];
  int scanCallCount = 0;

  @override
  Stream<List<Device>> get devices => _controller.stream;

  void addDevice(Device device) {
    _devices.add(device);
    _controller.add(List.from(_devices));
  }

  void removeDevice(String deviceId) {
    _devices.removeWhere((d) => d.deviceId == deviceId);
    _controller.add(List.from(_devices));
  }

  void clear() {
    _devices.clear();
    _controller.add([]);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    scanCallCount++;
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  void dispose() {
    _controller.close();
  }
}

class MockBleDiscoveryService extends BleDiscoveryService {
  final _controller = BehaviorSubject<List<Device>>.seeded([]);
  final _adapterStateSubject = BehaviorSubject<AdapterState>.seeded(
    AdapterState.unknown,
  );
  final List<Device> _devices = [];

  @override
  Stream<List<Device>> get devices => _controller.stream;

  @override
  Stream<AdapterState> get adapterStateStream => _adapterStateSubject.stream;

  void setAdapterState(AdapterState state) {
    _adapterStateSubject.add(state);
  }

  void addDevice(Device device) {
    _devices.add(device);
    _controller.add(List.from(_devices));
  }

  void removeDevice(String deviceId) {
    _devices.removeWhere((d) => d.deviceId == deviceId);
    _controller.add(List.from(_devices));
  }

  void clear() {
    _devices.clear();
    _controller.add([]);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}

  @override
  void stopScan() {}

  void dispose() {
    _controller.close();
    _adapterStateSubject.close();
  }
}
