import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_milk_probe.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/services/storage/new_owner_retention_preflight.dart';
import 'package:reaprime/src/services/wifi/bonsoir_wifi_scale_browser.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

class _CreatingSupportPathProvider extends PathProviderPlatform {
  _CreatingSupportPathProvider(this.support);

  final Directory support;
  int calls = 0;

  @override
  Future<String?> getApplicationSupportPath() async {
    calls++;
    await support.create(recursive: true);
    return support.path;
  }
}

base class _RecordingAsyncPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};
  final writes = <String>[];
  final reads = <String>[];
  bool failReads = false;
  bool failRememberedDevicesRead = false;
  bool failDefaultSkinIdRead = false;

  Never _failRead(String key) => throw StateError('read failed for $key');

  void _logRead(String key) {
    reads.add(key);
    if (failReads) _failRead(key);
    if (failRememberedDevicesRead &&
        key == SettingsKeys.rememberedDevices.name) {
      _failRead(key);
    }
    if (failDefaultSkinIdRead && key == SettingsKeys.defaultSkinId.name) {
      _failRead(key);
    }
  }

  String _logWrite(String operation, String key) {
    final entry = '$operation:$key';
    writes.add(entry);
    return entry;
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    _logWrite('setString', key);
    values[key] = value;
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    _logWrite('setBool', key);
    values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    _logWrite('setDouble', key);
    values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    _logWrite('setInt', key);
    values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    _logWrite('setStringList', key);
    values[key] = value;
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    _logRead(key);
    return values[key] as String?;
  }

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async {
    _logRead(key);
    return values[key] as bool?;
  }

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async {
    _logRead(key);
    return values[key] as double?;
  }

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async {
    _logRead(key);
    return values[key] as int?;
  }

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async {
    _logRead(key);
    return values[key] as List<String>?;
  }

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    final allowList = parameters.filter.allowList;
    _logWrite('clear', allowList == null ? '*' : allowList.join(','));
    if (allowList == null) {
      values.clear();
    } else {
      for (final key in allowList) {
        values.remove(key);
      }
    }
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => Map<String, Object>.of(values);

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => values.keys.toSet();
}

/// The legacy shared-preferences backend the manual WiFi endpoint owner reads
/// and writes. It records every backend call so a read-only observation can be
/// proven not to persist anything.
class _RecordingLegacyPreferences extends SharedPreferencesStorePlatform {
  final values = <String, Object>{};
  final reads = <String>[];
  final writes = <String>[];
  bool failReads = false;

  @override
  Future<bool> clear() async {
    writes.add('clear');
    values.clear();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    reads.add('getAll');
    if (failReads) {
      throw const FileSystemException('preference store unavailable');
    }
    return Map<String, Object>.of(values);
  }

  @override
  Future<bool> remove(String key) async {
    writes.add('remove:$key');
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add('setValue:$key');
    values[key] = value;
    return true;
  }
}

/// Records every inspect/read the selection query performs, delegating to the
/// real filesystem so the recorded paths are the real fixtures.
class _RecordingSkinFileAccess implements ManagedSkinFileAccess {
  final SystemManagedSkinFileAccess _inner =
      const SystemManagedSkinFileAccess();
  final operations = <String>[];
  bool failCanonical = false;
  List<String>? directoryOrder;
  bool onlyAlias = false;
  String? failManifestDirectory;

  Iterable<String> get contentReads => operations.where(
    (op) =>
        op.startsWith('readBoundedText:') ||
        op.startsWith('probeReadableFile:'),
  );

  Iterable<String> get canonicalised =>
      operations.where((op) => op.startsWith('canonicalPath:'));

  @override
  Future<List<String>> listSubdirectoryNames(String path) async {
    operations.add('list:$path');
    final names = await _inner.listSubdirectoryNames(path);
    if (onlyAlias) names.removeWhere((name) => name != 'alias');
    final order = directoryOrder;
    if (order != null) {
      names.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    }
    return names;
  }

  @override
  Future<FileSystemEntityType> entityType(
    String path, {
    bool followLinks = false,
  }) {
    operations.add('type${followLinks ? '+' : '-'}:$path');
    return _inner.entityType(path, followLinks: followLinks);
  }

  @override
  Future<String> linkTarget(String path) {
    operations.add('linkTarget:$path');
    return _inner.linkTarget(path);
  }

  @override
  Future<String> canonicalPath(String path) {
    operations.add('canonicalPath:$path');
    if (failCanonical) throw FileSystemException('root read failed', path);
    return _inner.canonicalPath(path);
  }

  @override
  Future<String> readBoundedText(String path, {required int maxBytes}) {
    operations.add('readBoundedText:$path');
    if (p.basename(p.dirname(path)) == failManifestDirectory) {
      throw FileSystemException('manifest read failed', path);
    }
    return _inner.readBoundedText(path, maxBytes: maxBytes);
  }

  @override
  Future<void> probeReadableFile(String path) {
    operations.add('probeReadableFile:$path');
    return _inner.probeReadableFile(path);
  }
}

final class _RecordingManualEndpointLookup implements WifiManualEndpointLookup {
  _RecordingManualEndpointLookup({
    this.result = const WifiManualEndpointAbsent(),
  });

  final WifiManualEndpointMatch result;
  final hosts = <String>[];

  @override
  Future<WifiManualEndpointMatch> findManualEndpoint(String host) async {
    hosts.add(host);
    return result;
  }
}

final class _FixedServingSelection implements SkinServingSelectionSource {
  _FixedServingSelection(this._selection);

  final SkinServingSelection _selection;

  @override
  SkinServingSelection observeServingSelection() => _selection;
}

final class _ThrowingServingSelection implements SkinServingSelectionSource {
  @override
  SkinServingSelection observeServingSelection() =>
      throw StateError('simulated serving selection read failure');
}

final class _InertBengle implements BengleInterface {
  _InertBengle({this.transportType = TransportType.serial});

  @override
  String get deviceId => 'bengle-machine-a';

  @override
  final TransportType transportType;

