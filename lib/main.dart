import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:collection/collection.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:reaprime/build_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reaprime/src/account/account_consent_prompter.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/controllers/bengle_probe_bridge.dart';
import 'package:reaprime/src/controllers/bengle_saw_bridge.dart';
import 'package:reaprime/src/controllers/bengle_steam_stop_bridge.dart';
import 'package:reaprime/src/controllers/hot_water_sequencer.dart';
import 'package:reaprime/src/controllers/steam_sequencer.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/remembered_device_sources.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/controllers/workflow_device_sync.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:reaprime/src/services/database/database.dart' hide Workflow;
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:reaprime/src/services/database/mappers/steam_mapper.dart';
import 'package:reaprime/src/services/database/mappers/bean_mapper.dart';
import 'package:reaprime/src/services/database/mappers/grinder_mapper.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:reaprime/src/services/storage/drift_grinder_storage.dart';
import 'package:reaprime/src/services/storage/drift_profile_storage.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/account/account_consent_gate.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/account/proxy_token_store.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/services/account/credential_store_factory.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:reaprime/src/services/simulated_device_service.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/services/macos_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/cli/cli_args.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'package:reaprime/src/controllers/scan_state_guardian.dart';

import 'src/app.dart';
import 'src/launcher/launcher_view.dart';
import 'src/services/foreground_service.dart';
import 'src/services/network/multicast_lock_service.dart';
import 'src/settings/settings_controller.dart';
import 'src/settings/settings_service.dart';
import 'src/settings/update_dialog.dart';
import 'src/services/serial/serial_service.dart';

import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';

import 'package:reaprime/src/services/telemetry/telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';
import 'package:reaprime/src/services/telemetry/anonymization.dart';
import 'package:reaprime/src/services/telemetry/error_report_throttle.dart';
import 'package:reaprime/src/services/telemetry/telemetry_forwarder_filter.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';
import 'package:device_info_plus/device_info_plus.dart';

Future<void> _setSystemInfoKeys(TelemetryService telemetryService) async {
  try {
    final deviceInfoPlugin = DeviceInfoPlugin();
    final deviceInfo = await deviceInfoPlugin.deviceInfo;
    final deviceData = deviceInfo.data;

    await telemetryService.setCustomKey('os_name', Platform.operatingSystem);
    await telemetryService.setCustomKey(
      'os_version',
      Platform.operatingSystemVersion,
    );
    await telemetryService.setCustomKey('app_version', BuildInfo.commitShort);

    final deviceModel =
        deviceData['model'] ?? deviceData['computerName'] ?? 'unknown';
    await telemetryService.setCustomKey('device_model', deviceModel);

    final deviceBrand =
        deviceData['brand'] ?? deviceData['hostName'] ?? 'unknown';
    await telemetryService.setCustomKey('device_brand', deviceBrand);
  } catch (e, st) {
    final log = Logger('Main');
    log.warning('Failed to set system info custom keys', e, st);
  }
}

const _defaultSimulatedDevices = <SimulatedDevicesTypes>{
  SimulatedDevicesTypes.machine,
  SimulatedDevicesTypes.scale,
  SimulatedDevicesTypes.sensor,
  SimulatedDevicesTypes.bengle,
};

Set<SimulatedDevicesTypes> _parseSimulateFlag(String value) {
  if (value == '1') {
    return {..._defaultSimulatedDevices};
  }
  return value
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .map((e) => SimulatedDevicesTypesFromString.fromString(e))
      .whereType<SimulatedDevicesTypes>()
      .toSet();
}

Future<void> _printStoragePaths() async {
  stdout.writeln('support: ${await AppDirectories.support}');
  stdout.writeln('hive: ${await AppDirectories.hive}');
  stdout.writeln('drift: ${await AppDirectories.driftFile}');
  stdout.writeln('logs: ${await AppDirectories.logs}');
  stdout.writeln('plugins: ${await AppDirectories.plugins}');
  stdout.writeln('webUi: ${await AppDirectories.webUi}');
  stdout.writeln('temp: ${await AppDirectories.temp}');
  await stdout.flush();
  exit(0);
}

