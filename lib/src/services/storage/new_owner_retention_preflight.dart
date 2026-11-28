import 'dart:convert';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/wifi_scale_id.dart';
import 'package:reaprime/src/models/device/scale_preference.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

const String _defaultSkinId = 'streamline.js';
const String _legacyDefaultSkinId = 'streamline_project-main';

String normalizePersistedDefaultSkinId(String? stored) =>
    stored == null || stored == _legacyDefaultSkinId ? _defaultSkinId : stored;

enum NewOwnerRetentionRejection {
  settingsReadFailed,
  rememberedDevicesUnreadable,
  preferredMachineUnresolved,
  preferredMachineAmbiguous,
  preferredMachineMetadataIncomplete,
  preferredMachineMetadataInconsistent,
  preferredScaleUnresolved,
  preferredScaleAmbiguous,
  preferredScaleMetadataIncomplete,
  preferredScaleMetadataInconsistent,
  preferredScalePluginUnsupported,
  preferredScaleManualEndpointUnreadable,
  preferredScaleManualEndpointMalformed,
  preferredScaleManualEndpointAmbiguous,
  legacySkinSelectionUnreadable,
  skinSelectionDisagreement,
  skinServingSelectionUnavailable,
  skinServingSelectionUnreadable,
  runtimeSkinSelectionUnsupported,
  skinIdInvalid,
  skinPackageMissing,
  skinPackageEscaped,
  skinPackageAmbiguous,
  skinPackageUnreadable,
}

final class RetainedDeviceMetadata {
  const RetainedDeviceMetadata({
    required this.implementation,
    required this.transportType,
  });

  final DeviceImplementation implementation;
  final TransportType transportType;
}

/// Observation of the selected installed managed skin package, expressed
/// relative to the managed skin root the owner scanned. It is not a package
/// identity, provenance record or escrow handle; a future guarded operation
/// must resolve the selected skin again through the owner before acting.
final class RetainedManagedSkinPackage {
  const RetainedManagedSkinPackage({
    required this.skinId,
    required this.directoryName,
  });

  final String skinId;
  final String directoryName;
}

final class _ReconnectSupport {
  const _ReconnectSupport(this.roles, this.transports);

  final Set<DeviceType> roles;
  final Set<TransportType> transports;
}

const Map<DeviceImplementation, _ReconnectSupport> _reconnectSupport = {
  DeviceImplementation.unifiedDe1: _ReconnectSupport(
    {DeviceType.machine},
    {TransportType.ble, TransportType.serial},
  ),
  DeviceImplementation.bengle: _ReconnectSupport(
    {DeviceType.machine, DeviceType.scale},
    {TransportType.ble, TransportType.serial},
  ),
  DeviceImplementation.decentScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.hdsSerial: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.serial},
  ),
  DeviceImplementation.hdsWifi: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.wifi},
  ),
  DeviceImplementation.skale2: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.acaiaScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.felicitaArc: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.blackCoffeeScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.bookooScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.eurekaScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.smartChefScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.variaAkuScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.difluidScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.hiroiaScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.atomheartScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.weighMasterScale: _ReconnectSupport(
    {DeviceType.scale},
    {TransportType.ble},
  ),
  DeviceImplementation.decentTemp: _ReconnectSupport(
    {DeviceType.sensor},
    {TransportType.ble},
  ),
  DeviceImplementation.difluidR2Sensor: _ReconnectSupport(
    {DeviceType.sensor},
    {TransportType.ble},
  ),
  DeviceImplementation.debugPort: _ReconnectSupport(
    {DeviceType.sensor},
    {TransportType.serial},
  ),
  DeviceImplementation.sensorBasket: _ReconnectSupport(
    {DeviceType.sensor},
    {TransportType.serial},
  ),
  DeviceImplementation.bengleDebugPort: _ReconnectSupport(
    {DeviceType.sensor},
    {TransportType.serial},
  ),
  DeviceImplementation.plugin: _ReconnectSupport(
    {DeviceType.scale, DeviceType.sensor, DeviceType.grinder},
    {TransportType.ble, TransportType.unknown},
  ),
};

