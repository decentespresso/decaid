import 'dart:convert';

import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MachineSettings {
  const MachineSettings({
    this.fanThreshold,
    this.refillKitSetting,
    this.flowCalibration,
  });

  final int? fanThreshold;
  final De1RefillKitSettings? refillKitSetting;
  final double? flowCalibration;
}

abstract interface class MachineSettingsStore {
  Future<MachineSettings?> read(String identity);

  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  });

  Future<void> clear(String identity);

  /// Clears fan and refill entries for [identity] while preserving the saved
  /// flow-calibration override. A generic machine-settings reset uses this so
  /// a live multiplier keeps its saved intent across the reset.
  Future<void> clearExceptFlowCalibration(String identity);
}

class NoopMachineSettingsStore implements MachineSettingsStore {
  const NoopMachineSettingsStore();

  @override
  Future<MachineSettings?> read(String identity) async => null;

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  }) async {}

  @override
  Future<void> clear(String identity) async {}

  @override
  Future<void> clearExceptFlowCalibration(String identity) async {}
}

class SharedPreferencesMachineSettingsStore implements MachineSettingsStore {
  static const _key = 'machineSettings';
  static const _maxMachines = 32;

  final SharedPreferences? _preferences;

  SharedPreferencesMachineSettingsStore({SharedPreferences? preferences})
    : _preferences = preferences;

  @override
  Future<MachineSettings?> read(String identity) async {
    if (identity.isEmpty) return null;
    final entries = await _readEntries();
    final entry = entries[identity];
    if (entry is! Map) return null;
    return _decodeSettings(entry);
  }

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  }) async {
    if (identity.isEmpty) return;
    final entries = await _readEntries();
    final existing = entries[identity] is Map
        ? Map<String, dynamic>.from(entries[identity] as Map)
        : <String, dynamic>{};
    if (fanThreshold != null) existing['fan'] = fanThreshold;
    if (refillKitSetting != null) existing['refillKit'] = refillKitSetting.hex;
    if (flowCalibration != null) existing['flowCalibration'] = flowCalibration;
    existing['updatedAt'] = _nextUpdatedAt(entries);
    entries.remove(identity);
    entries[identity] = existing;
    while (entries.length > _maxMachines) {
      final oldest = entries.entries.reduce(
        (a, b) => _updatedAt(a.value) <= _updatedAt(b.value) ? a : b,
      );
      entries.remove(oldest.key);
    }
    await _writeEntries(entries);
  }

  @override
  Future<void> clear(String identity) async {
    if (identity.isEmpty) return;
    final entries = await _readEntries();
    if (entries.remove(identity) != null) {
      await _writeEntries(entries);
    }
  }

  @override
  Future<void> clearExceptFlowCalibration(String identity) async {
    if (identity.isEmpty) return;
    final entries = await _readEntries();
    final entry = entries[identity];
    if (entry is! Map) return;
    final flow = entry['flowCalibration'];
    entries.remove(identity);
    if (flow is num && flow.isFinite) {
      entries[identity] = {
        'flowCalibration': flow.toDouble(),
        'updatedAt': _updatedAt(entry),
      };
    }
    await _writeEntries(entries);
  }

  Future<Map<String, dynamic>> _readEntries() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, dynamic>(
        (key, value) => MapEntry(key.toString(), value),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeEntries(Map<String, dynamic> entries) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    await preferences.setString(_key, jsonEncode(entries));
  }

  MachineSettings? _decodeSettings(Map entry) {
    final fan = entry['fan'];
    final refill = entry['refillKit'];
    final flow = entry['flowCalibration'];
    final fanThreshold = fan is num ? fan.toInt() : null;
    final refillKitSetting = refill is num
        ? De1RefillKitSettings.values
              .where((setting) => setting.hex == refill.toInt())
              .firstOrNull
        : null;
    final flowCalibration = flow is num && flow.isFinite
        ? flow.toDouble()
        : null;
    if (fanThreshold == null &&
        refillKitSetting == null &&
        flowCalibration == null) {
      return null;
    }
    return MachineSettings(
      fanThreshold: fanThreshold,
      refillKitSetting: refillKitSetting,
      flowCalibration: flowCalibration,
    );
  }

  int _updatedAt(dynamic entry) => entry is Map && entry['updatedAt'] is num
      ? (entry['updatedAt'] as num).toInt()
      : 0;

  int _nextUpdatedAt(Map<String, dynamic> entries) {
    return entries.values.fold<int>(0, (max, entry) {
          final updatedAt = _updatedAt(entry);
          return updatedAt > max ? updatedAt : max;
        }) +
        1;
  }
}

extension on Iterable<De1RefillKitSettings> {
  De1RefillKitSettings? get firstOrNull {
    for (final value in this) {
      return value;
    }
    return null;
  }
}
