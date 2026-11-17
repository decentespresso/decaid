import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';

abstract class BleDiscoveryService extends DeviceDiscoveryService {
  Stream<AdapterState> get adapterStateStream;

  Future<Map<String, Object?>> diagnostics() async => const {};
}