ActiveSkinConsent? _activeSkinConsent(String path, WebUIStorage storage) {
  final value = path.trim();
  if (value.isEmpty) return null;
  final normalizedPath = p.normalize(value);
  final skin = storage.installedSkins.firstWhereOrNull(
    (candidate) => p.equals(p.normalize(candidate.path), normalizedPath),
  );
  return ActiveSkinConsent(
    id: skin?.id,
    name: skin?.name ?? 'Custom skin',
    path: value,
  );
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final cliArgs = parseCliArgs(args);
  if (cliArgs.printStoragePaths) {
    await _printStoragePaths();
  }
  SemanticsBinding.instance.ensureSemantics();
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top],
  );
  Logger.root.level = Level.FINE;
  Logger.root.clearListeners();
  PrintAppender(formatter: ColorFormatter()).attachToLogger(Logger.root);

  final log = Logger("Main");

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await WindowManager.instance.ensureInitialized();
    if (!Platform.isLinux) {
      WindowManager.instance.setMinimumSize(defaultDesktopWindowSize);
      await WindowManager.instance.setAspectRatio(defaultDesktopAspectRatio);
      await WindowManager.instance.setSize(defaultDesktopWindowSize);
    }
    final startupSimulatedWebViewDevice =
        await SharedPreferencesSettingsService().enableSimulatedWebViews()
        ? await loadPersistedSimulatedWebViewDevice()
        : null;
    if (startupSimulatedWebViewDevice != null) {
      await setSimulatedWebViewDevice(
        startupSimulatedWebViewDevice,
        persist: false,
      );
    }
  }

  final logDir = await AppDirectories.logs;
  await Directory(logDir).create(recursive: true);

  RotatingFileAppender(
    baseFilePath: '$logDir/log.txt',
  ).attachToLogger(Logger.root);

  final webViewLogService = WebViewLogService(logDirectoryPath: logDir);
  await webViewLogService.initialize();

  Logger.root.info("==== Decent starting ====");
  BootTiming.start();

  unawaited(MulticastLockService().acquire());

  Logger.root.info(
    "build: ${BuildInfo.commitShort}, branch: ${BuildInfo.branch}",
  );
  Logger.root.info(
    "version: ${BuildInfo.version}, platform: ${Platform.operatingSystem}",
  );

  final isDebugOrSimulate =
      kDebugMode || const String.fromEnvironment("simulate").isNotEmpty;
  if (!Platform.isLinux && !Platform.isWindows && !isDebugOrSimulate) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e, st) {
      log.warning('Firebase initialization failed', e, st);
    }
  }
  BootTiming.mark('firebase_done');

  final logBuffer = LogBuffer();
  final errorReportThrottle = ErrorReportThrottle();
  final telemetryService = TelemetryService.create(logBuffer: logBuffer);
  BootTiming.telemetry = telemetryService;

  try {
    await telemetryService.initialize();
  } catch (e, st) {
    log.warning('Telemetry initialization failed', e, st);
  }

  await _setSystemInfoKeys(telemetryService);

  Logger.root.onRecord.listen((record) {
    if (record.level >= Level.WARNING) {
      final scrubbed = Anonymization.scrubString(
        '${record.level.name}: ${record.loggerName}: ${record.message}',
      );
      logBuffer.append(scrubbed);

      if (!shouldForwardToTelemetry(record)) return;

      if (errorReportThrottle.shouldReport(scrubbed)) {
        final error = record.error ?? scrubbed;
        telemetryService.recordError(error, record.stackTrace);
      }
    }
  });

  final List<DeviceDiscoveryService> services = [];

  final bleDiscoveryService = UniversalBleDiscoveryService();
  if (!cliArgs.serial) {
    services.add(bleDiscoveryService);
  } else {
    log.info('--serial: BLE service not added to scan list');
  }

  Hive.init(await AppDirectories.hive);
  ensureFlutterTypeAdaptersRegistered();

  services.add(createSerialService());

  final wifiScaleDiscoveryService = WifiScaleDiscoveryService();
  services.add(wifiScaleDiscoveryService);

  final simulatedDevicesService = SimulatedDeviceService();
  services.add(simulatedDevicesService);
  const simulateEnv = String.fromEnvironment("simulate");
  if (simulateEnv.isNotEmpty) {
    final dartDefineDevices = _parseSimulateFlag(simulateEnv);
    simulatedDevicesService.enabledDevices = dartDefineDevices;
    log.info("enabling simulated devices from dart-define: $dartDefineDevices");
  }
  final appDatabase = AppDatabase.defaults();

  final persistenceController = PersistenceController(
    storageService: DriftStorageService(appDatabase),
  );

  final beanStorage = DriftBeanStorageService(appDatabase);
  final grinderStorage = DriftGrinderStorageService(appDatabase);
  final profileStorage = DriftProfileStorageService(appDatabase);

  final WorkflowController workflowController = WorkflowController();
  try {
    Workflow? workflow = await persistenceController.loadWorkflow();
    if (workflow != null) {
      workflowController.setWorkflow(workflow);
    }
  } catch (e) {
    log.warning("loading default workflow failed", e);
  }

  final settingsController = SettingsController(
    SharedPreferencesSettingsService(),
  );
  settingsController.telemetryService = telemetryService;

  final profileController = ProfileController(storage: profileStorage);
  await profileController.initialize();

  final deviceController = DeviceController(services);
  deviceController.telemetryService = telemetryService;
  final de1Controller = De1Controller(controller: deviceController)
    ..defaultWorkflow = workflowController.currentWorkflow;
  final scaleController = ScaleController();
  final sensorController = SensorController(controller: deviceController);

  final rememberedDevicesController = RememberedDevicesController(
    machineConnections: de1Controller.de1.map(rememberedFromMachine),
    scaleConnections: scaleController.connectionState.map(
      (state) =>
          rememberedFromScaleState(state, scaleController.connectedScale),
    ),
    settings: SharedPreferencesSettingsService(),
  );
  await rememberedDevicesController.initialize();

  final connectionManager = ConnectionManager(
    deviceScanner: deviceController,
    de1Controller: de1Controller,
    scaleController: scaleController,
    settingsController: settingsController,
    rememberedDevices: rememberedDevicesController,
  );

  final scanStateGuardian = ScanStateGuardian(
    bleService: cliArgs.serial ? null : bleDiscoveryService,
  );

  final presenceController = PresenceController(
    de1Controller: de1Controller,
    settingsController: settingsController,
  );
  presenceController.initialize();

  workflowController.addListener(() {
    persistenceController.saveWorkflow(workflowController.currentWorkflow);
    de1Controller.defaultWorkflow = workflowController.currentWorkflow;
  });
  // ignore: unused_local_variable
  final workflowDeviceSync = WorkflowDeviceSync(
    workflowController: workflowController,
    de1Controller: de1Controller,
    onUploadError: connectionManager.reportError,
    onUploadErrorCleared: () => connectionManager.clearErrorOfKind(
      ConnectionErrorKind.profileUploadFailed,
    ),
  );
  // ignore: unused_local_variable
  final bengleSawBridge = BengleSawBridge(
    workflowController: workflowController,
    de1Controller: de1Controller,
  );

  // ignore: unused_local_variable
  final bengleSteamStopBridge = BengleSteamStopBridge(
    workflowController: workflowController,
    de1Controller: de1Controller,
  );

  // ignore: unused_local_variable
  final bengleProbeBridge = BengleProbeBridge(
    de1Controller: de1Controller,
    sensorController: sensorController,
  );

  // ignore: unused_local_variable
  final steamSequencer = SteamSequencer(
    de1Controller: de1Controller,
    sensorController: sensorController,
    workflowController: workflowController,
    persistenceController: persistenceController,
  );

  // ignore: unused_local_variable
  final hotWaterSequencer = HotWaterSequencer(
    de1Controller: de1Controller,
    scaleController: scaleController,
    settingsController: settingsController,
  );
  final WebUIService webUIService = WebUIService();
  final WebUIStorage webUIStorage = WebUIStorage(settingsController);

  DecentAccountService? decentAccountService;
  DecentProxyService? decentProxyService;
  AppLogUploadService? appLogUploadService;
  AccountTokensController? accountTokensController;
  CredentialStore? credentialStore;
  AccountConsentGate? consentGate;
  final proxyTokenService = ProxyTokenService();
  if (cliArgs.noAccount) {
    log.info('--no-account: skipping credential store and account service');
    decentAccountService = null;
    decentProxyService = null;
  } else {
    credentialStore = await createCredentialStore();
    final consentPrompter = AccountConsentPrompter(
      navigatorKey: NavigationService.navigatorKey,
    );
    final consentStore = AccountConsentStore(credentialStore: credentialStore);
    final gate = AccountConsentGate(
      store: consentStore,
      prompt: consentPrompter.prompt,
      trustedConsentKeys: cliArgs.trustedConsentKeys,
      trustAllConsent: cliArgs.trustAllConsent,
    );
    consentGate = gate;
    const decentBaseUrl = String.fromEnvironment(
      'DECENT_BASE_URL',
      defaultValue: 'https://decentespresso.com',
    );
    decentAccountService = DecentAccountService(
      httpClient: IOClient(
        HttpClient()..connectionTimeout = const Duration(seconds: 30),
      ),
      credentialStore: credentialStore,
      baseUrl: decentBaseUrl,
    );
    decentProxyService = DecentProxyService(
      httpClient: http.Client(),
      credentialStore: credentialStore,
      requireConsent: gate.requireConsent,
      baseUrl: decentBaseUrl,
      onAuthFailure: () => decentAccountService!.reportAuthenticationFailure(),
      isAuthKnownInvalid: decentAccountService.isAuthKnownInvalid,
    );
    accountTokensController = AccountTokensController(
      tokenService: proxyTokenService,
      store: ProxyTokenStore(credentialStore: credentialStore),
      callerLabelRegistrar: gate.registerCallerLabel,
    );
    await accountTokensController.initialize();
    await decentAccountService.initialize();

    appLogUploadService = AppLogUploadService(
      accountService: decentAccountService,
      consentStore: consentStore,
      preferences: await SharedPreferences.getInstance(),
      logFilePath: '$logDir/log.txt',
      machineIdentity: () {
        final machine = de1Controller.connectedDe1OrNull;
        if (machine == null || machine is SimulatedDevice) return null;
        try {
          final info = machine.machineInfo;
          return AppLogMachineIdentity(
            serialNumber: info.serialNumber,
            firmwareVersion: info.version,
          );
        } catch (_) {
          return null;
        }
      },
    );
    await appLogUploadService.initialize();
  }
  webUIService.skinProxyTokenProvider = (path) {
    final skin = _activeSkinConsent(path, webUIStorage);
    final gate = consentGate;
    if (skin == null || gate == null) return null;
    gate.registerCallerLabel(skin.key, skin.name);
    return proxyTokenService.rotateSkinToken(
      ProxyCaller(
        id: skin.key,
        scopes: const {ProxyTokenService.scopeAccountProxy},
      ),
    );
  };
  webUIService.skinProxyTokenRevoker = proxyTokenService.revokeSkinToken;

  final PluginLoaderService pluginService = PluginLoaderService(
    kvStore: HiveStoreService(defaultNamespace: "plugins")..initialize(),
    decentProxyService: decentProxyService,
    credentialStore: credentialStore,
  );
  await pluginService.pluginManager.attachDe1Controller(de1Controller);
  persistenceController.onShotStored = (shotId) =>
      pluginService.pluginManager.broadcastEvent('shotStored', {'id': shotId});

  BatteryController? batteryController;
  if (Platform.isAndroid || Platform.isIOS) {
    batteryController = BatteryController(
      de1Controller: de1Controller,
      deviceController: deviceController,
      settingsController: settingsController,
    );
  }

  final displayController = DisplayController(
    de1Controller: de1Controller,
    settingsController: settingsController,
    batteryStateStream: batteryController?.chargingState,
  );
  displayController.initialize();

  final updateCheckService = UpdateCheckService(
    settingsService: SharedPreferencesSettingsService(),
    webUIStorage: webUIStorage,
    pluginSourceService: PluginSourceService(pluginService),
  );

  final macosUpdater = Platform.isMacOS ? MacOSUpdater() : null;

  try {
    await startWebServer(
      deviceController,
      de1Controller,
      scaleController,
      settingsController,
      sensorController,
      workflowController,
      persistenceController,
      pluginService,
      webUIService,
      webUIStorage,
      profileController,
      '$logDir/log.txt',
      webViewLogService,
      batteryController,
      presenceController,
      displayController,
      beanStorage: beanStorage,
      grinderStorage: grinderStorage,
      connectionManager: connectionManager,
      backupSources: BackupDataSources(
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          final rows = await appDatabase.shotDao.getShotsForExport(
            limit: limit,
            cursorTimestamp: afterTimestamp,
            cursorId: afterId,
          );
          return rows.map(ShotMapper.fromRow).toList();
        },
        pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          final rows = await appDatabase.steamDao.getSteamsForExport(
            limit: limit,
            cursorTimestamp: afterTimestamp,
            cursorId: afterId,
          );
          return rows.map(SteamMapper.fromRow).toList();
        },
        pageBeans: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          final rows = await appDatabase.beanDao.getBeansForExport(
            limit: limit,
            cursorCreatedAt: afterCreatedAt,
            cursorId: afterId,
          );
          return rows.map(BeanMapper.fromRow).toList();
        },
        pageGrinders: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          final rows = await appDatabase.grinderDao.getGrindersForExport(
            limit: limit,
            cursorCreatedAt: afterCreatedAt,
            cursorId: afterId,
          );
          return rows.map(GrinderMapper.fromRow).toList();
        },
      ),
      wifiScaleDiscoveryService: wifiScaleDiscoveryService,
      rememberedDevicesController: rememberedDevicesController,
      decentAccountService: decentAccountService,
      decentProxyService: decentProxyService,
      proxyTokenService: proxyTokenService,
      updateCheckService: updateCheckService,
    );
  } catch (e, st) {
    log.severe('failed to start web server', e, st);
  }
  BootTiming.mark('webserver_up');
  settingsController.addListener(() {
    const simEnv = String.fromEnvironment("simulate");
    final dartDefineDevices = simEnv.isNotEmpty
        ? _parseSimulateFlag(simEnv)
        : <SimulatedDevicesTypes>{};
    simulatedDevicesService.enabledDevices = {
      ...dartDefineDevices,
      ...settingsController.simulatedDevices,
    };
  });
  await settingsController.loadSettings();
  if (macosUpdater != null) {
    try {
      await macosUpdater.configure(
        automaticChecks: settingsController.automaticUpdateCheck,
        channel: settingsController.updateChannel,
      );
    } catch (e, st) {
      log.warning(
        'Sparkle configuration failed; continuing without macOS auto-update',
        e,
        st,
      );
    }
  }
  bleDiscoveryService.requestLargeMtuNonAndroid = () =>
      settingsController.isFeatureFlagEnabled(.largeBleMtuNonAndroid);

  if (cliArgs.bypassOnboarding) {
    log.info('--bypass-onboarding: skipping onboarding screens');
    await settingsController.setOnboardingCompleted(true);
    await settingsController.setAccountStepSeen(true);
    await settingsController.setAndroidWarningDismissed(true);
  }
  if (cliArgs.skinId != null) {
    log.info('--skin: setting default skin to ${cliArgs.skinId}');
    await settingsController.setDefaultSkinId(cliArgs.skinId!);
  }
  if (cliArgs.skinPath != null) {
    log.info('--skin-path: overriding skin source to ${cliArgs.skinPath}');
    webUIService.skinOverride = SkinOverride.path(cliArgs.skinPath!);
  }

  const envMachineId = String.fromEnvironment("preferredMachineId");
  const envScaleId = String.fromEnvironment("preferredScaleId");
  if (envMachineId.isNotEmpty) {
    await settingsController.setPreferredMachineId(envMachineId);
    log.info("preferredMachineId overridden from dart-define: $envMachineId");
  }
  if (envScaleId.isNotEmpty) {
    await settingsController.setPreferredScaleId(envScaleId);
    log.info("preferredScaleId overridden from dart-define: $envScaleId");
  }

  Logger.root.level =
      Level.LEVELS.firstWhereOrNull(
        (e) => e.name == settingsController.logLevel,
      ) ??
      Level.FINE;

  Future.delayed(Duration(minutes: 10), () async {
    await updateCheckService.initialize();
  });

  WidgetsBinding.instance.addObserver(
    AppLifecycleObserver(
      updateCheckService: updateCheckService,
      de1Controller: de1Controller,
      displayController: displayController,
      pluginLoaderService: pluginService,
      connectionManager: connectionManager,
      appLogUploadService: appLogUploadService,
    ),
  );

  if (Platform.isAndroid) {
    ForegroundTaskService.init();
  }

  BootTiming.mark('runapp');
  runApp(
    WithForegroundTask(
      child: AppRoot(
        directConnect: cliArgs.direct,
        settingsController: settingsController,
        deviceController: deviceController,
        de1Controller: de1Controller,
        scaleController: scaleController,
        workflowController: workflowController,
        persistenceController: persistenceController,
        pluginLoaderService: pluginService,
        webUIService: webUIService,
        webUIStorage: webUIStorage,
        updateCheckService: updateCheckService,
        macosUpdater: macosUpdater,
        webViewLogService: webViewLogService,
        presenceController: presenceController,
        beanStorage: beanStorage,
        grinderStorage: grinderStorage,
        profileStorageService: profileStorage,
        connectionManager: connectionManager,
        scanStateGuardian: scanStateGuardian,
        decentAccountService: decentAccountService,
        accountTokensController: accountTokensController,
        appLogUploadService: appLogUploadService,
        batteryController: batteryController,
        displayController: displayController,
      ),
    ),
  );
}