final class NewOwnerRetentionAllowlist {
  const NewOwnerRetentionAllowlist({
    required this.preferredMachineId,
    required this.machineMetadata,
    required this.preferredScaleId,
    required this.scaleMetadata,
    required this.skin,
  }) : assert(
         (preferredMachineId == null) == (machineMetadata == null),
         'machine reconnect metadata is required exactly for a concrete '
         'machine selection',
       ),
       assert(
         (preferredScaleId == null ||
                 preferredScaleId == usbHdsScalePreference) ==
             (scaleMetadata == null),
         'scale reconnect metadata is required exactly for a concrete scale '
         'selection',
       );

  final String? preferredMachineId;
  final RetainedDeviceMetadata? machineMetadata;
  final String? preferredScaleId;
  final RetainedDeviceMetadata? scaleMetadata;
  final RetainedManagedSkinPackage skin;
}

sealed class NewOwnerRetentionPreflightResult {
  const NewOwnerRetentionPreflightResult();
}

final class NewOwnerRetentionAccepted extends NewOwnerRetentionPreflightResult {
  const NewOwnerRetentionAccepted(this.allowlist);

  final NewOwnerRetentionAllowlist allowlist;
}

final class NewOwnerRetentionRejected extends NewOwnerRetentionPreflightResult {
  const NewOwnerRetentionRejected(this.reason);

  final NewOwnerRetentionRejection reason;
}

final class _Selection {
  const _Selection.accepted(this.metadata) : rejection = null;

  const _Selection.rejected(this.rejection) : metadata = null;

  final RetainedDeviceMetadata? metadata;
  final NewOwnerRetentionRejection? rejection;
}

final class NewOwnerRetentionPreflight {
  NewOwnerRetentionPreflight({
    required this._settings,
    required this._storage,
    required this._runtimeOwner,
    required this._legacySkinSelection,
    required this._manualEndpoints,
  });

  final SettingsService _settings;
  final WebUIStorage _storage;
  final SkinServingSelectionSource? _runtimeOwner;
  final LegacySelectedSkinLookup _legacySkinSelection;
  final WifiManualEndpointLookup _manualEndpoints;

