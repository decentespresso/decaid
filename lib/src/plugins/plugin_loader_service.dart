import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_runtime.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/util/safe_path.dart';

class PluginSettingsValidationException implements Exception {
  final String message;
  PluginSettingsValidationException(this.message);

  @override
  String toString() => message;
}

class PluginLoaderService {
  static const _loadTimeout = Duration(seconds: 1);
  static const _maxConsecutiveLoadFailures = 3;
  static const _loadingPluginKey = 'plugin.watchdog.loading';

  final PluginManager pluginManager;
  final CredentialStore? _credentialStore;
  final _log = Logger('PluginLoaderService');

  late Directory _pluginsDir;
  late SharedPreferences _prefs;
  final Map<String, PluginManifest> _availablePluginsCache = {};
  Map<String, Map<String, dynamic>> _volatileSecureSettings = {};
  Future<void> _pluginLoadQueue = Future.value();
  final Map<String, Future<void>> _pluginSettingsLocks = {};

  PluginLoaderService({
    required KeyValueStoreService kvStore,
    DecentProxyService? decentProxyService,
    CredentialStore? credentialStore,
  }) : _credentialStore = credentialStore,
       pluginManager = PluginManager(
         kvStore: kvStore,
         decentProxyService: decentProxyService,
       );

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      _log.fine('PluginLoaderService already initialized');
      return;
    }

    // Get application documents directory
    final appDocDir = await getApplicationDocumentsDirectory();
    _pluginsDir = Directory('${appDocDir.path}/plugins');

    // Initialize SharedPreferences
    _prefs = await SharedPreferences.getInstance();
    await _recoverInterruptedPluginLoad();

    // Create plugins directory if it doesn't exist
    if (!_pluginsDir.existsSync()) {
      _pluginsDir.createSync(recursive: true);
      _log.info('Created plugins directory: ${_pluginsDir.path}');
    }

    // Copy bundled plugins from assets
    await _copyBundledPlugins();

    // Scan for available plugins
    await _scanAvailablePlugins();

    // Load auto-load enabled plugins
    await _loadAutoLoadPlugins();

    _initialized = true;
  }

  /// Add plugin to REA plugins folder
  /// treated as "plugin installation"
  /// user will provide filesystem path and permissions, REA should copy the contents over to
  /// the plugins folder
  Future<void> addPlugin(String sourcePath) async {
    final source = File(sourcePath);
    final sourceDir = Directory(sourcePath);

    Directory sourceDirectory;
    File manifestFile;

    // Check if source is a file or directory
    if (source.existsSync()) {
      // It's a file - could be a zip or single plugin file
      // For now, we only support directory-based installation
      throw Exception(
        'File-based plugin installation not yet implemented. Please provide a directory path.',
      );
    } else if (sourceDir.existsSync()) {
      // It's a directory
      sourceDirectory = sourceDir;
      manifestFile = File('${sourceDirectory.path}/manifest.json');
      if (!manifestFile.existsSync()) {
        throw Exception('manifest.json not found in plugin directory');
      }
    } else {
      throw Exception('Source does not exist: $sourcePath');
    }

    final manifestJson = jsonDecode(await manifestFile.readAsString());
    final manifest = PluginManifest.fromJson(manifestJson);

    // The id becomes a directory name under the plugins root; reject anything
    // that is not exactly one safe path component before creating it.
    if (!isSafePathComponent(manifest.id)) {
      throw FormatException(
        'Unsafe plugin id "${manifest.id}": must be a single safe path component',
      );
    }

    // Create plugin directory in plugins folder
    final pluginDir = Directory('${_pluginsDir.path}/${manifest.id}');
    if (pluginDir.existsSync()) {
      throw Exception('Plugin already installed: ${manifest.id}');
    }

    pluginDir.createSync(recursive: true);

    // Copy all files from source to destination
    await _copyDirectory(sourceDirectory, pluginDir);

    // Add to cache
    _availablePluginsCache[manifest.id] = manifest;

    _log.info('Plugin installed: ${manifest.id}');
  }

  /// Remove/uninstall a plugin
  /// This will unload the plugin if it's loaded and delete its files
  Future<void> removePlugin(String pluginId) async {
    // The id would be joined into a filesystem path; reject unsafe ids
    // before any unload, cache, or directory operation.
    if (!isSafePathComponent(pluginId)) {
      throw FormatException(
        'Unsafe plugin id "$pluginId": must be a single safe path component',
      );
    }

    // Unload plugin if it's loaded
    if (isPluginLoaded(pluginId)) {
      await unloadPlugin(pluginId);
    }

    await _withPluginSettingsLock(pluginId, () async {
      await _deleteSecureSettings(pluginId);
      await _prefs.remove('plugin.settings.$pluginId');
      await _prefs.remove('plugin.autoload.$pluginId');
      await _prefs.remove(_loadFailureKey(pluginId));
      if (_prefs.getString(_loadingPluginKey) == pluginId) {
        await _prefs.remove(_loadingPluginKey);
      }

      final pluginDir = Directory('${_pluginsDir.path}/$pluginId');
      if (pluginDir.existsSync()) {
        await pluginDir.delete(recursive: true);
        _log.info('Plugin removed: $pluginId');
      }
      _availablePluginsCache.remove(pluginId);
    });
  }

  /// Load plugin into the runtime
  /// by using the PluginManager loadPlugin method
  Future<void> loadPlugin(String pluginId) {
    final load = _pluginLoadQueue.then((_) => _loadPlugin(pluginId));
    _pluginLoadQueue = load.then<void>((_) {}, onError: (_, _) {});
    return load;
  }

  Future<void> _loadPlugin(String pluginId) async {
    if (!_availablePluginsCache.containsKey(pluginId)) {
      throw Exception('Plugin not found: $pluginId');
    }

    final manifest = _availablePluginsCache[pluginId]!;
    final pluginDir = Directory('${_pluginsDir.path}/$pluginId');

    await _prefs.setString(_loadingPluginKey, pluginId);
    try {
      final pluginFile = File('${pluginDir.path}/plugin.js');
      if (!pluginFile.existsSync()) {
        throw Exception('plugin.js not found for plugin: $pluginId');
      }

      final jsCode = await pluginFile.readAsString();
      final settings = await _pluginSettingsForLoad(pluginId);

      await pluginManager
          .loadPlugin(
            id: pluginId,
            manifest: manifest,
            jsCode: jsCode,
            settings: settings,
          )
          .timeout(_loadTimeout);
    } catch (_) {
      await _prefs.remove(_loadingPluginKey);
      await _recordLoadFailure(pluginId);
      rethrow;
    }

    await _prefs.remove(_loadingPluginKey);
    await _prefs.remove(_loadFailureKey(pluginId));
    _log.info('Plugin loaded: $pluginId');
  }

  /// Unload a plugin
  /// by using the PluginManager unloadPlugin method
  Future<void> unloadPlugin(String pluginId) async {
    await pluginManager.unloadPlugin(pluginId);
    _log.info('Plugin unloaded: $pluginId');
  }

  /// Reload a plugin (unload and load again)
  /// Useful when plugin settings change
  Future<void> reloadPlugin(String pluginId) async {
    if (!isPluginLoaded(pluginId)) {
      throw Exception('Plugin not loaded: $pluginId');
    }

    _log.info('Reloading plugin: $pluginId');

    // Unload the plugin
    await unloadPlugin(pluginId);

    // Load the plugin again
    await loadPlugin(pluginId);

    // Note: Plugin should load its own settings from the saved location
    _log.info('Plugin reloaded: $pluginId');
  }

  /// Store a setting in prefs, whether a specific plugin should be autoloaded at initialize
  Future<void> setPluginAutoLoad(String pluginId, bool enabled) async {
    if (enabled) {
      await _prefs.remove(_loadFailureKey(pluginId));
      if (_prefs.getString(_loadingPluginKey) == pluginId) {
        await _prefs.remove(_loadingPluginKey);
      }
    }
    await _prefs.setBool('plugin.autoload.$pluginId', enabled);
  }

  /// Check if a plugin should be auto-loaded
  Future<bool> shouldAutoLoad(String pluginId) async {
    return _prefs.getBool('plugin.autoload.$pluginId') ?? false;
  }

  Future<Map<String, dynamic>> pluginSettings(String pluginId) =>
      _withPluginSettingsLock(pluginId, () async {
        final manifest = _availablePluginsCache[pluginId];
        if (manifest == null) return {};

        final stored = await _storedSettings(manifest);
        return {
          ...stored.ordinary,
          for (final key in _secureSettingKeys(manifest))
            key: {'isSet': stored.secure.containsKey(key)},
        };
      });

  Future<void> savePluginSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) => _withPluginSettingsLock(pluginId, () async {
    final manifest = _availablePluginsCache[pluginId];
    if (manifest == null) {
      throw Exception('Plugin not found: $pluginId');
    }

    _validateSettings(manifest, settings);
    final stored = await _storedSettings(manifest);
    final secureKeys = _secureSettingKeys(manifest);
    final ordinaryPatch = Map.fromEntries(
      settings.entries.where((entry) => !secureKeys.contains(entry.key)),
    );
    var secure = stored.secure;
    for (final entry in settings.entries.where(
      (entry) => secureKeys.contains(entry.key),
    )) {
      if (_isSecureState(entry.value)) continue;
      secure = entry.value == null
          ? Map.fromEntries(
              secure.entries.where((current) => current.key != entry.key),
            )
          : {...secure, entry.key: entry.value};
    }

    final mergedOrdinary = {...stored.ordinary, ...ordinaryPatch};
    for (final entry in ordinaryPatch.entries) {
      if (entry.value == null) mergedOrdinary.remove(entry.key);
    }

    await _writeSecureSettings(pluginId, secure);
    await _writeOrdinarySettings(pluginId, mergedOrdinary);

    _log.fine('Settings saved for plugin: $pluginId');
  });

  /// Get a list of all the available plugins
  List<PluginManifest> get availablePlugins {
    return _availablePluginsCache.values.toList();
  }

  /// Get a specific plugin's manifest
  PluginManifest? getPluginManifest(String pluginId) {
    return _availablePluginsCache[pluginId];
  }

  /// Check if a plugin is currently loaded
  bool isPluginLoaded(String pluginId) {
    return pluginManager.loadedPlugins.any(
      (plugin) => plugin.pluginId == pluginId,
    );
  }

  /// Get the directory path for a specific plugin
  String getPluginDirectory(String pluginId) {
    if (!isSafePathComponent(pluginId)) {
      throw FormatException(
        'Unsafe plugin id "$pluginId": must be a single safe path component',
      );
    }
    if (!_availablePluginsCache.containsKey(pluginId)) {
      throw Exception('Plugin not found: $pluginId');
    }
    return '${_pluginsDir.path}/$pluginId';
  }

  /// Check if a plugin is bundled with the app (from assets)
  Future<bool> isPluginBundled(String pluginId) async {
    final bundledPlugins = await _getBundledPluginPaths();
    for (final pluginPath in bundledPlugins) {
      final pluginName = pluginPath.split('/').last;
      if (pluginName == pluginId) {
        return true;
      }
    }
    return false;
  }

  /// Get a list of currently loaded plugins
  /// from PluginManager
  List<PluginRuntime> get loadedPlugins {
    return pluginManager.loadedPlugins;
  }

  // Private helper methods

  String _loadFailureKey(String pluginId) =>
      'plugin.watchdog.loadFailures.$pluginId';

  String _settingsKey(String pluginId) => 'plugin.settings.$pluginId';

  String _secureSettingsKey(String pluginId) =>
      'plugin.settings.secure.$pluginId';

  Future<T> _withPluginSettingsLock<T>(
    String pluginId,
    Future<T> Function() action,
  ) {
    final previous = _pluginSettingsLocks[pluginId] ?? Future<void>.value();
    final next = Completer<void>();
    _pluginSettingsLocks[pluginId] = next.future;
    return previous.then((_) => action()).whenComplete(() {
      next.complete();
      if (identical(_pluginSettingsLocks[pluginId], next.future)) {
        _pluginSettingsLocks.remove(pluginId);
      }
    });
  }

  Set<String> _secureSettingKeys(PluginManifest manifest) => {
    for (final entry in manifest.settings.entries)
      if (entry.value is Map && entry.value['secure'] == true) entry.key,
  };

  bool _isSecureState(dynamic value) =>
      value is Map && value.length == 1 && value['isSet'] is bool;

  Future<Map<String, dynamic>> _pluginSettingsForLoad(String pluginId) =>
      _withPluginSettingsLock(pluginId, () async {
        final manifest = _availablePluginsCache[pluginId];
        if (manifest == null) {
          throw Exception('Plugin not found: $pluginId');
        }
        final stored = await _storedSettings(manifest);
        return {...stored.ordinary, ...stored.secure};
      });

  Future<({Map<String, dynamic> ordinary, Map<String, dynamic> secure})>
  _storedSettings(PluginManifest manifest) async {
    final ordinary = _readOrdinarySettings(manifest.id);
    final secureKeys = _secureSettingKeys(manifest);
    final storedSecure = await _readSecureSettings(manifest.id);
    final secure = Map.fromEntries(
      storedSecure.entries.where((entry) => secureKeys.contains(entry.key)),
    );
    if (secure.length != storedSecure.length) {
      await _writeSecureSettings(manifest.id, secure);
    }
    final legacySecure = Map.fromEntries(
      ordinary.entries.where((entry) => secureKeys.contains(entry.key)),
    );
    if (legacySecure.isEmpty) {
      return (ordinary: ordinary, secure: secure);
    }

    final migratedSecure = {...legacySecure, ...secure};
    final migratedOrdinary = Map.fromEntries(
      ordinary.entries.where((entry) => !secureKeys.contains(entry.key)),
    );
    await _writeSecureSettings(manifest.id, migratedSecure);
    await _writeOrdinarySettings(manifest.id, migratedOrdinary);
    return (ordinary: migratedOrdinary, secure: migratedSecure);
  }

  Map<String, dynamic> _readOrdinarySettings(String pluginId) {
    final settingsJson = _prefs.getString(_settingsKey(pluginId));
    if (settingsJson == null) return {};

    try {
      return Map<String, dynamic>.from(jsonDecode(settingsJson));
    } catch (e) {
      _log.warning('Failed to parse settings for plugin $pluginId', e);
      return {};
    }
  }

  Future<Map<String, dynamic>> _readSecureSettings(String pluginId) async {
    if (_credentialStore == null) {
      return Map.from(_volatileSecureSettings[pluginId] ?? {});
    }
    final settingsJson = await _credentialStore.read(
      key: _secureSettingsKey(pluginId),
    );
    if (settingsJson == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(settingsJson));
    } catch (_) {
      throw StateError('Secure settings for plugin $pluginId are invalid');
    }
  }

  Future<void> _writeOrdinarySettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    if (settings.isEmpty) {
      await _prefs.remove(_settingsKey(pluginId));
      if (_prefs.containsKey(_settingsKey(pluginId))) {
        throw StateError('Failed to remove settings for plugin $pluginId');
      }
      return;
    }
    final saved = await _prefs.setString(
      _settingsKey(pluginId),
      jsonEncode(settings),
    );
    if (!saved) {
      throw StateError('Failed to save settings for plugin $pluginId');
    }
  }

  Future<void> _writeSecureSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    if (_credentialStore == null) {
      if (settings.isEmpty) {
        _volatileSecureSettings = Map.fromEntries(
          _volatileSecureSettings.entries.where(
            (entry) => entry.key != pluginId,
          ),
        );
      } else {
        _volatileSecureSettings = {
          ..._volatileSecureSettings,
          pluginId: Map.from(settings),
        };
      }
      return;
    }
    if (settings.isEmpty) {
      await _credentialStore.delete(key: _secureSettingsKey(pluginId));
      return;
    }
    await _credentialStore.write(
      key: _secureSettingsKey(pluginId),
      value: jsonEncode(settings),
    );
  }

  Future<void> _deleteSecureSettings(String pluginId) async {
    _volatileSecureSettings = Map.fromEntries(
      _volatileSecureSettings.entries.where((entry) => entry.key != pluginId),
    );
    await _credentialStore?.delete(key: _secureSettingsKey(pluginId));
  }

  Future<void> _recordLoadFailure(String pluginId) async {
    final failureKey = _loadFailureKey(pluginId);
    final failures = (_prefs.getInt(failureKey) ?? 0) + 1;
    await _prefs.setInt(failureKey, failures);
    if (failures < _maxConsecutiveLoadFailures) return;

    await _prefs.setBool('plugin.autoload.$pluginId', false);
    _log.warning(
      'Disabled auto-load for plugin $pluginId after $failures consecutive load failures',
    );
  }

  Future<void> _recoverInterruptedPluginLoad() async {
    final pluginId = _prefs.getString(_loadingPluginKey);
    if (pluginId == null) return;

    await _prefs.setInt(_loadFailureKey(pluginId), _maxConsecutiveLoadFailures);
    await _prefs.setBool('plugin.autoload.$pluginId', false);
    await _prefs.remove(_loadingPluginKey);
    _log.warning(
      'Disabled auto-load for plugin $pluginId after an interrupted load',
    );
  }

  Future<void> _copyBundledPlugins() async {
    // Get list of bundled plugins from assets
    final bundledPlugins = await _getBundledPluginPaths();

    for (final pluginPath in bundledPlugins) {
      try {
        final pluginName = pluginPath.split('/').last;
        final destDir = Directory('${_pluginsDir.path}/$pluginName');

        // Check if plugin already exists in destination
        final isNewPlugin = !destDir.existsSync() || destDir.listSync().isEmpty;

        if (isNewPlugin) {
          // Create destination directory
          destDir.createSync(recursive: true);

          // Copy manifest.json
          final manifestAsset = await rootBundle.loadString(
            '$pluginPath/manifest.json',
          );
          File(
            '${destDir.path}/manifest.json',
          ).writeAsStringSync(manifestAsset);

          // Copy plugin.js
          final pluginAsset = await rootBundle.loadString(
            '$pluginPath/plugin.js',
          );
          File('${destDir.path}/plugin.js').writeAsStringSync(pluginAsset);

          _log.fine('Copied bundled plugin: $pluginName');
          continue;
        }

        // Read version from manifest, overwrite if our version is newer
        // In non-release builds, always overwrite to pick up development changes
        final manifestAsset = await rootBundle.loadString(
          '$pluginPath/manifest.json',
        );
        if (kReleaseMode) {
          final newManifest = PluginManifest.fromJson(
            jsonDecode(manifestAsset),
          );
          final existingManifestFile = File('${destDir.path}/manifest.json');
          final existingManifest = PluginManifest.fromJson(
            jsonDecode(await existingManifestFile.readAsString()),
          );
          if (_compareVersions(newManifest.version, existingManifest.version) <=
              0) {
            // existing plugin has same or newer version
            _log.fine(
              "not overriding bundled plugin: [bundled: ${newManifest.version}], [existing: ${existingManifest.version}]",
            );
            continue;
          }
        }
        File('${destDir.path}/manifest.json').writeAsStringSync(manifestAsset);

        // Copy plugin.js
        final pluginAsset = await rootBundle.loadString(
          '$pluginPath/plugin.js',
        );
        File('${destDir.path}/plugin.js').writeAsStringSync(pluginAsset);

        _log.fine('Updated bundled plugin: $pluginName');
      } catch (e) {
        _log.warning('Failed to copy bundled plugins', e);
      }
    }
  }

  /// Compares two semver-style version strings numerically.
  /// Returns negative if a < b, zero if equal, positive if a > b.
  static int _compareVersions(String a, String b) {
    final partsA = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final partsB = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = partsA.length > partsB.length ? partsA.length : partsB.length;
    for (var i = 0; i < len; i++) {
      final va = i < partsA.length ? partsA[i] : 0;
      final vb = i < partsB.length ? partsB[i] : 0;
      if (va != vb) return va - vb;
    }
    return 0;
  }

  Future<List<String>> _getBundledPluginPaths() async {
    // This is a simplified implementation
    // In a real app, you might want to:
    // 1. Read from a registry file in assets
    // 2. Scan the assets/plugins directory
    // 3. Read from pubspec.yaml

    // For now, return hardcoded list
    // You can extend this by adding more plugins as needed
    return [
      'assets/plugins/time-to-ready.reaplugin',
      'assets/plugins/visualizer.reaplugin',
      'assets/plugins/settings.reaplugin',
      'assets/plugins/dye2.reaplugin',
      'assets/plugins/decent-profile.reaplugin',
      'assets/plugins/shot-upload.reaplugin',
      // Add more bundled plugins here as they are added to the app
    ];
  }

  Future<void> _scanAvailablePlugins() async {
    _availablePluginsCache.clear();

    if (!_pluginsDir.existsSync()) {
      return;
    }

    final directories = _pluginsDir.listSync().whereType<Directory>();

    for (final dir in directories) {
      try {
        final manifestFile = File('${dir.path}/manifest.json');
        if (!manifestFile.existsSync()) {
          continue;
        }

        final manifestJson = jsonDecode(await manifestFile.readAsString());
        final manifest = PluginManifest.fromJson(manifestJson);

        // An unsafe id must not enter the cache, where it could later drive
        // filesystem paths (issue #547 follow-up).
        if (!isSafePathComponent(manifest.id)) {
          _log.warning(
            'Skipping plugin with unsafe id "${manifest.id}" at ${dir.path}',
          );
          continue;
        }

        _availablePluginsCache[manifest.id] = manifest;
        _log.fine('Found plugin: ${manifest.id}');
      } catch (e) {
        _log.warning('Failed to load plugin manifest from ${dir.path}', e);
      }
    }
  }

  Future<void> _loadAutoLoadPlugins() async {
    // First, ensure bundled plugins have auto-load enabled by default
    await _ensureBundledPluginsAutoLoadEnabled();

    // Then load all plugins with auto-load enabled
    for (final pluginId in _availablePluginsCache.keys) {
      final shouldLoad = await shouldAutoLoad(pluginId);
      if (shouldLoad) {
        try {
          await loadPlugin(pluginId);
        } catch (e) {
          _log.warning('Failed to auto-load plugin $pluginId', e);
        }
      }
    }
  }

  Future<void> _ensureBundledPluginsAutoLoadEnabled() async {
    try {
      // Get list of bundled plugins from assets
      final bundledPlugins = await _getBundledPluginPaths();

      for (final pluginPath in bundledPlugins) {
        final pluginName = pluginPath.split('/').last;
        final pluginDir = Directory('${_pluginsDir.path}/$pluginName');

        // Check if this is a bundled plugin directory
        if (!pluginDir.existsSync()) {
          continue;
        }

        // Load manifest to get plugin ID
        final manifestFile = File('${pluginDir.path}/manifest.json');
        if (!manifestFile.existsSync()) {
          continue;
        }

        final manifestJson = jsonDecode(await manifestFile.readAsString());
        final manifest = PluginManifest.fromJson(manifestJson);

        // For bundled plugins, set auto-load to true by default if not already set
        final autoLoadKey = 'plugin.autoload.${manifest.id}';
        if (!_prefs.containsKey(autoLoadKey)) {
          // First time seeing this bundled plugin, enable auto-load by default
          await _prefs.setBool(autoLoadKey, true);
          _log.info(
            'Set auto-load enabled by default for bundled plugin: ${manifest.id}',
          );
        }
      }
    } catch (e) {
      _log.warning('Failed to ensure bundled plugins auto-load enabled', e);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: false)) {
      if (entity is File) {
        final newFile = File('${destination.path}/${p.basename(entity.path)}');
        await entity.copy(newFile.path);
      } else if (entity is Directory) {
        final newDir = Directory(
          '${destination.path}/${p.basename(entity.path)}',
        );
        newDir.createSync(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  void _validateSettings(
    PluginManifest manifest,
    Map<String, dynamic> settings,
  ) {
    // Get settings schema from manifest
    final manifestSettings = manifest.settings;

    // If manifest has no settings schema, accept any settings
    if (manifestSettings.isEmpty) {
      return;
    }

    // Validate each setting against schema
    for (final key in settings.keys) {
      if (!manifestSettings.containsKey(key)) {
        throw PluginSettingsValidationException(
          'Setting "$key" not defined in plugin manifest',
        );
      }

      // TODO: Add more sophisticated validation based on schema type
      // For now, just check that the key exists in manifest
    }
  }

  /// Nukes the plugins folder
  Future<void> reset() async {
    for (var plugin in availablePlugins) {
      final path = getPluginDirectory(plugin.id);
      final dir = Directory(path);
      await dir.delete(recursive: true);
    }
  }
}
