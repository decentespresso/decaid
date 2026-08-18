import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

class UpdateCheckService {
  final Logger _log = Logger('UpdateCheckService');
  final SettingsService _settingsService;
  final AndroidUpdater _updater;
  final WebUIStorage _webUIStorage;
  final PluginSourceService? _pluginSourceService;

  final bool _isAndroid;

  final bool _isMacOS;

  Timer? _periodicTimer;
  UpdateInfo? _availableUpdate;

  late final BehaviorSubject<AppUpdateState> _state;

  static const Duration _checkInterval =
      (String.fromEnvironment("simulate") == "1")
      ? Duration(hours: 1)
      : Duration(hours: 12);

  UpdateCheckService({
    required SettingsService settingsService,
    AndroidUpdater? updater,
    required WebUIStorage webUIStorage,
    PluginSourceService? pluginSourceService,
    bool? platformIsAndroid,
    bool? platformIsMacOS,
  }) : _settingsService = settingsService,
       _updater = updater ?? AndroidUpdater(owner: 'tadelv', repo: 'reaprime'),
       _webUIStorage = webUIStorage,
       _pluginSourceService = pluginSourceService,
       _isAndroid = platformIsAndroid ?? Platform.isAndroid,
       _isMacOS = platformIsMacOS ?? Platform.isMacOS {
    _state = BehaviorSubject.seeded(_snapshot(AppUpdatePhase.idle));
  }

  UpdateInfo? get availableUpdate => _availableUpdate;

  bool get hasAvailableUpdate => _availableUpdate != null;

  Stream<AppUpdateState> get updateState => _state.stream;

  AppUpdateState get currentState => _state.value;

  bool get canInstall => _isAndroid;

  AppUpdateState _snapshot(
    AppUpdatePhase phase, {
    double? progress,
    String? error,
  }) {
    final update = _availableUpdate;
    final hasUpdate = update != null;
    return AppUpdateState(
      phase: phase,
      currentVersion: BuildInfo.version,
      latestVersion: update?.version,
      releaseNotes: update?.releaseNotes,
      releaseUrl: hasUpdate ? getReleaseUrl()! : getReleasesUrl(),
      installable: _isAndroid && hasUpdate,
      progress: progress,
      error: error,
    );
  }

  void _emit(AppUpdatePhase phase, {double? progress, String? error}) {
    _state.add(_snapshot(phase, progress: progress, error: error));
  }

  bool get _inProgress => const {
    AppUpdatePhase.checking,
    AppUpdatePhase.downloading,
    AppUpdatePhase.installing,
  }.contains(_state.value.phase);

  Future<void> requestCheck() async {
    if (_inProgress) return;
    await checkForUpdate();
  }

  Future<void> downloadAndInstall() async {
    if (_inProgress) return;
    if (!_isAndroid) return;

    if (_availableUpdate == null) {
      await checkForUpdate();
      if (_availableUpdate == null) {
        return;
      }
    }

    final update = _availableUpdate!;
    try {
      _emit(AppUpdatePhase.downloading, progress: 0);
      var lastEmitted = 0.0;
      final path = await _updater.downloadUpdate(
        update,
        onProgress: (p) {
          if (p - lastEmitted >= 0.01 || p >= 1.0) {
            lastEmitted = p;
            _emit(AppUpdatePhase.downloading, progress: p);
          }
        },
      );

      _emit(AppUpdatePhase.installing);
      final started = await _updater.installUpdate(path);
      if (!started) {
        _emit(
          AppUpdatePhase.error,
          error: 'Installation permission required. Grant it and retry.',
        );
      }
    } catch (e, st) {
      _log.severe('Update download/install failed', e, st);
      _emit(AppUpdatePhase.error, error: 'Update failed: $e');
    }
  }

  Future<void> initialize() async {
    final automaticUpdateCheck = await _settingsService.automaticUpdateCheck();
    if (automaticUpdateCheck) {
      await _startPeriodicChecks();
    }
  }