class AppLifecycleObserver with WidgetsBindingObserver {
  final _log = Logger("App Lifecycle");
  final UpdateCheckService? updateCheckService;
  final De1Controller? de1Controller;
  final DisplayController? displayController;
  final PluginLoaderService? pluginLoaderService;
  final ConnectionManager? connectionManager;
  final AppLogUploadService? appLogUploadService;

  late Timer _memTimer;
  bool _wasBackgrounded = false;
  StreamSubscription? _machineStateSubscription;
  StreamSubscription? _stateStreamSubscription;
  int? _lastMachineState;
  Future<void>? _detachFuture;

  AppLifecycleObserver({
    this.updateCheckService,
    this.de1Controller,
    this.displayController,
    this.pluginLoaderService,
    this.connectionManager,
    this.appLogUploadService,
  }) {
    _memTimer = Timer.periodic(Duration(minutes: 5), (t) {
      final rss = ProcessInfo.currentRss / (1024 * 1024);
      _log.info("[MEM] RSS=${rss.toStringAsFixed(1)}MB");
    });

    if (updateCheckService?.hasAvailableUpdate == true) {
      Future.delayed(const Duration(seconds: 3), () {
        _showUpdateNotification();
      });
    }

    _machineStateSubscription = de1Controller?.de1.listen((machine) {
      if (_detachFuture != null) return;
      _stateStreamSubscription?.cancel();

      if (machine == null) return;

      _stateStreamSubscription = machine.currentSnapshot.listen((snapshot) {
        if (_detachFuture != null) return;
        final currentState = snapshot.state.state.index;

        if (_lastMachineState == 0 &&
            currentState == 2 &&
            updateCheckService?.hasAvailableUpdate == true) {
          _log.info(
            'Machine transitioned from sleep to idle, showing update notification',
          );
          _showUpdateNotification();
        }

        _lastMachineState = currentState;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_detach());
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _log.info("state: $state");
      _wasBackgrounded = true;
    }
    if (state == AppLifecycleState.resumed) {
      _log.info("state: resumed");

      unawaited(displayController?.onAppResumed() ?? Future<void>.value());

      if (_wasBackgrounded && updateCheckService?.hasAvailableUpdate == true) {
        _showUpdateNotification();
      }
      _wasBackgrounded = false;
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _detach();
    return AppExitResponse.exit;
  }

  Future<void> _detach() {
    final existing = _detachFuture;
    if (existing != null) return existing;

    _memTimer.cancel();
    final detaching = _handleDetached();
    _detachFuture = detaching;
    return detaching;
  }

  Future<void> _handleDetached() async {
    final machineSubscription = _machineStateSubscription;
    _machineStateSubscription = null;
    try {
      await machineSubscription?.cancel();
    } catch (error, stackTrace) {
      _log.warning('Machine subscription detach failed', error, stackTrace);
    }
    final stateSubscription = _stateStreamSubscription;
    _stateStreamSubscription = null;
    try {
      await stateSubscription?.cancel();
    } catch (error, stackTrace) {
      _log.warning('State subscription detach failed', error, stackTrace);
    }
    try {
      await connectionManager?.shutdown();
    } catch (error, stackTrace) {
      _log.warning('Connection shutdown failed', error, stackTrace);
    }
    try {
      await pluginLoaderService?.dispose();
    } catch (error, stackTrace) {
      _log.severe('Plugin loader disposal failed', error, stackTrace);
    }
    appLogUploadService?.dispose();
  }

  void _showUpdateNotification() {
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;

    final updateInfo = updateCheckService?.availableUpdate;
    if (updateInfo == null) return;

    final messenger = ScaffoldMessenger.of(context);

    messenger.clearSnackBars();

    final controller = messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(child: Text('Update: ${updateInfo.version}')),
            SnackBarAction(
              label: 'View',
              onPressed: () {
                final releaseUrl = updateCheckService?.getReleaseUrl();
                if (releaseUrl != null) launchUrl(Uri.parse(releaseUrl));
              },
            ),
            SnackBarAction(
              label: 'Download',
              onPressed: () {
                if (Platform.isAndroid) {
                  _showAndroidDownloadDialog(context, updateInfo);
                } else {
                  final releaseUrl = updateCheckService?.getReleaseUrl();
                  if (releaseUrl != null) {
                    launchUrl(Uri.parse(releaseUrl));
                  }
                }
              },
            ),
          ],
        ),
        showCloseIcon: true,
        duration: const Duration(days: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );

    controller.closed.then((reason) {
      if (reason == SnackBarClosedReason.dismiss) {
        updateCheckService?.skipCurrentUpdate();
      }
    });
  }

  void _showAndroidDownloadDialog(BuildContext context, UpdateInfo updateInfo) {
    final updater = AndroidUpdater(owner: 'tadelv', repo: 'reaprime');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AndroidQuickUpdateDialog(
        updateInfo: updateInfo,
        onDownload: (info, onProgress) =>
            updater.downloadUpdate(info, onProgress: onProgress),
        onInstall: updater.installUpdate,
      ),
    );
  }

