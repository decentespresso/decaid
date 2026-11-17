import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/foreground_service.dart';
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:rxdart/rxdart.dart';

enum AppStartupStatus { idle, initializing, ready, degraded, failed }

enum AppStartupTaskStatus { idle, pending, completed, failed }

@immutable
class AppStartupState {
  final AppStartupStatus status;
  final List<String> reasons;
  final Map<String, AppStartupTaskStatus> optionalTasks;
  final String? discoveryRecovery;

  AppStartupState({
    required this.status,
    List<String> reasons = const [],
    Map<String, AppStartupTaskStatus> optionalTasks = const {},
    this.discoveryRecovery,
  }) : reasons = List.unmodifiable(reasons),
       optionalTasks = Map.unmodifiable(optionalTasks);

  bool get discoveryRecoveryRequired => discoveryRecovery != null;
}

class AppStartupCoordinator {
  static final _log = Logger('AppStartupCoordinator');

  final Future<void> Function() _initializeDevices;
  late final Future<void> Function() _initializeWebUI;
  final DeviceStartupOutcome Function() _deviceStartupOutcome;
  final Future<bool> Function()? _startForeground;
  final FutureOr<Object?> Function()? _watchForeground;
  final FutureOr<void> Function(Object token)? _unwatchForeground;
  final Future<void> Function()? _initializePlugins;
  final Future<void> Function()? _refreshRemoteSkins;
  final bool _isAndroid;

  final _stateController = BehaviorSubject<AppStartupState>.seeded(
    AppStartupState(status: AppStartupStatus.idle),
  );
  Future<void>? _initializationFuture;
  AppStartupState _state = AppStartupState(status: AppStartupStatus.idle);
  bool _disposed = false;
  bool _devicesReady = false;
  bool _webUIReady = false;
  bool _foregroundReady = false;
  bool _foregroundWatched = false;
  final Map<String, String> _coreReasons = {};
  final List<String> _webUIWarnings = [];
  bool _storageInitialized = false;
  bool _skinServed = false;
  bool _optionalWorkStarted = false;
  bool _coreRetryNeeded = false;
  String? _discoveryRecovery;
  Object? _foregroundWatchToken;

  AppStartupCoordinator({
    DeviceController? deviceController,
    De1Controller? de1Controller,
    WebUIStorage? webUIStorage,
    WebUIService? webUIService,
    PluginLoaderService? pluginLoaderService,
    Future<void> Function()? initializeDevices,
    Future<void> Function()? initializeWebUI,
    DeviceStartupOutcome Function()? deviceStartupOutcome,
    Future<bool> Function()? startForeground,
    FutureOr<Object?> Function()? watchForeground,
    FutureOr<void> Function(Object token)? unwatchForeground,
    Future<void> Function()? initializePlugins,
    Future<void> Function()? refreshRemoteSkins,
    bool? isAndroid,
  }) : assert(
         initializeDevices != null || deviceController != null,
         'Provide deviceController or initializeDevices',
       ),
       assert(
         initializeWebUI != null ||
             (webUIStorage != null && webUIService != null),
         'Provide WebUI services or initializeWebUI',
       ),
       _initializeDevices = initializeDevices ?? deviceController!.initialize,
       _deviceStartupOutcome =
           deviceStartupOutcome ??
           (() =>
               deviceController?.startupOutcome ??
               const DeviceStartupOutcome()),
       _startForeground =
           startForeground ??
           (isAndroid == false ? null : ForegroundTaskService.start),
       _watchForeground =
           watchForeground ??
           (de1Controller == null
               ? null
               : () => ForegroundTaskService.watchMachineConnection(
                   de1Controller.de1,
                 )),
       _unwatchForeground =
           unwatchForeground ?? ForegroundTaskService.unwatchMachineConnection,
       _initializePlugins =
           initializePlugins ?? pluginLoaderService?.initialize,
       _refreshRemoteSkins =
           refreshRemoteSkins ?? webUIStorage?.downloadRemoteSkinsAndRescan,
       _isAndroid = isAndroid ?? Platform.isAndroid {
    _initializeWebUI =
        initializeWebUI ??
        (() => _initializeWebUIServices(webUIStorage!, webUIService!));
  }

  AppStartupState get state => _state;
  AppStartupStatus get status => _state.status;
  List<String> get reasons => _state.reasons;
  Stream<AppStartupState> get stateStream => _stateController.stream;
  Future<void>? get initializationFuture => _initializationFuture;