  @override
  String get name => 'Bengle';

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _ObservedState {
  const _ObservedState(this.preferences, this.legacyPreferences, this.files);

  final Map<String, Object> preferences;
  final Map<String, Object> legacyPreferences;
  final Map<String, String> files;
}

Map<String, Object?> machineRecord({
  String id = 'machine-a',
  String name = 'DE1',
  String type = 'machine',
  String? implementation = 'unifiedDe1',
  String? transportType = 'ble',
}) => {
  'id': id,
  'name': name,
  'type': type,
  'implementation': ?implementation,
  'transportType': ?transportType,
};

Map<String, Object?> scaleRecord({
  String id = 'scale-a',
  String name = 'Decent Scale',
  String type = 'scale',
  String? implementation = 'decentScale',
  String? transportType = 'ble',
}) => machineRecord(
  id: id,
  name: name,
  type: type,
  implementation: implementation,
  transportType: transportType,
);

String ownerEncodedRegistry(Device device) {
  final record = RememberedDevice.fromDevice(device);
  expect(record, isNotNull, reason: 'the owner serializer dropped $device');
  return RememberedDevice.encodeList([record!]);
}

NewOwnerRetentionAllowlist acceptedAllowlist(
  NewOwnerRetentionPreflightResult result,
) {
  expect(result, isA<NewOwnerRetentionAccepted>());
  return (result as NewOwnerRetentionAccepted).allowlist;
}

NewOwnerRetentionRejection rejectionOf(
  NewOwnerRetentionPreflightResult result,
) {
  expect(result, isA<NewOwnerRetentionRejected>());
  return (result as NewOwnerRetentionRejected).reason;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAsyncPreferences platform;
  late _RecordingLegacyPreferences legacyPreferences;
  late SharedPreferencesStorePlatform previousLegacyPreferences;
  late SharedPreferencesSettingsService settings;
  late Directory workspace;
  late Directory webUiDir;

  setUp(() async {
    platform = _RecordingAsyncPreferences();
    SharedPreferencesAsyncPlatform.instance = platform;
    previousLegacyPreferences = SharedPreferencesStorePlatform.instance;
    legacyPreferences = _RecordingLegacyPreferences();
    SharedPreferencesStorePlatform.instance = legacyPreferences;
    SharedPreferences.resetStatic();

    workspace = Directory.systemTemp.createTempSync('retention_preflight');
    webUiDir = Directory(p.join(workspace.path, 'web-ui'))..createSync();
    File(p.join(workspace.path, 'new-owner-reset-journal.json'))
        .writeAsStringSync('{"state":"resetting","stage":"deletion"}');
    File(p.join(workspace.path, 'streamline_bridge.sqlite'))
        .writeAsStringSync('sqlite-canary');
    platform.values[SettingsKeys.telemetryConsent.name] = true;
    platform.values[SettingsKeys.preferredGrinderDeviceId.name] = 'grinder-a';
    platform.values[SettingsKeys.logLevel.name] = 'DEBUG';

    settings = SharedPreferencesSettingsService();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
    SharedPreferencesStorePlatform.instance = previousLegacyPreferences;
    SharedPreferences.resetStatic();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  void seedManualHosts(Object value) =>
      legacyPreferences.values['flutter.wifi_scale_manual_hosts'] = value;

  void seedSkin(
    String directoryName, {
    String? declaredId,
    String? manifestName = 'skin-manifest.json',
    String? manifestBody,
    String? manifestLinkTarget,
    bool manifestAsDirectory = false,
    bool withIndexHtml = true,
    bool indexAsDirectory = false,
    String? indexLinkTarget,
  }) {
    final dir = Directory(p.join(webUiDir.path, directoryName))..createSync();
    if (indexAsDirectory) {
      Directory(p.join(dir.path, 'index.html')).createSync();
    } else if (withIndexHtml) {
      if (indexLinkTarget != null) {
        Link(p.join(dir.path, 'index.html')).createSync(indexLinkTarget);
      } else {
        File(p.join(dir.path, 'index.html')).writeAsStringSync('<html></html>');
      }
    }
    File(p.join(dir.path, 'skin-state.json'))
        .writeAsStringSync('{"factory":"personal-state"}');
    if (manifestName == null) return;
    final manifestPath = p.join(dir.path, manifestName);
    if (manifestLinkTarget != null) {
      Link(manifestPath).createSync(manifestLinkTarget);
      return;
    }
    if (manifestAsDirectory) {
      Directory(manifestPath).createSync();
      return;
    }
    File(manifestPath).writeAsStringSync(
      manifestBody ??
          jsonEncode({
            'id': declaredId ?? directoryName,
            'name': directoryName,
          }),
    );
  }

  String canonicalWebUiPath([String? child]) {
    final canonicalRoot = webUiDir.resolveSymbolicLinksSync();
    return child == null ? canonicalRoot : p.join(canonicalRoot, child);
  }

  Map<String, String> treeSnapshot(Directory root) => {
    for (final entity in root.listSync(recursive: true, followLinks: false))
      if (entity is File)
        p.relative(entity.path, from: root.path): base64Encode(
          entity.readAsBytesSync(),
        )
      else if (entity is Link)
        p.relative(entity.path, from: root.path): 'link:${entity.targetSync()}',
  };

  _ObservedState observeState() => _ObservedState(
    Map<String, Object>.of(platform.values),
    Map<String, Object>.of(legacyPreferences.values),
    treeSnapshot(workspace),
  );

  void expectNoStateChange(_ObservedState before) {
    expect(platform.values, before.preferences, reason: 'preferences changed');
    expect(platform.writes, isEmpty, reason: 'preferences were written');
    expect(
      legacyPreferences.values,
      before.legacyPreferences,
      reason: 'legacy preferences changed',
    );
    expect(
      legacyPreferences.writes,
      isEmpty,
      reason: 'legacy preferences were written',
    );
    expect(treeSnapshot(workspace), before.files, reason: 'files changed');
  }

  Future<NewOwnerRetentionPreflightResult> runPreflight({
    SkinOverride declaredOverride = const SkinOverride.registry(),
    SkinServingSelectionSource? runtimeOwner,
    bool omitRuntimeOwner = false,
    ManagedSkinFileAccess? skinFileAccess,
    WifiManualEndpointLookup? manualEndpoints,
    bool omitRootOverride = false,
  }) async {
    final storage = WebUIStorage(
      SettingsController(settings),
      webUIDir: omitRootOverride ? null : webUiDir,
      skinFileAccess: skinFileAccess,
    );
    final result = await NewOwnerRetentionPreflight(
      settings: settings,
      storage: storage,
      runtimeOwner: omitRuntimeOwner
          ? null
          : runtimeOwner ??
                _FixedServingSelection(
                  SkinServingSelection.notServing(
                    declaredOverride: declaredOverride,
                  ),
                ),
      legacySkinSelection: SharedPrefsLegacySelectedSkinLookup(),
      manualEndpoints: manualEndpoints ?? SharedPrefsWifiManualEndpointStore(),
    ).observe();
    expect(
      storage.installedSkins,
      isEmpty,
      reason: 'preflight populated the owner skin registry',
    );
    return result;
  }

  group('accepted retention allowlist', () {
    test('retains concrete machine, primary scale and managed skin', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(),
        scaleRecord(),
      ]);
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.preferredMachineId, 'machine-a');
      expect(
        allowlist.machineMetadata!.implementation,
        DeviceImplementation.unifiedDe1,
      );
      expect(allowlist.machineMetadata!.transportType, TransportType.ble);
      expect(allowlist.preferredScaleId, 'scale-a');
      expect(
        allowlist.scaleMetadata!.implementation,
        DeviceImplementation.decentScale,
      );
      expect(allowlist.scaleMetadata!.transportType, TransportType.ble);
      expect(allowlist.skin.skinId, 'insight');
      expect(allowlist.skin.directoryName, 'insight');
      expectNoStateChange(before);
    });

    test(
      'treats absent preferences as automatic selection and default skin',
      () async {
        seedSkin('streamline.js');
        final before = observeState();

        final allowlist = acceptedAllowlist(await runPreflight());

        expect(allowlist.preferredMachineId, isNull);
        expect(allowlist.machineMetadata, isNull);
        expect(allowlist.preferredScaleId, isNull);
        expect(allowlist.scaleMetadata, isNull);
        expect(allowlist.skin.skinId, 'streamline.js');
        expect(allowlist.skin.directoryName, 'streamline.js');
        expectNoStateChange(before);
      },
    );

    test('normalizes the legacy skin alias without migrating it', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.defaultSkinId.name] =
          'streamline_project-main';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'streamline.js');
      expect(
        platform.values[SettingsKeys.defaultSkinId.name],
        'streamline_project-main',
      );
      expectNoStateChange(before);
    });

    test('retains the usb-hds:any selector without a remembered row', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'usb-hds:any';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(),
      ]);
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.preferredMachineId, isNull);
      expect(allowlist.preferredScaleId, 'usb-hds:any');
      expect(allowlist.scaleMetadata, isNull);
      expectNoStateChange(before);
    });

    test(
      'retains a manual WiFi endpoint without a remembered record',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        seedManualHosts(<String>['10.0.0.9', '192.168.1.50']);
        final before = observeState();

        final allowlist = acceptedAllowlist(await runPreflight());

        expect(allowlist.preferredMachineId, isNull);
        expect(allowlist.machineMetadata, isNull);
        expect(allowlist.preferredScaleId, 'wifi:192.168.1.50');
        expect(
          allowlist.scaleMetadata!.implementation,
          DeviceImplementation.hdsWifi,
        );
        expect(allowlist.scaleMetadata!.transportType, TransportType.wifi);
        expect(allowlist.skin.skinId, 'streamline.js');
        expectNoStateChange(before);
      },
    );

    test(
      'accepts a runtime path override that is the managed package root',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        final allowlist = acceptedAllowlist(
          await runPreflight(
            declaredOverride: SkinOverride.path(
              p.join(webUiDir.path, 'insight'),
            ),
          ),
        );

        expect(allowlist.skin.skinId, 'insight');
        expectNoStateChange(before);
      },
    );

    test(
      'accepts a runtime id override naming the selected managed skin',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        final allowlist = acceptedAllowlist(
          await runPreflight(
            declaredOverride: const SkinOverride.id('insight'),
          ),
        );

        expect(allowlist.skin.skinId, 'insight');
        expectNoStateChange(before);
      },
    );
    test('accepts a managed skin described only by manifest.json', () async {
      seedSkin('streamline.js');
      seedSkin('insight', manifestName: 'manifest.json');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expect(allowlist.skin.directoryName, 'insight');
      expectNoStateChange(before);
    });

    test('accepts a managed skin directory without a manifest', () async {
      seedSkin('streamline.js');
      seedSkin('insight', manifestName: null);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expect(allowlist.skin.directoryName, 'insight');
      expectNoStateChange(before);
    });

    test(
      'retains a legacy package whose directory name differs from its id',
      () async {
        seedSkin('streamline', declaredId: 'streamline.js');
        platform.values[SettingsKeys.defaultSkinId.name] = 'streamline.js';
        final before = observeState();

        final allowlist = acceptedAllowlist(await runPreflight());
        expect(allowlist.skin.skinId, 'streamline.js');
        expect(allowlist.skin.directoryName, 'streamline');
        expectNoStateChange(before);
      },
    );

    test(
      'retains the declared id of a package whose directory differs',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight-dir', declaredId: 'insight');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        final allowlist = acceptedAllowlist(await runPreflight());

        expect(allowlist.skin.skinId, 'insight');
        expect(allowlist.skin.directoryName, 'insight-dir');
        expectNoStateChange(before);
      },
    );

    test('prefers the canonical directory over a duplicate id', () async {
      seedSkin('insight');
      seedSkin('insight-legacy', declaredId: 'insight');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expectNoStateChange(before);
    });

    test('accepts an in-package manifest symlink', () async {
      seedSkin('streamline.js');
      seedSkin('insight', manifestName: null);
      final realManifest = Directory(p.join(webUiDir.path, 'insight'));
      File(p.join(realManifest.path, 'manifest.real.json'))
          .writeAsStringSync(jsonEncode({'id': 'insight', 'name': 'insight'}));
      Link(p.join(realManifest.path, 'skin-manifest.json'))
          .createSync(p.join(realManifest.path, 'manifest.real.json'));
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expectNoStateChange(before);
    });

    test('accepts an in-package index.html symlink', () async {
      seedSkin('streamline.js');
      seedSkin('insight', withIndexHtml: false);
      final dir = Directory(p.join(webUiDir.path, 'insight'));
      File(p.join(dir.path, 'index.real.html'))
          .writeAsStringSync('<html></html>');
      Link(p.join(dir.path, 'index.html'))
          .createSync(p.join(dir.path, 'index.real.html'));
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expectNoStateChange(before);
    });

    test('accepts a runtime path to the owned legacy directory', () async {
      seedSkin('streamline', declaredId: 'streamline.js');
      platform.values[SettingsKeys.defaultSkinId.name] = 'streamline.js';
      final before = observeState();

      final allowlist = acceptedAllowlist(
        await runPreflight(
          declaredOverride: SkinOverride.path(
            p.join(webUiDir.path, 'streamline'),
          ),
        ),
      );

      expect(allowlist.skin.skinId, 'streamline.js');
      expectNoStateChange(before);
    });
    test('accepts a machine connected over serial', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(implementation: 'bengle', transportType: 'serial'),
      ]);
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(
        allowlist.machineMetadata!.implementation,
        DeviceImplementation.bengle,
      );
      expect(allowlist.machineMetadata!.transportType, TransportType.serial);
      expectNoStateChange(before);
    });

    test('accepts an HDS scale connected over serial', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        scaleRecord(implementation: 'hdsSerial', transportType: 'serial'),
      ]);
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(
        allowlist.scaleMetadata!.implementation,
        DeviceImplementation.hdsSerial,
      );
      expect(allowlist.scaleMetadata!.transportType, TransportType.serial);
      expectNoStateChange(before);
    });

    for (final transport in [TransportType.serial, TransportType.ble]) {
      test(
        'retains the owner-built Bengle primary scale over ${transport.name}',
        () async {
          seedSkin('streamline.js');
          final scale = BengleVirtualScale(
            _InertBengle(transportType: transport),
          );
          platform.values[SettingsKeys.preferredScaleId.name] = scale.deviceId;
          platform.values[SettingsKeys.rememberedDevices.name] =
              ownerEncodedRegistry(scale);
          final before = observeState();

          final allowlist = acceptedAllowlist(await runPreflight());

          expect(
            allowlist.preferredScaleId,
            'bengle-internal-bengle-machine-a',
          );
          expect(
            allowlist.scaleMetadata!.implementation,
            DeviceImplementation.bengle,
          );
          expect(allowlist.scaleMetadata!.transportType, transport);
          expectNoStateChange(before);
        },
      );
    }

    test('accepts an HDS scale connected over wifi', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        scaleRecord(implementation: 'hdsWifi', transportType: 'wifi'),
      ]);
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(
        allowlist.scaleMetadata!.implementation,
        DeviceImplementation.hdsWifi,
      );
      expect(allowlist.scaleMetadata!.transportType, TransportType.wifi);
      expectNoStateChange(before);
    });
  });

  group('rejected device selections', () {
    test(
      'rejects a concrete machine preference without remembered metadata',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
        platform.values[SettingsKeys.rememberedDevices.name] = '[]';
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredMachineUnresolved,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a session-only machine identity even with a stored record',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] =
            'usb-session-1234';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(id: 'usb-session-1234'),
        ]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredMachineUnresolved,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects machine records without required reconnect metadata',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(implementation: null, transportType: null),
        ]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredMachineMetadataIncomplete,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects duplicate remembered records for the selected machine',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(),
          machineRecord(name: 'DE1 duplicate'),
        ]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredMachineAmbiguous,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a scale preference that resolves to a machine record',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] = 'machine-a';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(),
        ]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a WiFi record with the wrong role without manual lookup',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(id: 'wifi:192.168.1.50'),
        ]);
        seedManualHosts(<String>['192.168.1.50']);
        final lookup = _RecordingManualEndpointLookup(
          result: const WifiManualEndpointFound(),
        );
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(manualEndpoints: lookup)),
          NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
        );
        expect(lookup.hosts, isEmpty);
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a matching record with a malformed name without manual lookup',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          scaleRecord(id: 'wifi:192.168.1.50')..['name'] = 42,
        ]);
        seedManualHosts(<String>['192.168.1.50']);
        final lookup = _RecordingManualEndpointLookup(
          result: const WifiManualEndpointFound(),
        );
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(manualEndpoints: lookup)),
          NewOwnerRetentionRejection.preferredScaleMetadataIncomplete,
        );
        expect(lookup.hosts, isEmpty);
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a matching record with a malformed type without manual lookup',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          scaleRecord(id: 'wifi:192.168.1.50')..['type'] = 42,
        ]);
        seedManualHosts(<String>['192.168.1.50']);
        final lookup = _RecordingManualEndpointLookup(
          result: const WifiManualEndpointFound(),
        );
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(manualEndpoints: lookup)),
          NewOwnerRetentionRejection.preferredScaleMetadataIncomplete,
        );
        expect(lookup.hosts, isEmpty);
        expectNoStateChange(before);
      },
    );

    test('rejects a registry holding only a non-object element', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'wifi:192.168.1.50';
      platform.values[SettingsKeys.rememberedDevices.name] = '[42]';
      seedManualHosts(<String>['192.168.1.50']);
      final lookup = _RecordingManualEndpointLookup(
        result: const WifiManualEndpointFound(),
      );
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(manualEndpoints: lookup)),
        NewOwnerRetentionRejection.rememberedDevicesUnreadable,
      );
      expect(lookup.hosts, isEmpty);
      expectNoStateChange(before);
    });

    test(
      'rejects a registry holding a non-object element beside a valid one',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(),
          42,
        ]);
        seedManualHosts(<String>['192.168.1.50']);
        final lookup = _RecordingManualEndpointLookup(
          result: const WifiManualEndpointFound(),
        );
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(manualEndpoints: lookup)),
          NewOwnerRetentionRejection.rememberedDevicesUnreadable,
        );
        expect(lookup.hosts, isEmpty);
        expectNoStateChange(before);
      },
    );

    test(
      'rejects the owner-built Bengle sensor record as the primary scale',
      () async {
        seedSkin('streamline.js');
        final probe = BengleMilkProbe(bengle: _InertBengle());
        platform.values[SettingsKeys.preferredScaleId.name] = probe.deviceId;
        platform.values[SettingsKeys.rememberedDevices.name] =
            ownerEncodedRegistry(probe);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a Bengle primary scale record with an unknown transport',
      () async {
        seedSkin('streamline.js');
        final virtual = BengleVirtualScale(_InertBengle());
        platform.values[SettingsKeys.preferredScaleId.name] = virtual.deviceId;
        platform.values[SettingsKeys.rememberedDevices.name] =
            RememberedDevice.encodeList([
              RememberedDevice(
                id: virtual.deviceId,
                name: virtual.name,
                type: DeviceType.scale,
                implementation: DeviceImplementation.bengle,
                transportType: TransportType.unknown,
              ),
            ]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a WiFi scale missing from the manual endpoint list',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] = 'wifi:10.0.0.9';
        seedManualHosts(<String>['192.168.1.50']);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredScaleUnresolved,
        );
        expectNoStateChange(before);
      },
    );

    test('rejects duplicate manual WiFi endpoint entries', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'wifi:192.168.1.50';
      seedManualHosts(<String>['192.168.1.50', '192.168.1.50']);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredScaleManualEndpointAmbiguous,
      );
      expectNoStateChange(before);
    });

    test('rejects a malformed manual WiFi endpoint preference', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'wifi:192.168.1.50';
      seedManualHosts('192.168.1.50');
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredScaleManualEndpointMalformed,
      );
      expectNoStateChange(before);
    });

    test(
      'rejects a manual WiFi endpoint preference with a non-host entry',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] =
            'wifi:192.168.1.50';
        seedManualHosts(<Object>['192.168.1.50', 42]);
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.preferredScaleManualEndpointMalformed,
        );
        expectNoStateChange(before);
      },
    );

    test('reports a manual WiFi endpoint read failure distinctly', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'wifi:192.168.1.50';
      seedManualHosts(<String>['192.168.1.50']);
      legacyPreferences.failReads = true;
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredScaleManualEndpointUnreadable,
      );
      expectNoStateChange(before);
    });

    test(
      'does not consult manual WiFi endpoints for a non-WiFi scale',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
        final lookup = _RecordingManualEndpointLookup();
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(manualEndpoints: lookup)),
          NewOwnerRetentionRejection.preferredScaleUnresolved,
        );
        expect(lookup.hosts, isEmpty);
        expectNoStateChange(before);
      },
    );

    test('rejects a corrupt remembered-device registry', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = '{not json';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.rememberedDevicesUnreadable,
      );
      expectNoStateChange(before);
    });

    test(
      'reports a settings read failure instead of an absent selection',
      () async {
        seedSkin('streamline.js');
        platform.failReads = true;
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.settingsReadFailed,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'reports a remembered-device read failure as a settings read failure',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
        platform.failRememberedDevicesRead = true;
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.settingsReadFailed,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'reports a persisted-skin read failure after preferred reads succeed',
      () async {
        seedSkin('streamline.js');
        platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
        platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
        platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
          machineRecord(),
          scaleRecord(),
        ]);
        platform.failDefaultSkinIdRead = true;
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.settingsReadFailed,
        );
        expect(
          platform.reads,
          containsAllInOrder([
            SettingsKeys.preferredMachineId.name,
            SettingsKeys.preferredScaleId.name,
            SettingsKeys.defaultSkinId.name,
          ]),
        );
        expectNoStateChange(before);
      },
    );

    test('rejects a machine record whose implementation is a scale', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(implementation: 'decentScale', transportType: 'ble'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredMachineMetadataInconsistent,
      );
      expectNoStateChange(before);
    });

    test('rejects a scale record whose implementation is a machine', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        scaleRecord(implementation: 'unifiedDe1', transportType: 'ble'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
      );
      expectNoStateChange(before);
    });

    test('rejects a machine transport its implementation cannot use', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(implementation: 'unifiedDe1', transportType: 'wifi'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredMachineMetadataInconsistent,
      );
      expectNoStateChange(before);
    });

    test('rejects a scale transport its implementation cannot use', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredScaleId.name] = 'scale-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        scaleRecord(implementation: 'decentScale', transportType: 'serial'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredScaleMetadataInconsistent,
      );
      expectNoStateChange(before);
    });

    test('rejects an unknown transport for a concrete choice', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(implementation: 'unifiedDe1', transportType: 'unknown'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredMachineMetadataInconsistent,
      );
      expectNoStateChange(before);
    });

    test('rejects a plugin implementation for a machine preference', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.preferredMachineId.name] = 'machine-a';
      platform.values[SettingsKeys.rememberedDevices.name] = jsonEncode([
        machineRecord(implementation: 'plugin', transportType: 'ble'),
      ]);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.preferredMachineMetadataInconsistent,
      );
      expectNoStateChange(before);
    });
  });

  group('rejected skin selections', () {
    test('rejects a missing managed package instead of falling back', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageMissing,
      );
      expectNoStateChange(before);
    });

    test('rejects an unsafe persisted skin id', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.defaultSkinId.name] = '../escape';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinIdInvalid,
      );
      expectNoStateChange(before);
    });

    test(
      'rejects a managed skin directory that escapes the managed root',
      () async {
        seedSkin('streamline.js');
        final outside = Directory(p.join(workspace.path, 'outside-skin'))
          ..createSync();
        File(p.join(outside.path, 'index.html'))
            .writeAsStringSync('<html></html>');
        File(p.join(outside.path, 'skin-manifest.json'))
            .writeAsStringSync(jsonEncode({'id': 'escape-skin'}));
        Link(p.join(webUiDir.path, 'escape-skin'))
            .createSync(p.relative(outside.path, from: webUiDir.path));
        platform.values[SettingsKeys.defaultSkinId.name] = 'escape-skin';
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.skinPackageEscaped,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects the package directory name of a differently declared id',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight', declaredId: 'other-skin');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.skinPackageMissing,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects duplicate package directories without a canonical one',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight-a', declaredId: 'insight');
        seedSkin('insight-b', declaredId: 'insight');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        expect(
          rejectionOf(await runPreflight()),
          NewOwnerRetentionRejection.skinPackageAmbiguous,
        );
        expectNoStateChange(before);
      },
    );

    test('rejects a manifest symlink that escapes the package', () async {
      seedSkin('streamline.js');
      final external = File(p.join(workspace.path, 'external-manifest.json'))
        ..writeAsStringSync(jsonEncode({'id': 'insight', 'name': 'insight'}));
      seedSkin('insight', manifestLinkTarget: external.path);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );
      expectNoStateChange(before);
    });

    test('rejects an index.html symlink that escapes the package', () async {
      seedSkin('streamline.js');
      final external = File(p.join(workspace.path, 'external-index.html'))
        ..writeAsStringSync('<html></html>');
      seedSkin('insight', indexLinkTarget: external.path);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );
      expectNoStateChange(before);
    });

    test('rejects an index.html entry point that is a directory', () async {
      seedSkin('streamline.js');
      seedSkin('insight', withIndexHtml: false, indexAsDirectory: true);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageMissing,
      );
      expectNoStateChange(before);
    });

    test('rejects a manifest that cannot be read as a file', () async {
      seedSkin('streamline.js');
      seedSkin('insight', manifestAsDirectory: true);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );
      expectNoStateChange(before);
    });

    test('rejects a runtime path alias outside the managed root', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      final alias = Link(p.join(workspace.path, 'alias-skin'))
        ..createSync(p.join(webUiDir.path, 'insight'));
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(declaredOverride: SkinOverride.path(alias.path)),
        ),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expectNoStateChange(before);
    });

    test(
      'rejects a runtime path naming a non-canonical duplicate package',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight');
        seedSkin('insight-legacy', declaredId: 'insight');
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final before = observeState();

        expect(
          rejectionOf(
            await runPreflight(
              declaredOverride: SkinOverride.path(
                p.join(webUiDir.path, 'insight-legacy'),
              ),
            ),
          ),
          NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
        );
        expectNoStateChange(before);
      },
    );

    test('rejects a managed skin with an unreadable manifest', () async {
      seedSkin('streamline.js');
      seedSkin('insight', manifestBody: '{not json');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );
      expectNoStateChange(before);
    });

    test('rejects a managed skin without an index.html entry point', () async {
      seedSkin('streamline.js');
      seedSkin('insight', withIndexHtml: false);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageMissing,
      );
      expectNoStateChange(before);
    });

    test('rejects a runtime path override outside the managed root', () async {
      seedSkin('streamline.js');
      final outside = Directory(p.join(workspace.path, 'outside-skin'))
        ..createSync();
      File(p.join(outside.path, 'index.html'))
          .writeAsStringSync('<html></html>');
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(declaredOverride: SkinOverride.path(outside.path)),
        ),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expectNoStateChange(before);
    });

    test('rejects a runtime id override naming a different skin', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(
            declaredOverride: const SkinOverride.id('insight'),
          ),
        ),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expectNoStateChange(before);
    });

    test('rejects a runtime path override that does not exist', () async {
      seedSkin('streamline.js');
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(
            declaredOverride: SkinOverride.path(
              p.join(webUiDir.path, 'missing-skin'),
            ),
          ),
        ),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expectNoStateChange(before);
    });
  });

  group('known owner root', () {
    for (final known in [false, true]) {
      test(
        'uninitialized owner known override=$known avoids path lookup',
        () async {
          seedSkin('streamline.js');
          final support = Directory(p.join(workspace.path, 'missing-support'));
          final provider = _CreatingSupportPathProvider(support);
          final previousProvider = PathProviderPlatform.instance;
          final previousTarget = debugDefaultTargetPlatformOverride;
          PathProviderPlatform.instance = provider;
          debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
          try {
            final before = observeState();
            final result = await runPreflight(omitRootOverride: !known);
            expect([provider.calls, support.existsSync()], [0, false]);
            if (known) {
              final retained = acceptedAllowlist(result);
              expect(retained.skin.skinId, 'streamline.js');
              expect(retained.skin.directoryName, 'streamline.js');
            } else {
              expect(
                rejectionOf(result),
                NewOwnerRetentionRejection.skinPackageUnreadable,
              );
            }
            expectNoStateChange(before);
          } finally {
            PathProviderPlatform.instance = previousProvider;
            debugDefaultTargetPlatformOverride = previousTarget;
          }
        },
      );
    }
  });

  group('managed package aliases', () {
    for (final reverse in [false, true]) {
      for (final staged in [false, true]) {
        test('canonical target staging=$staged reverse=$reverse', () async {
          final target = staged ? '.webui-install-staging' : 'insight';
          seedSkin(target, declaredId: 'insight');
          Link(p.join(webUiDir.path, 'alias')).createSync(target);
          platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
          final spy = _RecordingSkinFileAccess()
            ..onlyAlias = !staged
            ..directoryOrder = reverse ? ['alias', target] : [target, 'alias'];
          final before = observeState();
          final result = await runPreflight(skinFileAccess: spy);
          if (staged) {
            expect(result, isA<NewOwnerRetentionRejected>());
            expect(
              spy.contentReads.where((op) => op.contains(target)),
              isEmpty,
            );
          } else {
            final retained = acceptedAllowlist(result);
            expect(retained.skin.skinId, 'insight');
            expect(retained.skin.directoryName, 'insight');
            expect(
              spy.operations,
              contains('linkTarget:${p.join(webUiDir.path, 'alias')}'),
            );
            expect(
              spy.canonicalised,
              contains('canonicalPath:${p.join(webUiDir.path, 'alias')}'),
            );
          }
          expectNoStateChange(before);
        });
      }
    }
  });

  group('selection authority', () {
    for (final reverse in [false, true]) {
      for (final flaw in ['large', 'directory', 'corrupt', 'io', 'escape']) {
        test(
          'canonical $flaw cannot promote legacy reverse=$reverse',
          () async {
            final external = File(p.join(workspace.path, 'external.json'))
              ..writeAsStringSync('{"id":"insight"}');
            seedSkin(
              'insight',
              manifestBody: flaw == 'large'
                  ? jsonEncode({'id': 'insight', 'padding': 'x' * (256 * 1024)})
                  : flaw == 'corrupt'
                  ? '{bad'
                  : null,
              manifestAsDirectory: flaw == 'directory',
              manifestLinkTarget: flaw == 'escape' ? external.path : null,
            );
            seedSkin('insight-legacy', declaredId: 'insight');
            platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
            final spy = _RecordingSkinFileAccess()
              ..directoryOrder = reverse
                  ? ['insight-legacy', 'insight']
                  : ['insight', 'insight-legacy']
              ..failManifestDirectory = flaw == 'io' ? 'insight' : null;
            final before = observeState();
            expect(
              await runPreflight(skinFileAccess: spy),
              isA<NewOwnerRetentionRejected>(),
            );
            expectNoStateChange(before);
          },
        );
      }
      test(
        'hidden noncanonical identity cannot promote inspected legacy reverse=$reverse',
        () async {
          seedSkin('legacy-a', declaredId: 'insight');
          seedSkin(
            'legacy-b',
            manifestBody: jsonEncode({
              'id': 'insight',
              'padding': 'x' * (256 * 1024),
            }),
          );
          platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
          final spy = _RecordingSkinFileAccess()
            ..directoryOrder = reverse
                ? ['legacy-b', 'legacy-a']
                : ['legacy-a', 'legacy-b'];
          final before = observeState();
          expect(
            await runPreflight(skinFileAccess: spy),
            isA<NewOwnerRetentionRejected>(),
          );
          expectNoStateChange(before);
        },
      );
      test(
        'valid canonical remains authoritative with broken unrelated legacy reverse=$reverse',
        () async {
          seedSkin('insight');
          seedSkin('legacy-a', declaredId: 'insight');
          seedSkin('unrelated-broken', manifestBody: '{bad');
          platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
          final spy = _RecordingSkinFileAccess()
            ..directoryOrder = reverse
                ? ['unrelated-broken', 'legacy-a', 'insight']
                : ['insight', 'legacy-a', 'unrelated-broken'];
          final before = observeState();
          final retained = acceptedAllowlist(
            await runPreflight(skinFileAccess: spy),
          );
          expect(retained.skin.directoryName, 'insight');
          expectNoStateChange(before);
        },
      );
    }
  });

  group('observation read seam', () {
    test('root read failure is not missing', () async {
      final spy = _RecordingSkinFileAccess()..failCanonical = true;
      final before = observeState();
      expect(
        rejectionOf(await runPreflight(skinFileAccess: spy)),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );
      expectNoStateChange(before);
    });

    test('positively absent root is missing', () async {
      webUiDir.deleteSync();
      final before = observeState();
      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinPackageMissing,
      );
      expectNoStateChange(before);
    });

    for (final form in [
      'chain',
      'intermediate',
      'cycle',
      'depth',
      'internal',
    ]) {
      test('checks full link path before follow: $form', () async {
        seedSkin('streamline.js');
        final package = p.join(webUiDir.path, 'streamline.js');
        final manifest = p.join(package, 'skin-manifest.json');
        File(manifest).deleteSync();
        final outside = Directory(p.join(workspace.path, 'outside'))
          ..createSync();
        File(p.join(outside.path, 'data.json'))
            .writeAsStringSync('{"id":"streamline.js"}');
        if (form == 'intermediate') {
          Link(p.join(package, 'sub')).createSync(outside.path);
          Link(manifest).createSync('sub/data.json');
        } else if (form == 'depth') {
          for (var i = 0; i < 35; i++) {
            Link(p.join(package, 'link$i')).createSync('link${i + 1}');
          }
          File(p.join(package, 'link35'))
              .writeAsStringSync('{"id":"streamline.js"}');
          Link(manifest).createSync('link0');
        } else if (form == 'internal') {
          File(p.join(package, 'data.json'))
              .writeAsStringSync('{"id":"streamline.js"}');
          Link(p.join(package, 'link')).createSync('data.json');
          Link(manifest).createSync('link');
        } else {
          Link(p.join(package, 'link')).createSync(
            form == 'cycle'
                ? 'skin-manifest.json'
                : p.join(outside.path, 'data.json'),
          );
          Link(manifest).createSync('link');
        }
        final spy = _RecordingSkinFileAccess();
        final before = observeState();
        final result = await runPreflight(skinFileAccess: spy);
        if (form == 'internal') {
          acceptedAllowlist(result);
        } else {
          expect(
            rejectionOf(result),
            NewOwnerRetentionRejection.skinPackageUnreadable,
          );
          expect(
            spy.operations.where((op) => op.startsWith('canonicalPath:')),
            isNot(contains(contains('skin-manifest.json'))),
          );
        }
        expect(
          spy.operations.where((op) => op.contains(outside.path)),
          isEmpty,
        );
        expectNoStateChange(before);
      });
    }
    test('records every inspected path of an accepted selection', () async {
      seedSkin('streamline.js');
      final spy = _RecordingSkinFileAccess();
      final before = observeState();

      final allowlist = acceptedAllowlist(
        await runPreflight(skinFileAccess: spy),
      );

      final packagePath = canonicalWebUiPath('streamline.js');
      final logicalPackagePath = p.join(webUiDir.path, 'streamline.js');
      expect(allowlist.skin.directoryName, 'streamline.js');
      expect(spy.operations, contains('list:${webUiDir.path}'));
      expect(spy.operations, contains('type-:$logicalPackagePath'));
      expect(spy.operations, contains('canonicalPath:$logicalPackagePath'));
      expect(
        spy.operations,
        contains(
          'readBoundedText:${p.join(packagePath, 'skin-manifest.json')}',
        ),
      );
      expect(
        spy.operations,
        contains('probeReadableFile:${p.join(packagePath, 'index.html')}'),
      );
      expect(spy.contentReads, isNotEmpty);
      for (final read in spy.contentReads) {
        expect(
          read,
          anyOf(
            startsWith('readBoundedText:$packagePath'),
            startsWith('probeReadableFile:$packagePath'),
          ),
        );
      }
      expectNoStateChange(before);
    });

    test('rejects an external manifest link without following it', () async {
      seedSkin('streamline.js');
      final external = File(p.join(workspace.path, 'external-manifest.json'))
        ..writeAsStringSync(jsonEncode({'id': 'insight', 'name': 'insight'}));
      seedSkin('insight', manifestLinkTarget: external.path);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final spy = _RecordingSkinFileAccess();
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(skinFileAccess: spy)),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );

      final manifestPath = canonicalWebUiPath(
        p.join('insight', 'skin-manifest.json'),
      );
      expect(spy.operations, contains('linkTarget:$manifestPath'));
      expect(spy.canonicalised, isNot(contains('canonicalPath:$manifestPath')));
      expect(
        spy.operations.where((op) => op.contains(external.path)),
        isEmpty,
        reason: 'the external manifest target was inspected',
      );
      expectNoStateChange(before);
    });

    test('rejects an external index.html link without following it', () async {
      seedSkin('streamline.js');
      final external = File(p.join(workspace.path, 'external-index.html'))
        ..writeAsStringSync('<html></html>');
      seedSkin('insight', indexLinkTarget: external.path);
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final spy = _RecordingSkinFileAccess();
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(skinFileAccess: spy)),
        NewOwnerRetentionRejection.skinPackageUnreadable,
      );

      final entryPointPath = canonicalWebUiPath(
        p.join('insight', 'index.html'),
      );
      expect(spy.operations, contains('linkTarget:$entryPointPath'));
      expect(
        spy.canonicalised,
        isNot(contains('canonicalPath:$entryPointPath')),
      );
      expect(spy.operations.where((op) => op.contains(external.path)), isEmpty);
      expectNoStateChange(before);
    });

    test(
      'rejects an external package directory link before following it',
      () async {
        seedSkin('streamline.js');
        final outside = Directory(p.join(workspace.path, 'outside-skin'))
          ..createSync();
        File(p.join(outside.path, 'skin-manifest.json')).writeAsStringSync(
          jsonEncode({'id': 'escape-skin', 'name': 'escape-skin'}),
        );
        final linkPath = p.join(webUiDir.path, 'escape-skin');
        Link(linkPath)
            .createSync(p.relative(outside.path, from: webUiDir.path));
        platform.values[SettingsKeys.defaultSkinId.name] = 'escape-skin';
        final spy = _RecordingSkinFileAccess();
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(skinFileAccess: spy)),
          NewOwnerRetentionRejection.skinPackageEscaped,
        );
        expect(spy.operations, contains('linkTarget:$linkPath'));
        expect(spy.canonicalised, isNot(contains('canonicalPath:$linkPath')));
        expect(
          spy.operations.where((op) => op.contains(outside.path)),
          isEmpty,
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects an unreadable manifest without reading its content',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight', manifestAsDirectory: true);
        platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
        final spy = _RecordingSkinFileAccess();
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(skinFileAccess: spy)),
          NewOwnerRetentionRejection.skinPackageUnreadable,
        );

        final manifestPath = canonicalWebUiPath(
          p.join('insight', 'skin-manifest.json'),
        );
        expect(spy.operations, contains('type-:$manifestPath'));
        expect(
          spy.operations,
          isNot(contains('readBoundedText:$manifestPath')),
        );
        expectNoStateChange(before);
      },
    );

    test(
      'rejects a runtime path outside the managed root without inspection',
      () async {
        seedSkin('streamline.js');
        final outside = Directory(p.join(workspace.path, 'outside-skin'))
          ..createSync();
        File(p.join(outside.path, 'index.html'))
            .writeAsStringSync('<html></html>');
        final spy = _RecordingSkinFileAccess();
        final before = observeState();

        expect(
          rejectionOf(
            await runPreflight(
              declaredOverride: SkinOverride.path(outside.path),
              skinFileAccess: spy,
            ),
          ),
          NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
        );
        expect(spy.operations, isEmpty);
        expectNoStateChange(before);
      },
    );
  });

  group('runtime serving reconciliation', () {
    const entryPort = 3019;

    WebUIService? serving;

    setUp(() {
      WebUIService.resolveWifiIP = () async => 'localhost';
      WebUIService.skinPortRangeStart = 27000;
      WebUIService.skinPortRangeSize = 32;
      WebUIService.aliasBindBarrier = null;
    });

    tearDown(() async {
      WebUIService.aliasBindBarrier = null;
      await serving?.stopServing();
      serving = null;
    });

    Future<WebUIService> serve(String path) async {
      final service = WebUIService(
        listLocalAddresses: () async => const <String>[],
      );
      serving = service;
      await service.serveFolderAtPath(path, port: entryPort);
      return service;
    }

    test('rejects a different managed package actually served', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      final service = await serve(p.join(webUiDir.path, 'insight'));
      final generation = service.serveGeneration.value;
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(runtimeOwner: service)),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expect(service.serveGeneration.value, generation);
      expect(service.serverPath(), p.join(webUiDir.path, 'insight'));
      expectNoStateChange(before);
    });

    test('rejects an unmanaged path actually served', () async {
      seedSkin('streamline.js');
      final outside = Directory(p.join(workspace.path, 'outside-skin'))
        ..createSync();
      File(p.join(outside.path, 'index.html'))
          .writeAsStringSync('<html></html>');
      final service = await serve(outside.path);
      final spy = _RecordingSkinFileAccess();
      final generation = service.serveGeneration.value;
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(runtimeOwner: service, skinFileAccess: spy),
        ),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expect(spy.operations, isEmpty);
      expect(service.serveGeneration.value, generation);
      expect(service.observeServingSelection().servedPath, outside.path);
      expectNoStateChange(before);
    });

    test('accepts a served selection naming the selected default', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final service = await serve(p.join(webUiDir.path, 'insight'));
      final generation = service.serveGeneration.value;
      final before = observeState();

      final allowlist = acceptedAllowlist(
        await runPreflight(runtimeOwner: service),
      );

      expect(allowlist.skin.skinId, 'insight');
      expect(allowlist.skin.directoryName, 'insight');
      expect(service.serveGeneration.value, generation);
      expectNoStateChange(before);
    });

    test('accepts an owner that is explicitly not serving', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      final service = WebUIService(
        listLocalAddresses: () async => const <String>[],
      );
      serving = service;
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      final before = observeState();

      final allowlist = acceptedAllowlist(
        await runPreflight(runtimeOwner: service),
      );

      expect(service.isServing, isFalse);
      expect(allowlist.skin.skinId, 'insight');
      expectNoStateChange(before);
    });

    test('rejects an absent runtime serving owner', () async {
      seedSkin('streamline.js');
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(omitRuntimeOwner: true)),
        NewOwnerRetentionRejection.skinServingSelectionUnavailable,
      );
      expectNoStateChange(before);
    });

    test('rejects a runtime owner that cannot be observed', () async {
      seedSkin('streamline.js');
      final before = observeState();

      expect(
        rejectionOf(
          await runPreflight(runtimeOwner: _ThrowingServingSelection()),
        ),
        NewOwnerRetentionRejection.skinServingSelectionUnreadable,
      );
      expectNoStateChange(before);
    });

    test('rejects an inactive other managed package after recovery', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      final otherPackage = p.join(webUiDir.path, 'insight');
      final service = await serve(otherPackage);
      final generation = service.serveGeneration.value;
      await service.closeSkinListenerForTesting();
      expect(service.isServing, isTrue);
      final before = observeState();

      expect(
        rejectionOf(await runPreflight(runtimeOwner: service)),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );

      await service.recover().timeout(const Duration(seconds: 15));

      expect(service.isServing, isTrue);
      expect(service.serveGeneration.value, generation + 1);
      expect(service.observeServingSelection().servedPath, otherPackage);
      expect(
        rejectionOf(await runPreflight(runtimeOwner: service)),
        NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
      );
      expectNoStateChange(before);
    });

    test(
      'rejects a declared path that disagrees with the served one',
      () async {
        seedSkin('streamline.js');
        seedSkin('insight');
        final service = await serve(p.join(webUiDir.path, 'streamline.js'));
        service.skinOverride = SkinOverride.path(
          p.join(webUiDir.path, 'insight'),
        );
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(runtimeOwner: service)),
          NewOwnerRetentionRejection.runtimeSkinSelectionUnsupported,
        );
        expectNoStateChange(before);
      },
    );
  });

  group('legacy saved skin selection', () {
    void seedLegacySelected(String skinId) =>
        legacyPreferences.values['flutter.selected_webui_skin_id'] = skinId;

    test('rejects a saved skin that disagrees with the default', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      seedLegacySelected('insight');
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.skinSelectionDisagreement,
      );
      expect(legacyPreferences.reads, isNotEmpty);
      expect(platform.reads, isNot(contains('selected_webui_skin_id')));
      expectNoStateChange(before);
    });

    test('accepts an equivalent normalized alias of the default', () async {
      seedSkin('streamline.js');
      platform.values[SettingsKeys.defaultSkinId.name] =
          'streamline_project-main';
      seedLegacySelected('streamline.js');
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'streamline.js');
      expectNoStateChange(before);
    });

    test(
      'rejects a saved legacy alias beside its own managed package',
      () async {
        seedSkin('streamline.js');
        seedSkin('streamline_project-main');
        final service = WebUIService(
          listLocalAddresses: () async => const <String>[],
        );
        seedLegacySelected('streamline_project-main');
        final before = observeState();

        expect(
          rejectionOf(await runPreflight(runtimeOwner: service)),
          NewOwnerRetentionRejection.skinSelectionDisagreement,
        );
        expect(service.isServing, isFalse);
        expectNoStateChange(before);
      },
    );

    test(
      'accepts a canonical saved skin when only the default aliases',
      () async {
        seedSkin('streamline.js');
        seedSkin('streamline_project-main');
        platform.values[SettingsKeys.defaultSkinId.name] =
            'streamline_project-main';
        seedLegacySelected('streamline.js');
        final before = observeState();

        final allowlist = acceptedAllowlist(await runPreflight());

        expect(allowlist.skin.skinId, 'streamline.js');
        expect(allowlist.skin.directoryName, 'streamline.js');
        expectNoStateChange(before);
      },
    );

    test('reads the absent legacy selection from its own backend', () async {
      seedSkin('streamline.js');
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'streamline.js');
      expect(legacyPreferences.reads, isNotEmpty);
      expect(platform.reads, isNot(contains('selected_webui_skin_id')));
      expectNoStateChange(before);
    });

    test('accepts a saved skin that names the selected default', () async {
      seedSkin('streamline.js');
      seedSkin('insight');
      platform.values[SettingsKeys.defaultSkinId.name] = 'insight';
      seedLegacySelected('insight');
      final before = observeState();

      final allowlist = acceptedAllowlist(await runPreflight());

      expect(allowlist.skin.skinId, 'insight');
      expectNoStateChange(before);
    });

    test('reports a legacy selection read failure distinctly', () async {
      seedSkin('streamline.js');
      legacyPreferences.failReads = true;
      final before = observeState();

      expect(
        rejectionOf(await runPreflight()),
        NewOwnerRetentionRejection.legacySkinSelectionUnreadable,
      );
      expect(
        platform.reads,
        containsAllInOrder([
          SettingsKeys.preferredMachineId.name,
          SettingsKeys.preferredScaleId.name,
          SettingsKeys.defaultSkinId.name,
        ]),
      );
      expectNoStateChange(before);
    });
  });

  group('plugin-backed preferred scales', () {
    for (final transport in [TransportType.ble, TransportType.unknown]) {
      test(
        'rejects an owner-built plugin scale over ${transport.name}',
        () async {
          seedSkin('streamline.js');
          final scale = PluginScale(
            deviceId: 'plugin:com.example.scale:driver-a:instance-a',
            name: 'Plugin Scale',
            capabilities: {},
            invoke: (operation, payload) async => {},
            transportType: transport,
          );
          addTearDown(scale.dispose);
          platform.values[SettingsKeys.preferredScaleId.name] = scale.deviceId;
          platform.values[SettingsKeys.rememberedDevices.name] =
              ownerEncodedRegistry(scale);
          final before = observeState();

          expect(
            rejectionOf(await runPreflight()),
            NewOwnerRetentionRejection.preferredScalePluginUnsupported,
          );
          expectNoStateChange(before);
        },
      );
    }
  });
}
