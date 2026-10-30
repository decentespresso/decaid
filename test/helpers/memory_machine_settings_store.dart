import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';

class MemoryMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> values = {};
  final List<String> reads = [];
  final List<String> updates = [];
  final List<String> clears = [];
  final List<String> clearsExceptFlowCalibration = [];
  void Function(String identity)? onRead;

  @override
  Future<MachineSettings?> read(String identity) async {
    reads.add(identity);
    onRead?.call(identity);
    if (identity.isEmpty) return null;
    final settings = values[identity];
    if (settings?.fanThreshold == null &&
        settings?.refillKitSetting == null &&
        settings?.flowCalibration == null) {
      return null;
    }
    return settings;
  }

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  }) async {
    updates.add(identity);
    if (identity.isEmpty) return;
    final current = values[identity];
    values[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
      flowCalibration: flowCalibration ?? current?.flowCalibration,
    );
  }

  @override
  Future<void> clear(String identity) async {
    clears.add(identity);
    if (identity.isEmpty) return;
    values.remove(identity);
  }

  @override
  Future<void> clearExceptFlowCalibration(String identity) async {
    clearsExceptFlowCalibration.add(identity);
    if (identity.isEmpty) return;
    final current = values[identity];
    values.remove(identity);
    if (current?.flowCalibration != null) {
      values[identity] = MachineSettings(
        flowCalibration: current?.flowCalibration,
      );
    }
  }
}