  void dispose() {
    _memTimer.cancel();
    _machineStateSubscription?.cancel();
    _stateStreamSubscription?.cancel();
  }
}

class AppRoot extends StatefulWidget {
  final bool directConnect;
  final SettingsController settingsController;
  final DeviceController deviceController;
  final De1Controller de1Controller;
  final ScaleController scaleController;
  final WorkflowController workflowController;
  final PersistenceController persistenceController;
  final PluginLoaderService pluginLoaderService;
  final WebUIService webUIService;
  final WebUIStorage webUIStorage;
  final UpdateCheckService? updateCheckService;
  final MacOSUpdater? macosUpdater;
  final WebViewLogService webViewLogService;
  final PresenceController presenceController;
  final BeanStorageService? beanStorage;
  final GrinderStorageService? grinderStorage;
  final ProfileStorageService? profileStorageService;
  final ConnectionManager connectionManager;
  final ScanStateGuardian scanStateGuardian;
  final DecentAccountService? decentAccountService;
  final AccountTokensController? accountTokensController;
  final AppLogUploadService? appLogUploadService;
  final BatteryController? batteryController;
  final DisplayController displayController;

  const AppRoot({
    super.key,
    this.directConnect = false,
    required this.settingsController,
    required this.deviceController,
    required this.de1Controller,
    required this.scaleController,
    required this.workflowController,
    required this.persistenceController,
    required this.pluginLoaderService,
    required this.webUIService,
    required this.webUIStorage,
    required this.webViewLogService,
    required this.presenceController,
    required this.connectionManager,
    required this.scanStateGuardian,
    this.updateCheckService,
    this.macosUpdater,
    this.beanStorage,
    this.grinderStorage,
    this.profileStorageService,
    this.decentAccountService,
    this.accountTokensController,
    this.appLogUploadService,
    this.batteryController,
    required this.displayController,
  });