  Future<NewOwnerRetentionPreflightResult> observe() async {
    final String? preferredMachineId;
    final String? preferredScaleId;
    final String? storedSkinId;
    try {
      preferredMachineId = await _settings.preferredMachineId();
      preferredScaleId = await _settings.preferredScaleId();
      storedSkinId = await _settings.persistedDefaultSkinId();
    } catch (_) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.settingsReadFailed,
      );
    }

    List<Map<String, dynamic>>? remembered;
    if (_needsRememberedRecords(preferredMachineId, preferredScaleId)) {
      try {
        remembered = _decodeRememberedRecords(
          await _settings.rememberedDevices(),
        );
      } on FormatException {
        return const NewOwnerRetentionRejected(
          NewOwnerRetentionRejection.rememberedDevicesUnreadable,
        );
      } catch (_) {
        return const NewOwnerRetentionRejected(
          NewOwnerRetentionRejection.settingsReadFailed,
        );
      }
    }

    final machine = _resolveSelection(
      selectedId: preferredMachineId,
      expectedType: DeviceType.machine,
      records: remembered,
      unresolved: NewOwnerRetentionRejection.preferredMachineUnresolved,
      ambiguous: NewOwnerRetentionRejection.preferredMachineAmbiguous,
      incomplete: NewOwnerRetentionRejection.preferredMachineMetadataIncomplete,
      inconsistent:
          NewOwnerRetentionRejection.preferredMachineMetadataInconsistent,
    );
    if (machine.rejection case final rejection?) {
      return NewOwnerRetentionRejected(rejection);
    }

    final scale = await _resolveScaleSelection(preferredScaleId, remembered);
    if (scale.rejection case final rejection?) {
      return NewOwnerRetentionRejected(rejection);
    }

    final String? legacySkinId;
    try {
      legacySkinId = await _legacySkinSelection.selectedSkinId();
    } catch (_) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.legacySkinSelectionUnreadable,
      );
    }

    final skinId = normalizePersistedDefaultSkinId(storedSkinId);
    if (legacySkinId != null && legacySkinId != skinId) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.skinSelectionDisagreement,
      );
    }

    final runtimeOwner = _runtimeOwner;
    if (runtimeOwner == null) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.skinServingSelectionUnavailable,
      );
    }
    final SkinServingSelection serving;
    try {
      serving = runtimeOwner.observeServingSelection();
    } catch (_) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.skinServingSelectionUnreadable,
      );
    }

    final declared = serving.declaredOverride;
    final runtimePaths = <String?>{
      if (serving.servedPath != null) serving.servedPath,
      if (declared.source == SkinSource.path) declared.value,
    };
    if (runtimePaths.isEmpty) runtimePaths.add(null);

    ManagedSkinLookup? selected;
    for (final runtimePath in runtimePaths) {
      final lookup = await _storage.resolveManagedSelectedSkin(
        skinId,
        runtimePath: runtimePath,
      );
      if (!lookup.isResolved) {
        return NewOwnerRetentionRejected(
          runtimePath == null
              ? _skinRejection(lookup.status)
              : NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
        );
      }
      selected = lookup;
    }
    final skin = selected!;
    if (!_runtimeSelectionMatches(declared, skin)) {
      return const NewOwnerRetentionRejected(
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
    }

    return NewOwnerRetentionAccepted(
      NewOwnerRetentionAllowlist(
        preferredMachineId: preferredMachineId,
        machineMetadata: machine.metadata,
        preferredScaleId: preferredScaleId,
        scaleMetadata: scale.metadata,
        skin: RetainedManagedSkinPackage(
          skinId: skin.skinId!,
          directoryName: skin.directoryName!,
        ),
      ),
    );
  }

  bool _needsRememberedRecords(String? machineId, String? scaleId) =>
      machineId != null ||
      (scaleId != null && scaleId != usbHdsScalePreference);

  Future<_Selection> _resolveScaleSelection(
    String? selectedId,
    List<Map<String, dynamic>>? records,
  ) async {
    if (selectedId == usbHdsScalePreference) {
      return const _Selection.accepted(null);
    }
    final rememberedSelection = _resolveSelection(
      selectedId: selectedId,
      expectedType: DeviceType.scale,
      records: records,
      unresolved: NewOwnerRetentionRejection.preferredScaleUnresolved,
      ambiguous: NewOwnerRetentionRejection.preferredScaleAmbiguous,
      incomplete: NewOwnerRetentionRejection.preferredScaleMetadataIncomplete,
      inconsistent:
          NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
    );
    if (rememberedSelection.rejection !=
        NewOwnerRetentionRejection.preferredScaleUnresolved) {
      return rememberedSelection;
    }
    final host = _manualWifiHost(selectedId);
    if (host == null) return rememberedSelection;

    final WifiManualEndpointMatch match;
    try {
      match = await _manualEndpoints.findManualEndpoint(host);
    } catch (_) {
      return const _Selection.rejected(
        NewOwnerRetentionRejection.preferredScaleManualEndpointUnreadable,
      );
    }
    return switch (match) {
      WifiManualEndpointFound() => const _Selection.accepted(
        RetainedDeviceMetadata(
          implementation: DeviceImplementation.hdsWifi,
          transportType: TransportType.wifi,
        ),
      ),
      WifiManualEndpointAbsent() => rememberedSelection,
      WifiManualEndpointAmbiguous() => const _Selection.rejected(
        NewOwnerRetentionRejection.preferredScaleManualEndpointAmbiguous,
      ),
      WifiManualEndpointMalformed() => const _Selection.rejected(
        NewOwnerRetentionRejection.preferredScaleManualEndpointMalformed,
      ),
    };
  }

  String? _manualWifiHost(String? selectedId) {
    if (selectedId == null || !selectedId.startsWith(WifiScaleId.prefix)) {
      return null;
    }
    final host = WifiScaleId.hostOf(selectedId);
    return host.isEmpty ? null : host;
  }

  List<Map<String, dynamic>> _decodeRememberedRecords(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('remembered devices must be a JSON list');
    }
    return [
      for (final entry in decoded)
        if (entry is Map)
          Map<String, dynamic>.from(entry)
        else
          throw const FormatException(
            'remembered devices must be JSON objects',
          ),
    ];
  }

  _Selection _resolveSelection({
    required String? selectedId,
    required DeviceType expectedType,
    required List<Map<String, dynamic>>? records,
    required NewOwnerRetentionRejection unresolved,
    required NewOwnerRetentionRejection ambiguous,
    required NewOwnerRetentionRejection incomplete,
    required NewOwnerRetentionRejection inconsistent,
  }) {
    if (selectedId == null) return const _Selection.accepted(null);
    if (selectedId.isEmpty || isEphemeralDeviceIdentity(selectedId)) {
      return _Selection.rejected(unresolved);
    }

    final candidates = records!
        .where((record) => record['id'] == selectedId)
        .toList();
    if (candidates.isEmpty) return _Selection.rejected(unresolved);
    if (candidates.length > 1) return _Selection.rejected(ambiguous);

    final record = candidates.single;
    final name = record['name'];
    final typeName = record['type'];
    if (name is! String || typeName is! String) {
      return _Selection.rejected(incomplete);
    }
    if (DeviceType.values.asNameMap()[typeName] != expectedType) {
      return _Selection.rejected(inconsistent);
    }

    final implementationName = record['implementation'];
    final transportName = record['transportType'];
    if (implementationName is! String || transportName is! String) {
      return _Selection.rejected(incomplete);
    }
    final implementation = DeviceImplementation.values
        .asNameMap()[implementationName];
    final transportType = TransportType.values.asNameMap()[transportName];
    if (implementation == null || transportType == null) {
      return _Selection.rejected(incomplete);
    }
    if (implementation == DeviceImplementation.plugin &&
        expectedType == DeviceType.scale) {
      return _Selection.rejected(
        NewOwnerRetentionRejection.preferredScalePluginUnsupported,
      );
    }
    final support = _reconnectSupport[implementation];
    if (support == null ||
        !support.roles.contains(expectedType) ||
        !support.transports.contains(transportType)) {
      return _Selection.rejected(inconsistent);
    }
    return _Selection.accepted(
      RetainedDeviceMetadata(
        implementation: implementation,
        transportType: transportType,
      ),
    );
  }

  bool _runtimeSelectionMatches(SkinOverride declared, ManagedSkinLookup skin) {
    switch (declared.source) {
      case SkinSource.registry:
        return true;
      case SkinSource.id:
        return declared.value != null && declared.value == skin.skinId;
      case SkinSource.path:
        return declared.value != null;
    }
  }

  NewOwnerRetentionRejection _skinRejection(ManagedSkinLookupStatus status) {
    return switch (status) {
      ManagedSkinLookupStatus.resolved => throw StateError(
        'a resolved managed skin has no rejection',
      ),
      ManagedSkinLookupStatus.invalidId =>
        NewOwnerRetentionRejection.skinIdInvalid,
      ManagedSkinLookupStatus.missing =>
        NewOwnerRetentionRejection.skinPackageMissing,
      ManagedSkinLookupStatus.escaped =>
        NewOwnerRetentionRejection.skinPackageEscaped,
      ManagedSkinLookupStatus.ambiguous =>
        NewOwnerRetentionRejection.skinPackageAmbiguous,
      ManagedSkinLookupStatus.unreadable =>
        NewOwnerRetentionRejection.skinPackageUnreadable,
    };
  }
}
