import 'dart:async';

import 'package:clock/clock.dart';
import 'package:reaprime/src/services/ble/ble_lifecycle_gate.dart';

import 'plugin_ble_matcher.dart';
import 'plugin_manifest.dart';

enum BleEvidenceSource { advertisement, system }

class BleAdvertisementEvidence {
  final String? name;
  final bool nameComplete;
  final List<String>? serviceUuids;
  final bool servicesComplete;
  final BleEvidenceSource source;
  final DateTime observedAt;

  BleAdvertisementEvidence({
    this.name,
    bool? nameComplete,
    List<String>? serviceUuids,
    bool? servicesComplete,
    this.source = BleEvidenceSource.advertisement,
    DateTime? observedAt,
  }) : nameComplete = nameComplete ?? source == BleEvidenceSource.advertisement,
       servicesComplete =
           servicesComplete ?? source == BleEvidenceSource.advertisement,
       serviceUuids = serviceUuids == null
           ? null
           : List.unmodifiable(serviceUuids),
       observedAt = observedAt ?? clock.now();

  bool get isComplete =>
      (name != null || nameComplete) &&
      serviceUuids != null &&
      servicesComplete;
}

class BleAdvertisementCache {
  int _generation = 0;
  final Map<String, BleAdvertisementEvidence> _observations = {};

  void beginGeneration(int generation) {
    _generation = generation;
    _observations.clear();
  }

  void record(
    String physicalId,
    int generation,
    BleAdvertisementEvidence evidence,
  ) {
    if (generation != _generation) return;
    final key = normalizeBleDeviceId(physicalId);
    final previous = _observations[key];
    if (previous != null &&
        ((previous.isComplete && !evidence.isComplete) ||
            (previous.isComplete == evidence.isComplete &&
                evidence.observedAt.isBefore(previous.observedAt)))) {
      return;
    }
    _observations[key] = evidence;
  }

  BleAdvertisementEvidence? get(String physicalId) =>
      _observations[normalizeBleDeviceId(physicalId)];
}

enum PluginBleOwnership { native, plugin, pending, conflict }

class PluginBleDriver {
  final String pluginId;
  final int generation;
  final PluginDriverDeclaration declaration;
  final String factoryHandle;

  const PluginBleDriver._(
    this.pluginId,
    this.generation,
    this.declaration,
    this.factoryHandle,
  );
}

class PluginBleDecision {
  final PluginBleOwnership kind;
  final List<PluginBleDriver> drivers;
  final int registryRevision;

  const PluginBleDecision._(this.kind, this.drivers, this.registryRevision);
}

class PluginBleClaim {
  final PluginBleDriver driver;
  final String physicalId;

  const PluginBleClaim._(this.driver, this.physicalId);

  String get publicId =>
      'plugin:${driver.pluginId}:${driver.declaration.id}:$physicalId';
}

class PluginBleRegistry {
  final int activeBindingLimit;
  final Map<String, PluginBleDriver> _drivers = {};
  final Map<String, PluginBleClaim> _claims = {};
  final StreamController<int> _changes = StreamController.broadcast();
  int _revision = 0;
  bool _closed = false;

  PluginBleRegistry({this.activeBindingLimit = 1}) {
    if (activeBindingLimit < 1) throw ArgumentError.value(activeBindingLimit);
  }

  Stream<int> get changes => _changes.stream;
  int get revision => _revision;
  int get activeBindingCount => _claims.length;
  bool get hasDrivers => _drivers.isNotEmpty;

  PluginBleDriver register({
    required String pluginId,
    required int generation,
    required PluginDriverDeclaration declaration,
    required Set<PluginPermissions> permissions,
    required String factoryHandle,
  }) {
    if (_closed ||
        !permissions.contains(PluginPermissions.transportBle) ||
        declaration.ble == null) {
      throw StateError(
        'BLE driver requires a live registry, declaration and transport.ble',
      );
    }
    if (_drivers.containsKey(pluginId)) {
      throw StateError('A plugin generation may bind at most one BLE driver');
    }
    final driver = PluginBleDriver._(
      pluginId,
      generation,
      declaration,
      factoryHandle,
    );
    _drivers[pluginId] = driver;
    _changed();
    return driver;
  }

  void removeGeneration(String pluginId, int generation) {
    if (_drivers[pluginId]?.generation != generation) return;
    _drivers.remove(pluginId);
    _changed();
  }

  bool isCurrent(PluginBleDriver driver) =>
      !_closed && identical(_drivers[driver.pluginId], driver);

  PluginBleDecision decide(BleAdvertisementEvidence evidence) {
    final matches = <PluginBleDriver>[];
    final unresolved = <PluginBleDriver>[];
    for (final driver in _drivers.values) {
      final result = driver.declaration.ble!.evaluate(
        name: evidence.name,
        nameComplete: evidence.nameComplete,
        serviceUuids: evidence.serviceUuids,
        servicesComplete: evidence.servicesComplete,
      );
      if (result == PluginBleMatch.match) matches.add(driver);
      if (result == PluginBleMatch.indeterminate) unresolved.add(driver);
    }
    final kind = matches.length > 1
        ? PluginBleOwnership.conflict
        : unresolved.isNotEmpty
        ? PluginBleOwnership.pending
        : matches.isNotEmpty
        ? PluginBleOwnership.plugin
        : PluginBleOwnership.native;
    return PluginBleDecision._(
      kind,
      List.unmodifiable([...matches, ...unresolved]),
      _revision,
    );
  }

  PluginBleClaim reserve(PluginBleDriver driver, String physicalId) {
    final key = normalizeBleDeviceId(physicalId);
    if (!isCurrent(driver)) throw StateError('Stale BLE driver');
    if (_claims.containsKey(key)) {
      throw StateError('Physical BLE device is owned');
    }
    if (_claims.values
            .where(
              (claim) =>
                  claim.driver.pluginId == driver.pluginId &&
                  claim.driver.generation == driver.generation,
            )
            .length >=
        activeBindingLimit) {
      throw StateError('Active BLE binding limit reached');
    }
    final claim = PluginBleClaim._(driver, key);
    _claims[key] = claim;
    return claim;
  }

  void release(PluginBleClaim claim) {
    if (identical(_claims[claim.physicalId], claim)) {
      _claims.remove(claim.physicalId);
    }
  }

  void _changed() {
    _revision++;
    if (!_changes.isClosed) _changes.add(_revision);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _drivers.clear();
    await _changes.close();
  }
}