  static void restart(BuildContext context) {
    context.findAncestorStateOfType<_AppRootState>()?.restart();
  }

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final Logger _log = Logger("AppRoot");
  Key _key = UniqueKey();

  static const _windowChannel = MethodChannel('net.tadel.reaprime/window');

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _windowChannel.setMethodCallHandler(_handleWindowMethod);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      _windowChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _handleWindowMethod(MethodCall call) async {
    if (call.method == 'backToDashboard') {
      _backToDashboard();
    }
  }

  void _backToDashboard() {
    NavigationService.navigatorKey.currentState?.pushNamedAndRemoveUntil(
      LauncherView.routeName,
      (_) => false,
    );
  }

  Future<void> restart() async {
    _log.info("recreating App Root");
    setState(() {
      _key = UniqueKey();
    });
  }

  static const _channel = MethodChannel('app/lifecycle');

  Future<void> recreateActivity() async {
    try {
      await _channel.invokeMethod('recreateActivity');
    } catch (e) {
      _log.severe('[ActivityControl] recreate failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(
      key: _key,
      child: MyApp(
        directConnect: widget.directConnect,
        settingsController: widget.settingsController,
        deviceController: widget.deviceController,
        de1Controller: widget.de1Controller,
        scaleController: widget.scaleController,
        workflowController: widget.workflowController,
        persistenceController: widget.persistenceController,
        pluginLoaderService: widget.pluginLoaderService,
        webUIService: widget.webUIService,
        webUIStorage: widget.webUIStorage,
        updateCheckService: widget.updateCheckService,
        macosUpdater: widget.macosUpdater,
        webViewLogService: widget.webViewLogService,
        presenceController: widget.presenceController,
        beanStorage: widget.beanStorage,
        grinderStorage: widget.grinderStorage,
        profileStorageService: widget.profileStorageService,
        connectionManager: widget.connectionManager,
        scanStateGuardian: widget.scanStateGuardian,
        decentAccountService: widget.decentAccountService,
        accountTokensController: widget.accountTokensController,
        appLogUploadService: widget.appLogUploadService,
        batteryController: widget.batteryController,
        displayController: widget.displayController,
      ),
    );

    if (Platform.isMacOS) {
      return PlatformMenuBar(menus: _buildPlatformMenus(), child: child);
    }
    if ((Platform.isWindows || Platform.isLinux) &&
        widget.settingsController.enableSimulatedWebViews) {
      return CallbackShortcuts(
        bindings: _simulatedWebViewShortcuts(),
        child: child,
      );
    }
    return child;
  }

  Map<ShortcutActivator, VoidCallback> _simulatedWebViewShortcuts() {
    return {
      const SingleActivator(
        LogicalKeyboardKey.digit0,
        control: true,
        alt: true,
      ): () =>
          unawaited(setSimulatedWebViewDevice(null)),
      const SingleActivator(
        LogicalKeyboardKey.digit8,
        control: true,
        alt: true,
      ): () => unawaited(
        setSimulatedWebViewDevice(SimulatedWebViewDevice.teclastT50Mini),
      ),
      const SingleActivator(
        LogicalKeyboardKey.digit7,
        control: true,
        alt: true,
      ): () => unawaited(
        setSimulatedWebViewDevice(SimulatedWebViewDevice.teclastP80X),
      ),
      const SingleActivator(
        LogicalKeyboardKey.digit6,
        control: true,
        alt: true,
      ): () => unawaited(
        setSimulatedWebViewDevice(SimulatedWebViewDevice.teclastP85Pro),
      ),
    };
  }

  List<PlatformMenuItem> _buildPlatformMenus() {
    return [
      PlatformMenu(
        label: 'Decaid',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(label: 'About Decaid', onSelected: null),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Quit Decaid',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyQ,
                  meta: true,
                ),
                onSelected: () => unawaited(
                  ServicesBinding.instance.exitApplication(
                    AppExitType.cancelable,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: 'View',
        menus: [
          PlatformMenuItem(
            label: 'Back to Dashboard',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyD,
              meta: true,
            ),
            onSelected: _backToDashboard,
          ),
          if (widget.settingsController.enableSimulatedWebViews) ...[
            PlatformMenuItem(
              label: 'Use Native macOS WebView',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit0,
                alt: true,
                meta: true,
              ),
              onSelected: () async {
                await setSimulatedWebViewDevice(null);
              },
            ),
            PlatformMenuItem(
              label: 'Simulate Teclast M50/T50 Mini WebView',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit8,
                alt: true,
                meta: true,
              ),
              onSelected: () async {
                await setSimulatedWebViewDevice(
                  SimulatedWebViewDevice.teclastT50Mini,
                );
              },
            ),
            PlatformMenuItem(
              label: 'Simulate Teclast P80X WebView',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit7,
                alt: true,
                meta: true,
              ),
              onSelected: () async {
                await setSimulatedWebViewDevice(
                  SimulatedWebViewDevice.teclastP80X,
                );
              },
            ),
            PlatformMenuItem(
              label: 'Simulate Teclast P85 Pro WebView',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit6,
                alt: true,
                meta: true,
              ),
              onSelected: () async {
                await setSimulatedWebViewDevice(
                  SimulatedWebViewDevice.teclastP85Pro,
                );
              },
            ),
          ],
        ],
      ),
    ];
  }
}