  Future<void> ensureInitialized() {
    if (_disposed) return Future<void>.value();
    return _initializationFuture ??= _runInitialization();
  }

  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    if (_state.status == AppStartupStatus.failed || _coreRetryNeeded) {
      _initializationFuture = null;
      return ensureInitialized();
    }
    return ensureInitialized();
  }

  Future<void> _runInitialization() async {
    _setState(
      AppStartupState(
        status: AppStartupStatus.initializing,
        reasons: _state.reasons,
        optionalTasks: _state.optionalTasks.isEmpty
            ? _optionalTaskStates(AppStartupTaskStatus.idle)
            : _state.optionalTasks,
        discoveryRecovery: _discoveryRecovery,
      ),
    );
    BootTiming.mark('init_start');
    _coreRetryNeeded = false;
    Object? deviceError;
    StackTrace? deviceStack;
    var discoveryBlocked = false;
    final devices = () async {
      if (_devicesReady) return;
      try {
        await _initializeDevices();
        if (_disposed) return;
        final outcome = _deviceStartupOutcome();
        _devicesReady = outcome.failures.isEmpty;
        if (outcome.failures.isEmpty) {
          _coreReasons.remove('devices');
          _discoveryRecovery = null;
        } else {
          _discoveryRecovery =
              'Device service initialization failed: ${outcome.failures.join('; ')}';
          _coreReasons['devices'] = _discoveryRecovery!;
          discoveryBlocked = outcome.blocking;
        }
      } catch (error, st) {
        deviceError = error;
        deviceStack = st;
        _discoveryRecovery = 'Device initialization failed: $error';
        _coreReasons['devices'] = _discoveryRecovery!;
        _log.severe('Device initialization failed', error, st);
      }
    }();
    final webUI = () async {
      if (_webUIReady) return;
      try {
        await _initializeWebUI();
        if (_disposed) return;
        _webUIReady = true;
        _coreReasons.remove('webUI');
        _log.info('WebUI startup completed');
      } catch (error, st) {
        _log.warning('WebUI startup degraded: $error', error, st);
        _coreReasons['webUI'] = 'WebUI startup failed: $error';
      }
    }();
    await Future.wait([devices, webUI]);
    if (_disposed) return;
    if (deviceError != null) {
      _publishCoreResult(AppStartupStatus.failed);
      Error.throwWithStackTrace(deviceError!, deviceStack!);
    }
    if (discoveryBlocked) {
      _publishCoreResult(AppStartupStatus.failed);
      throw DeviceDiscoveryStartupFailed(_discoveryRecovery!);
    }

    if (_isAndroid && _startForeground != null) {
      try {
        if (!_foregroundReady) _foregroundReady = await _startForeground();
        if (_disposed) return;
        if (!_foregroundReady) {
          _coreReasons['foreground'] = 'Foreground service failed to start';
        } else {
          if (!_foregroundWatched && _watchForeground != null) {
            final token = await _watchForeground();
            if (_disposed) {
              if (token != null) await _unwatchForeground?.call(token);
              return;
            }
            _foregroundWatchToken = token;
            _foregroundWatched = true;
          }
          _coreReasons.remove('foreground');
        }
      } catch (error, st) {
        _log.warning('Foreground service startup degraded: $error', error, st);
        _coreReasons['foreground'] =
            'Foreground service startup failed: $error';
      }
    }
    if (_disposed) return;
    _coreRetryNeeded = _coreReasons.isNotEmpty;
    BootTiming.mark('init_ready');
    BootTiming.mark('scan_start');
    _publishCoreResult(
      _coreReasons.isEmpty &&
              _webUIWarnings.isEmpty &&
              !_state.optionalTasks.values.contains(AppStartupTaskStatus.failed)
          ? AppStartupStatus.ready
          : AppStartupStatus.degraded,
    );
    if (!_optionalWorkStarted) {
      _optionalWorkStarted = true;
      _startOptionalWork();
    }
  }

  void _publishCoreResult(AppStartupStatus status) {
    final optionalReasons = _state.reasons.where(
      (reason) =>
          reason.startsWith('plugins startup failed:') ||
          reason.startsWith('remote skins startup failed:'),
    );
    _setState(
      AppStartupState(
        status: status,
        reasons: List.unmodifiable([
          ..._coreReasons.values,
          ..._webUIWarnings,
          ...optionalReasons,
        ]),
        optionalTasks: _state.optionalTasks,
        discoveryRecovery: _discoveryRecovery,
      ),
    );
  }

  void _startOptionalWork() {
    final initializePlugins = _initializePlugins;
    if (initializePlugins != null) {
      _setOptionalStatus('plugins', AppStartupTaskStatus.pending);
      unawaited(_runOptional('plugins', initializePlugins));
    }
    final refreshRemoteSkins = _refreshRemoteSkins;
    if (refreshRemoteSkins != null) {
      _setOptionalStatus('remote skins', AppStartupTaskStatus.pending);
      unawaited(_runOptional('remote skins', refreshRemoteSkins));
    }
  }

  Future<void> _runOptional(String name, Future<void> Function() work) async {
    try {
      await work();
      if (!_disposed) _setOptionalStatus(name, AppStartupTaskStatus.completed);
    } catch (error, st) {
      _log.warning('$name startup failed: $error', error, st);
      if (_disposed) return;
      _setOptionalStatus(name, AppStartupTaskStatus.failed);
      _setState(
        AppStartupState(
          status:
              _state.status == AppStartupStatus.failed ||
                  _state.status == AppStartupStatus.initializing
              ? _state.status
              : AppStartupStatus.degraded,
          reasons: [..._state.reasons, '$name startup failed: $error'],
          optionalTasks: _state.optionalTasks,
          discoveryRecovery: _discoveryRecovery,
        ),
      );
    }
  }

  void _setOptionalStatus(String name, AppStartupTaskStatus status) {
    if (_disposed) return;
    final tasks = Map<String, AppStartupTaskStatus>.from(_state.optionalTasks);
    tasks[name] = status;
    _setState(
      AppStartupState(
        status: _state.status,
        reasons: _state.reasons,
        optionalTasks: tasks,
        discoveryRecovery: _discoveryRecovery,
      ),
    );
  }

  Map<String, AppStartupTaskStatus> _optionalTaskStates(
    AppStartupTaskStatus status,
  ) {
    return {
      if (_initializePlugins != null) 'plugins': status,
      if (_refreshRemoteSkins != null) 'remote skins': status,
    };
  }

  void _setState(AppStartupState state) {
    if (_disposed) return;
    _state = state;
    _stateController.add(state);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final token = _foregroundWatchToken;
    _foregroundWatchToken = null;
    if (token != null) {
      final unwatch = _unwatchForeground;
      if (unwatch != null) {
        unawaited(Future<void>.sync(() => unwatch(token)));
      }
    }
    _stateController.close();
  }

  Future<void> _initializeWebUIServices(
    WebUIStorage storage,
    WebUIService service,
  ) async {
    final failures = <String>[];
    if (!_storageInitialized) {
      _log.info('Initializing WebUI storage...');
      try {
        await storage.initialize(downloadRemote: false);
        _storageInitialized = true;
        _log.info('WebUI storage initialized without remote skin download');
      } catch (error, st) {
        _log.warning('Failed to initialize WebUI storage', error, st);
        failures.add('WebUI storage initialization failed: $error');
      }
    }
    if (_disposed) return;
    if (!_skinServed) {
      _webUIWarnings.clear();
      final override = service.skinOverride;
      if (override.source == SkinSource.path) {
        final path = override.value!;
        final readable = await _isReadableDirectory(path);
        if (_disposed) return;
        if (readable) {
          _log.info('Starting WebUI service from --skin-path: $path');
          try {
            await service.serveFolderAtPath(path);
            _skinServed = true;
            _log.info('WebUI serving configured skin path: $path');
          } catch (error, st) {
            _log.warning('Configured skin path failed: $error', error, st);
            _webUIWarnings.add('Configured skin path failed: $error');
          }
        } else {
          _log.warning('Configured skin path is not readable: $path');
          _webUIWarnings.add('Configured skin path is not readable: $path');
        }
      }
      if (_disposed) return;
      if (!_skinServed) {
        if (override.source == SkinSource.path) {
          _log.info('Falling back to registry default skin');
        }
        final defaultSkin = storage.defaultSkin;
        if (defaultSkin != null) {
          _log.info('Starting WebUI service with skin: ${defaultSkin.name}');
          try {
            await service.serveFolderAtPath(defaultSkin.path);
            _skinServed = true;
            _log.info('WebUI serving default skin: ${defaultSkin.path}');
          } catch (error, st) {
            _log.warning('Default skin failed: $error', error, st);
            failures.add('Default skin failed: $error');
          }
        } else {
          _log.warning('No default skin available');
          failures.add('No default skin available');
        }
      }
    }
    if (failures.isNotEmpty) throw _WebUIStartupDegraded(failures.join('; '));
  }

  static Future<bool> _isReadableDirectory(String path) async {
    try {
      return await Directory(path).exists();
    } catch (_) {
      return false;
    }
  }
}

class _WebUIStartupDegraded implements Exception {
  final String message;

  const _WebUIStartupDegraded(this.message);

  @override
  String toString() => message;
}

class DeviceDiscoveryStartupFailed implements Exception {
  final String message;

  const DeviceDiscoveryStartupFailed(this.message);

  @override
  String toString() => message;
}
