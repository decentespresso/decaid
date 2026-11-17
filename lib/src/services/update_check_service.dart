import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:rxdart/rxdart.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
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
  final bool externallyManaged;

  final bool _isMacOS;

  Timer? _periodicTimer;
  UpdateInfo? _availableUpdate;
  bool _hasCompletedCheck = false;
  Future<String>? _download;
  Future<bool>? _installation;
  bool _installationStarted = false;
  bool _resumedDuringInstallation = false;
  String? _downloadedPath;
  (String, String)? _downloadedRelease;
  int _operationRevision = 0;

  late final BehaviorSubject<AppUpdateState> _state;

  static const Duration _checkInterval =
      (String.fromEnvironment("simulate") == "1")
      ? Duration(hours: 1)
      : Duration(hours: 12);

  UpdateCheckService({
    required this._settingsService,
    AndroidUpdater? updater,
    required this._webUIStorage,
    this._pluginSourceService,
    bool? platformIsAndroid,
    bool? platformIsMacOS,
    GithubRateLimit? rateLimit,
    GithubCredentialProvider? credentials,
    this.externallyManaged = BuildInfo.appStore,
  }) : _updater =
           updater ??
           AndroidUpdater(
             owner: 'tadelv',
             repo: 'reaprime',
             rateLimit: rateLimit,
             credentials: credentials,
           ),
       _isAndroid = platformIsAndroid ?? Platform.isAndroid,
       _isMacOS = platformIsMacOS ?? Platform.isMacOS {
    _state = BehaviorSubject.seeded(_snapshot(AppUpdatePhase.idle));
  }

  UpdateInfo? get availableUpdate =>
      externallyManaged ? null : _availableUpdate;

  bool get hasAvailableUpdate => availableUpdate != null;
  bool get hasCompletedCheck => _hasCompletedCheck;
  Future<String?> get skippedVersion => _settingsService.skippedVersion();

  Stream<AppUpdateState> get updateState => _state.stream;

  AppUpdateState get currentState => _state.value;

  bool get installationStarted => _installationStarted;

  void onAppResumed() {
    if (currentState.phase != AppUpdatePhase.installing) return;
    if (!_installationStarted) {
      _resumedDuringInstallation = true;
      return;
    }
    _installation = null;
    _installationStarted = false;
    _resumedDuringInstallation = false;
    _emit(hasAvailableUpdate ? AppUpdatePhase.available : AppUpdatePhase.idle);
  }

  String? get downloadedPath =>
      _downloadedRelease ==
          (_availableUpdate?.version, _availableUpdate?.downloadUrl)
      ? _downloadedPath
      : null;

  bool get canInstall => _isAndroid;

  bool get canCheck => !_isMacOS && !externallyManaged;

  AppUpdateState _snapshot(
    AppUpdatePhase phase, {
    double? progress,
    String? error,
  }) {
    final update = availableUpdate;
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
    if (!_state.isClosed) {
      _state.add(_snapshot(phase, progress: progress, error: error));
    }
  }

  bool get _inProgress => const {
    AppUpdatePhase.checking,
    AppUpdatePhase.downloading,
    AppUpdatePhase.installing,
  }.contains(_state.value.phase);

  Future<void> requestCheck() async {
    if (_inProgress) return;
    try {
      await checkForUpdate();
    } catch (e) {
      _log.fine('Manual update check failed; error state already emitted: $e');
    }
  }

  Future<void> downloadAndInstall() async {
    if (_inProgress) return;
    if (!_isAndroid) return;

    if (_availableUpdate == null) {
      try {
        await checkForUpdate();
      } catch (e, st) {
        _log.warning('Update check before install failed', e, st);
        return;
      }
      if (_availableUpdate == null) {
        return;
      }
    }

    try {
      final path = await downloadUpdate(_availableUpdate!, (_) {});
      await installUpdate(path);
    } catch (e) {
      _log.fine('Update failed; error state already emitted: $e');
    }
  }

  Future<String> downloadUpdate(
    UpdateInfo update,
    void Function(double) onProgress,
  ) {
    if (!_isAndroid ||
        externallyManaged ||
        update.version != availableUpdate?.version ||
        update.downloadUrl != availableUpdate?.downloadUrl) {
      return Future.error(StateError('The app update is no longer available'));
    }
    if (_download case final pending?) return pending;
    if (_installation != null ||
        currentState.phase == AppUpdatePhase.installing) {
      return Future.error(StateError('An app update operation is in progress'));
    }
    _installation = null;
    _installationStarted = false;
    return _download = _downloadUpdate(update, onProgress).whenComplete(() {
      _download = null;
    });
  }

  Future<String> _downloadUpdate(
    UpdateInfo update,
    void Function(double) onProgress,
  ) async {
    _operationRevision++;
    try {
      if (downloadedPath case final path?) {
        if (await _isUsableApk(path)) {
          _emit(AppUpdatePhase.available);
          return path;
        }
      }
      _downloadedPath = null;
      _downloadedRelease = null;
      _emit(AppUpdatePhase.downloading);
      double? lastEmitted;
      final path = await _updater.downloadUpdate(
        update,
        onProgress: (progress) {
          if (!progress.isFinite || progress < 0 || progress > 1) return;
          if (lastEmitted == null ||
              progress - lastEmitted! >= 0.01 ||
              progress >= 1) {
            lastEmitted = progress;
            _emit(AppUpdatePhase.downloading, progress: progress);
            onProgress(progress);
          }
        },
      );
      _downloadedPath = path;
      _downloadedRelease = (update.version, update.downloadUrl);
      _emit(AppUpdatePhase.available);
      return path;
    } catch (e, st) {
      _downloadedPath = null;
      _downloadedRelease = null;
      _log.warning('App update download failed', e, st);
      _emit(
        AppUpdatePhase.error,
        error: remoteErrorMessage(e, action: 'download the app update'),
      );
      rethrow;
    }
  }

  Future<bool> installUpdate(String path) {
    if (!_isAndroid || externallyManaged || path != downloadedPath) {
      return Future.error(
        StateError('The downloaded app update is unavailable'),
      );
    }
    if (_installation case final pending?) return pending;
    if (_download != null || currentState.phase == AppUpdatePhase.downloading) {
      return Future.error(StateError('An app update operation is in progress'));
    }
    return _installation = _installUpdate(path);
  }

  Future<bool> _installUpdate(String path) async {
    _operationRevision++;
    _resumedDuringInstallation = false;
    _emit(AppUpdatePhase.installing);
    var cacheValidated = false;
    try {
      cacheValidated = await _isUsableApk(path);
      if (!cacheValidated) {
        throw StateError('The downloaded app update is unavailable');
      }
      final started = await _updater.installUpdate(path);
      _installationStarted = started;
      if (!started) {
        _installation = null;
        _emit(
          AppUpdatePhase.error,
          error: 'Installation permission required. Grant it and retry.',
        );
      } else {
        _emit(AppUpdatePhase.installing);
        if (_resumedDuringInstallation) onAppResumed();
      }
      return started;
    } catch (e, st) {
      if (!cacheValidated || !await File(path).exists()) {
        _downloadedPath = null;
        _downloadedRelease = null;
      }
      _installation = null;
      _log.warning('App update installation failed', e, st);
      _emit(
        AppUpdatePhase.error,
        error: remoteErrorMessage(e, action: 'install the app update'),
      );
      rethrow;
    }
  }

  Future<bool> _isUsableApk(String path) async {
    final cached = await File(path).stat();
    return cached.type == FileSystemEntityType.file && cached.size > 0;
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

    if (_isMacOS || externallyManaged) {
      await _updateManagedContent();
    } else {
      final lastCheck = await _settingsService.lastUpdateCheckTime();
      if (lastCheck == null ||
          DateTime.now().difference(lastCheck) > _checkInterval) {
        await checkForUpdate(quiet: true);
        await _updateManagedContent();
      }
    }

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_checkInterval, (_) async {
      if (!_isMacOS) {
        await checkForUpdate(quiet: true);
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

  Future<UpdateInfo?> checkForUpdate({bool quiet = false}) async {
    if (_download != null ||
        _installation != null ||
        currentState.phase == AppUpdatePhase.downloading ||
        currentState.phase == AppUpdatePhase.installing) {
      return availableUpdate;
    }
    if (externallyManaged) {
      _availableUpdate = null;
      _emit(AppUpdatePhase.idle);
      return null;
    }
    if (_isMacOS) {
      _log.info('macOS app updates are owned by Sparkle; skipping APK check');
      return null;
    }
    final revision = _operationRevision;
    try {
      _emit(AppUpdatePhase.checking);
      _log.info('Checking for updates (current: ${BuildInfo.version})');

      final channel = await _settingsService.updateChannel();
      if (revision != _operationRevision) return availableUpdate;
      final updateInfo = await _updater.checkForUpdate(
        BuildInfo.version,
        channel: channel,
      );
      if (revision != _operationRevision) return availableUpdate;

      await _settingsService.setLastUpdateCheckTime(DateTime.now());
      if (revision != _operationRevision) return availableUpdate;
      final skipped = updateInfo == null
          ? null
          : await _settingsService.skippedVersion();
      if (revision != _operationRevision) return availableUpdate;
      _hasCompletedCheck = true;

      if (updateInfo != null) {
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
      if (revision != _operationRevision) return availableUpdate;
      _log.warning('Error checking for updates', e, stackTrace);
      if (quiet) {
        _emit(
          _availableUpdate != null
              ? AppUpdatePhase.available
              : AppUpdatePhase.idle,
        );
        return null;
      }
      _emit(
        AppUpdatePhase.error,
        error: remoteErrorMessage(e, action: 'check for app updates'),
      );
      rethrow;
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
    _hasCompletedCheck = true;
    _emit(AppUpdatePhase.idle);
  }

  void debugForceUpdate({String version = '99.0.0', String? downloadUrl}) {
    if (externallyManaged) {
      _availableUpdate = null;
      _emit(AppUpdatePhase.idle);
      return;
    }
    _log.info('DEBUG: forcing fake update notification ($version)');
    _hasCompletedCheck = true;
    _availableUpdate = UpdateInfo(
      version: version,
      downloadUrl: downloadUrl ?? 'https://github.com/decentespresso/decaid/releases/download/v0.7.7/decent-android-0.7.7.apk',
      releaseNotes: 'Forced update for testing the update API.',
      isPrerelease: false,
      tagName: 'v$version',
    );
    _emit(AppUpdatePhase.available);
  }

  Future<void> skipCurrentUpdate() async {
    final version = _availableUpdate?.version;
    if (version != null) {
      await skipVersion(version);
    } else {
      _emit(AppUpdatePhase.idle);
    }
  }

  Future<void> skipVersion(String version) async {
    _log.info('User skipped update: $version');
    await _settingsService.setSkippedVersion(version);
    if (_availableUpdate?.version == version) {
      _availableUpdate = null;
      _hasCompletedCheck = true;
      _emit(AppUpdatePhase.idle);
    }
  }

  void dispose() {
    _periodicTimer?.cancel();
    _updater.dispose();
    _state.close();
  }
}
