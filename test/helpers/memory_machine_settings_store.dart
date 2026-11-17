import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';

class MemoryMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> values = {};
  final List<String> reads = [];
  final List<String> updates = [];
  final List<String> clears = [];
  final List<String> resetClears = [];
  void Function(String identity)? onRead;

  @override
  Future<MachineSettings?> read(String identity) async {
    reads.add(identity);
    onRead?.call(identity);
    if (identity.isEmpty) return null;
    final settings = values[identity];
    if (settings?.fanThreshold == null &&
        settings?.refillKitSetting == null &&
        settings?.flowCalibration == null &&
        settings?.refillLevel == null) {
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
    int? refillLevel,
  }) async {
    updates.add(identity);
    if (identity.isEmpty) return;
    final current = values[identity];
    values[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
      flowCalibration: flowCalibration ?? current?.flowCalibration,
      refillLevel: refillLevel ?? current?.refillLevel,
    );
  }

  @override
  Future<void> clear(String identity) async {
    clears.add(identity);
    if (identity.isEmpty) return;
    values.remove(identity);
  }

  @override
  Future<void> clearResetOverrides(String identity) async {
    resetClears.add(identity);
    if (identity.isEmpty) return;
    final current = values[identity];
    values.remove(identity);
    if (current?.flowCalibration != null || current?.refillLevel != null) {
      values[identity] = MachineSettings(
        flowCalibration: current?.flowCalibration,
        refillLevel: current?.refillLevel,
      );
    }
  }
}