  Future<void> _startPeriodicChecks() async {
    _log.info(
      'Starting periodic update checks (every ${_checkInterval.inHours} hours)'
      '${_isMacOS ? ' [skins only — Sparkle owns macOS app updates]' : ''}',
    );

    if (_isMacOS) {
      await _updateManagedContent();
    } else {
      final lastCheck = await _settingsService.lastUpdateCheckTime();
      if (lastCheck == null ||
          DateTime.now().difference(lastCheck) > _checkInterval) {
        await checkForUpdate();
        await _updateManagedContent();
      }
    }

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_checkInterval, (_) async {
      if (!_isMacOS) {
        await checkForUpdate();
      }
      await _updateManagedContent();
    });
  }

  void _stopPeriodicChecks() {
    _log.info('Stopping periodic update checks');
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  Future<void> _updateManagedContent() async {
    try {
      _log.info('Updating skins...');
      await _webUIStorage.updateAllSkins();
      _log.info('Skin update complete');
    } catch (e, st) {
      _log.warning('Error updating skins', e, st);
    }

    final pluginSourceService = _pluginSourceService;
    if (pluginSourceService == null) return;
    try {
      _log.info('Updating plugins...');
      await pluginSourceService.updateAllPlugins();
      _log.info('Plugin update complete');
    } catch (e, st) {
      _log.warning('Error updating plugins', e, st);
    }
  }

  Future<UpdateInfo?> checkForUpdate() async {
    if (_isMacOS) {
      _log.info('macOS app updates are owned by Sparkle; skipping APK check');
      return null;
    }
    try {
      _emit(AppUpdatePhase.checking);
      _log.info('Checking for updates (current: ${BuildInfo.version})');

      final updateInfo = await _updater.checkForUpdate(
        BuildInfo.version,
        channel: await _settingsService.updateChannel(),
      );

      await _settingsService.setLastUpdateCheckTime(DateTime.now());

      if (updateInfo != null) {
        final skipped = await _settingsService.skippedVersion();
        if (skipped != null && skipped == updateInfo.version) {
          _log.info('Update ${updateInfo.version} skipped by user');
          _availableUpdate = null;
        } else {
          _log.info('Update available: ${updateInfo.version}');
          _availableUpdate = updateInfo;
        }
      } else {
        _log.info('No update available');
        _availableUpdate = null;
      }

      _emit(
        _availableUpdate != null
            ? AppUpdatePhase.available
            : AppUpdatePhase.idle,
      );
      return updateInfo;
    } catch (e, stackTrace) {
      _log.warning('Error checking for updates', e, stackTrace);
      _emit(AppUpdatePhase.error, error: 'Update check failed: $e');
      return null;
    }
  }

  String getReleasesUrl() {
    return 'https://github.com/decentespresso/decaid/releases';
  }

  String? getReleaseUrl([UpdateInfo? update]) {
    final release = update ?? _availableUpdate;
    if (release == null) return null;
    return 'https://github.com/decentespresso/decaid/releases/tag/${release.tagName}';
  }

  Future<void> enableAutomaticChecks() async {
    await _settingsService.setAutomaticUpdateCheck(true);
    await _startPeriodicChecks();
  }

  Future<void> disableAutomaticChecks() async {
    await _settingsService.setAutomaticUpdateCheck(false);
    _stopPeriodicChecks();
    _availableUpdate = null;
  }

  void clearAvailableUpdate() {
    _availableUpdate = null;
    _emit(AppUpdatePhase.idle);
  }

  void debugForceUpdate({String version = '99.0.0', String? downloadUrl}) {
    _log.info('DEBUG: forcing fake update notification ($version)');
    _availableUpdate = UpdateInfo(
      version: version,
      downloadUrl:
          downloadUrl ??
          'https://github.com/decentespresso/decaid/releases/download/v0.7.7/decent-android-0.7.7.apk',
      releaseNotes: 'Forced update for testing the update API.',
      isPrerelease: false,
      tagName: 'v$version',
    );
    _emit(AppUpdatePhase.available);
  }

  Future<void> skipCurrentUpdate() async {
    final version = _availableUpdate?.version;
    if (version != null) {
      _log.info('User skipped update: $version');
      await _settingsService.setSkippedVersion(version);
    }
    _availableUpdate = null;
    _emit(AppUpdatePhase.idle);
  }

  void dispose() {
    _periodicTimer?.cancel();
    _updater.dispose();
    _state.close();
  }
}
