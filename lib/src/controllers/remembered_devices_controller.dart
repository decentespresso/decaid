import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/device_matcher.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:rxdart/subjects.dart';

class RememberedDevicesController {
  final SettingsService _settings;
  final Stream<RememberedDevice?> _machineConnections;
  final Stream<RememberedDevice?> _scaleConnections;
  final _log = Logger('RememberedDevices');

  final Map<String, RememberedDevice> _registry = {};
  final BehaviorSubject<List<RememberedDevice>> _changes =
      BehaviorSubject.seeded(const []);
  final List<StreamSubscription> _subs = [];
  bool _initialized = false;

  bool _migrationPersistPending = false;

  RememberedDevicesController({
    required Stream<RememberedDevice?> machineConnections,
    required Stream<RememberedDevice?> scaleConnections,
    required SettingsService settings,
  }) : _machineConnections = machineConnections,
       _scaleConnections = scaleConnections,
       _settings = settings;

  List<RememberedDevice> get remembered => List.unmodifiable(_registry.values);

  Stream<List<RememberedDevice>> get changes => _changes.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final raw = await _settings.rememberedDevices();
    final loaded = RememberedDevice.decodeList(raw);

    final stored = RememberedDevice.storedCount(raw);
    final recordsDropped = stored > loaded.length;
    final hasOpaqueRecords = recordsDropped || _scanForOpaqueRecords(raw);
    if (recordsDropped) {
      _log.warning(
        'dropped ${stored - loaded.length} unreadable remembered record(s)',
      );
    }

    var migrated = 0;
    for (final d in loaded) {
      if (d.implementation == null || d.transportType == null) {
        _registry[d.id] = d.migrate(DeviceMatcher.implementationForName);
        migrated++;
      } else {
        _registry[d.id] = d;
      }
    }
    _log.info(
      'loaded ${_registry.length} remembered device(s)'
      '${migrated > 0 ? ", migrated $migrated old record(s)" : ""}',
    );
    if (migrated > 0 && !hasOpaqueRecords) {
      try {
        await _persist();
      } catch (_) {
        _migrationPersistPending = true;
        _log.warning(
          'migration persist failed — will retry on next live-device reconnect',
        );
      }
    }
    _emit();
    _subs.add(
      _machineConnections.listen(
        (d) {
          if (d != null) unawaited(_rememberFromStream(d));
        },
        onError: (e, st) =>
            _log.severe('machine connection stream error', e, st),
      ),
    );
    _subs.add(
      _scaleConnections.listen(
        (d) {
          if (d != null) unawaited(_rememberFromStream(d));
        },
        onError: (e, st) => _log.severe('scale connection stream error', e, st),
      ),
    );
  }

  Future<void> _rememberFromStream(RememberedDevice device) async {
    try {
      await _remember(device);
    } catch (_) {}
  }

  Future<void> _remember(RememberedDevice device) async {
    final existing = _registry[device.id];
    if (existing != null && existing.sameMetadata(device)) {
      if (_migrationPersistPending) {
        try {
          await _persist();
          _migrationPersistPending = false;
        } catch (_) {}
      }
      return;
    }
    _registry[device.id] = device;
    try {
      await _persist();
    } catch (_) {
      if (existing != null) {
        _registry[device.id] = existing;
      } else {
        _registry.remove(device.id);
      }
      rethrow;
    }
    _log.info('remembering $device');
    _emit();
  }

  Future<void> forget(String id) async {
    final removed = _registry.remove(id);
    if (removed == null) return;
    try {
      await _persist();
    } catch (_) {
      _registry[id] = removed;
      rethrow;
    }
    _log.info('forgot $id');
    _emit();
  }

  Future<void> _persist() async {
    try {
      await _settings.setRememberedDevices(
        RememberedDevice.encodeList(_registry.values),
      );
    } catch (e, st) {
      _log.severe('failed to persist remembered devices', e, st);
      rethrow;
    }
  }

  static bool _scanForOpaqueRecords(String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return false;
    }
    if (decoded is! List) return false;
    final knownTypes = DeviceType.values.map((t) => t.name).toSet();
    final knownImpls = DeviceImplementation.values.map((i) => i.name).toSet();
    final knownTTs = TransportType.values.map((t) => t.name).toSet();
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final typeName = entry['type'];
      if (typeName is String && !knownTypes.contains(typeName)) return true;
      final implName = entry['implementation'];
      if (implName is String && !knownImpls.contains(implName)) return true;
      final ttName = entry['transportType'];
      if (ttName is String && !knownTTs.contains(ttName)) return true;
    }
    return false;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(remembered);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    if (!_changes.isClosed) await _changes.close();
  }
}
