import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

enum DeviceType { machine, scale, sensor }

abstract class Device {
  String get deviceId;
  String get name;
  DeviceType get type;

  /// Which concrete device class this is. Used by [DeviceFactory] to
  /// reconstruct a device from persisted metadata without name-matching.
  DeviceImplementation get implementation;

  /// The transport type this device communicates over. Delegates to the
  /// underlying transport.
  TransportType get transportType;

  Future<void> onConnect();

  Future<void> disconnect();

  Stream<ConnectionState> get connectionState;
}

enum ConnectionState {
  discovered,
  connecting,
  connected,
  disconnecting,
  disconnected,
}

abstract class DeviceDiscoveryService {
  Stream<List<Device>> get devices;

  Future<void> initialize() async {
    throw "Not implemented yet";
  }

  Future<void> scanForDevices({ScanFilter? filter}) async {
    throw "Not implemented yet";
  }

  /// Stop an in-progress scan early.
  ///
  /// Default is a no-op. Implementations should cancel any pending scan
  /// timers and stop the underlying scan (e.g., BLE stopScan).
  void stopScan() {}

  /// Attempt a direct connection to a remembered device without scanning.
  /// Returns a connected-and-ready [Device] on success, or null to signal
  /// the caller to fall back to a full scan.
  ///
  /// Default implementation returns null (scan fallback). Transport-specific
  /// discovery services override this with the direct-connect path.
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    return null;
  }
}
