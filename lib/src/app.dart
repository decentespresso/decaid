import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/main.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/controllers/presence_navigator_observer.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/history_feature/history_feature.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_view.dart';
import 'package:reaprime/src/onboarding_feature/steps/android_warning_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/import_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/initialization_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/permissions_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/scan_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/welcome_step.dart';
import 'package:reaprime/src/onboarding_feature/steps/login_step.dart';
import 'package:reaprime/src/realtime_shot_feature/realtime_shot_feature.dart';
import 'package:reaprime/src/realtime_steam_feature/realtime_steam_feature.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/theme/theme.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide Scale;
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/launcher/launcher_scan_page.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/debug_feature/scale_debug_view.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/macos_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/settings/data_management_page.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/plugins_settings_view.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'debug_feature/debug_item_details_view.dart';

import 'debug_feature/debug_item_list_view.dart';
import 'settings/feature_flags.dart';
import 'settings/gateway_mode.dart';
import 'settings/settings_controller.dart';
import 'settings/settings_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';

class NavigationService {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static BuildContext? get context => navigatorKey.currentContext;
  static String? get currentRoute => ModalRoute.of(context!)?.settings.name;
}

class MyApp extends StatefulWidget {
  const MyApp({
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
    required this.displayController,
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
  });

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
  final WebViewLogService webViewLogService;
  final PresenceController presenceController;
  final DisplayController displayController;
  final ConnectionManager connectionManager;
  final ScanStateGuardian scanStateGuardian;
  final UpdateCheckService? updateCheckService;
  final MacOSUpdater? macosUpdater;
  final BeanStorageService? beanStorage;
  final GrinderStorageService? grinderStorage;
  final ProfileStorageService? profileStorageService;
  final DecentAccountService? decentAccountService;
  final AccountTokensController? accountTokensController;
  final AppLogUploadService? appLogUploadService;
  final BatteryController? batteryController;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static final Logger _log = Logger('MyApp');
  De1StateManager? _de1StateManager;
  Timer? _restartTimer;
  late final OnboardingController _onboardingController;

  bool _degradedAndroid = false;

  @override
  void initState() {
    super.initState();
    _initializeDe1StateManager();
    _onboardingController = OnboardingController(
      steps: [
        createAndroidWarningStep(settingsController: widget.settingsController),
        OnboardingStep(
          id: 'welcome',
          shouldShow: () async =>
              !widget.settingsController.onboardingCompleted,
          builder: createWelcomeStep().builder,
        ),
        if (widget.decentAccountService != null)
          createLoginStep(
            accountService: widget.decentAccountService!,
            settingsController: widget.settingsController,
          ),
        createPermissionsStep(de1Controller: widget.de1Controller),
        createInitializationStep(
          deviceController: widget.deviceController,
          de1Controller: widget.de1Controller,
          pluginLoaderService: widget.pluginLoaderService,
          webUIStorage: widget.webUIStorage,
          webUIService: widget.webUIService,
        ),
        if (widget.profileStorageService != null &&
            widget.beanStorage != null &&
            widget.grinderStorage != null)
          OnboardingStep(
            id: 'import',
            shouldShow: () async =>
                !widget.settingsController.onboardingCompleted,
            builder: createImportStep(
              storageService: widget.persistenceController.storageService,
              profileStorageService: widget.profileStorageService!,
              beanStorageService: widget.beanStorage!,
              grinderStorageService: widget.grinderStorage!,
              settingsController: widget.settingsController,
              persistenceController: widget.persistenceController,
              workflowController: widget.workflowController,
            ).builder,
          ),
        createScanStep(
          connectionManager: widget.connectionManager,
          deviceController: widget.deviceController,
          settingsController: widget.settingsController,
          scanStateGuardian: widget.scanStateGuardian,
          directConnect: widget.directConnect,
          onSkipToDashboard: () {
            NavigationService.navigatorKey.currentState
                ?.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
          },
        ),
      ],
    );
    _onboardingController.initialize();
    _resolveDegradedAndroid();
  }

  Future<void> _resolveDegradedAndroid() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (mounted && info.version.sdkInt < 31) {
        setState(() => _degradedAndroid = true);
      }
    } catch (e) {
      _log.warning('Failed to resolve Android SDK for degraded check: $e');
    }
  }

  @override
  void didUpdateWidget(MyApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsController != widget.settingsController ||
        oldWidget.de1Controller != widget.de1Controller ||
        oldWidget.connectionManager != widget.connectionManager ||
        oldWidget.scaleController != widget.scaleController ||
        oldWidget.workflowController != widget.workflowController ||
        oldWidget.persistenceController != widget.persistenceController) {
      _de1StateManager?.dispose();
      _de1StateManager = null;
      _initializeDe1StateManager();
    }
  }

  void _initializeDe1StateManager() {
    _de1StateManager = De1StateManager(
      de1Controller: widget.de1Controller,
      scaleController: widget.scaleController,
      workflowController: widget.workflowController,
      persistenceController: widget.persistenceController,
      settingsController: widget.settingsController,
      connectionManager: widget.connectionManager,
      accountService: widget.decentAccountService,
      navigatorKey: NavigationService.navigatorKey,
    );
  }

  Future<void> _navigateAfterOnboarding() async {
    final navigator = NavigationService.navigatorKey.currentState;
    if (navigator == null) return;

    navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);

    final supportedPlatforms =
        Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows;
    if (!supportedPlatforms || _degradedAndroid) {
      _log.info(
        'Skin not auto-opened (unsupported platform or degraded '
        'Android) — launcher shows the browser hero card.',
      );
      return;
    }

    if (!widget.webUIService.isServing) {
      _log.info('WebUI not serving, attempting to start...');
      final defaultSkin = widget.webUIStorage.defaultSkin;
      if (defaultSkin == null) {
        _log.warning('No default skin available — staying on launcher.');
        return;
      }
      try {
        await widget.webUIService.serveFolderAtPath(defaultSkin.path);
        _log.info('WebUI service started successfully');
      } catch (e) {
        _log.severe('Failed to start WebUI service: $e — staying on launcher.');
        return;
      }
    }

    _log.info('Navigating to SkinView');
    SkinView.open(navigator);
  }

  @override
  void dispose() {
    _de1StateManager?.dispose();
    _onboardingController.dispose();
    _restartTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _restartTimer?.cancel();
    _restartTimer = Timer.periodic(Duration(hours: 1), (_) {
      final now = DateTime.now();
      if (now.hour == 1) {
        AppRoot.restart(context);
      }
    });

    final body = ScaffoldMessenger(
      child: ListenableBuilder(
        listenable: widget.settingsController,
        builder: (BuildContext context, Widget? child) {
          return ShadApp(
            restorationScopeId: null,

            supportedLocales: const [Locale('en', '')],

            onGenerateTitle: (BuildContext context) => "Decaid",
            theme: ShadThemeData(
              colorScheme: DecentColorScheme.light(),
              brightness: Brightness.light,
            ),
            darkTheme: ShadThemeData(
              colorScheme: DecentColorScheme.dark(),
              brightness: Brightness.dark,
            ),
            themeMode: widget.settingsController.themeMode,

            navigatorKey: NavigationService.navigatorKey,
            navigatorObservers: [
              PresenceNavigatorObserver(
                presenceController: widget.presenceController,
              ),
            ],
            onGenerateRoute: (RouteSettings routeSettings) {
              return MaterialPageRoute<void>(
                settings: routeSettings,
                builder: (BuildContext context) {
                  switch (routeSettings.name) {
                    case SettingsView.routeName:
                      return SettingsView(
                        controller: widget.settingsController,
                        updateCheckService: widget.updateCheckService,
                        macosUpdater: widget.macosUpdater,
                        presenceController: widget.presenceController,
                        webUIStorage: widget.webUIStorage,
                      );
                    case De1DebugView.routeName:
                      final args = routeSettings.arguments;
                      final String deviceId;
                      if (args is Map<String, dynamic>) {
                        deviceId = args['deviceId'] as String;
                      } else {
                        deviceId = args as String;
                      }
                      var device = widget.deviceController.devices.firstWhere(
                        (e) => e.deviceId == deviceId,
                      );
                      if (device is De1Interface) {
                        return De1DebugView(
                          machine: device,
                          de1Controller: widget.de1Controller,
                        );
                      }
                      if (device is Scale) {
                        return ScaleDebugView(scale: device);
                      }
                      return Scaffold(
                        body: ShadButton.link(
                          child: Text("No mapping for ${device.name}"),
                          onPressed: () {
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                        ),
                      );
                    case DebugItemListView.routeName:
                      return DebugItemListView(
                        controller: widget.deviceController,
                        de1Controller: widget.de1Controller,
                      );
                    case RealtimeShotFeature.routeName:
                      final args = routeSettings.arguments;
                      ShotSequencer shotSequencer;
                      if (args is ShotSequencer) {
                        shotSequencer = args;
                      } else {
                        final beverageType = widget
                            .workflowController
                            .currentWorkflow
                            .profile
                            .beverageType;
                        final scalelessBeverage =
                            beverageType == BeverageType.cleaning ||
                            beverageType == BeverageType.calibrate;
                        shotSequencer = ShotSequencer(
                          scaleController: widget.scaleController,
                          de1controller: widget.de1Controller,
                          persistenceController: widget.persistenceController,
                          targetProfile:
                              widget.workflowController.currentWorkflow.profile,
                          targetYield:
                              widget
                                  .workflowController
                                  .currentWorkflow
                                  .context
                                  ?.targetYield ??
                              0,
                          bypassSAW:
                              widget.settingsController.gatewayMode ==
                              GatewayMode.full,
                          blockOnNoScale:
                              widget.settingsController.blockOnNoScale &&
                              !scalelessBeverage,
                          weightFlowMultiplier:
                              widget.settingsController.weightFlowMultiplier,
                          volumeFlowMultiplier:
                              widget.settingsController.volumeFlowMultiplier,
                          stepExitArbiterEnabled: widget.settingsController
                              .isFeatureFlagEnabled(
                                FeatureFlag.stepExitArbiter,
                              ),
                        );
                      }
                      return RealtimeShotFeature(
                        shotSequencer: shotSequencer,
                        workflowController: widget.workflowController,
                      );
                    case RealtimeSteamFeature.routeName:
                      final args =
                          routeSettings.arguments as Map<String, dynamic>;
                      De1Controller de1Controller = args['controller'];
                      SteamSettings steamSettings = args['data'];
                      return RealtimeSteamFeature(
                        de1Controller: de1Controller,
                        initialSteamSettings: steamSettings,
                        gatewayMode: widget.settingsController.gatewayMode,
                      );
                    case LauncherView.routeName:
                      return LauncherView(
                        de1Controller: widget.de1Controller,
                        scaleController: widget.scaleController,
                        webUIService: widget.webUIService,
                        batteryController: widget.batteryController,
                        decentAccountService: widget.decentAccountService,
                        isDegradedAndroid: _degradedAndroid,
                        connectionManager: widget.connectionManager,
                        deviceController: widget.deviceController,
                        settingsController: widget.settingsController,
                        scanStateGuardian: widget.scanStateGuardian,
                      );
                    case HistoryFeature.routeName:
                      final possibleShot = routeSettings.arguments as String;
                      return HistoryFeature(
                        persistenceController: widget.persistenceController,
                        workflowController: widget.workflowController,
                        selectedShot: possibleShot,
                      );
                    case PluginsSettingsView.routeName:
                      return PluginsSettingsView(
                        pluginLoaderService: widget.pluginLoaderService,
                        decentAccountService: widget.decentAccountService,
                      );
                    case DeviceManagementPage.routeName:
                      return DeviceManagementPage(
                        settingsController: widget.settingsController,
                        deviceController: widget.deviceController,
                      );
                    case DataManagementPage.routeName:
                      return DataManagementPage(
                        controller: widget.settingsController,
                        persistenceController: widget.persistenceController,
                        de1Controller: widget.de1Controller,
                        decentAccountService: widget.decentAccountService,
                        profileStorageService: widget.profileStorageService,
                        beanStorageService: widget.beanStorage,
                        grinderStorageService: widget.grinderStorage,
                        workflowController: widget.workflowController,
                      );
                    case SkinSelectorPage.routeName:
                      return SkinSelectorPage(
                        settingsController: widget.settingsController,
                        webUIService: widget.webUIService,
                        webUIStorage: widget.webUIStorage,
                      );
                    case AdvancedPage.routeName:
                      return AdvancedPage(
                        controller: widget.settingsController,
                      );
                    case AccountPage.routeName:
                      if (widget.decentAccountService == null) {
                        return Scaffold(
                          body: Center(
                            child: Text('Account service not available'),
                          ),
                        );
                      }
                      return AccountPage(
                        accountService: widget.decentAccountService!,
                        tokensController: widget.accountTokensController,
                        appLogUploadService: widget.appLogUploadService,
                      );
                    case LauncherScanPage.routeName:
                      return LauncherScanPage(
                        connectionManager: widget.connectionManager,
                        deviceController: widget.deviceController,
                        settingsController: widget.settingsController,
                        scanStateGuardian: widget.scanStateGuardian,
                      );
                    case SkinView.routeName:
                      return SkinView(
                        settingsController: widget.settingsController,
                        webViewLogService: widget.webViewLogService,
                        deviceIp: widget.webUIService.deviceIp(),
                        displayController: widget.displayController,
                        port: widget.webUIService.port,
                      );
                    default:
                      return OnboardingView(
                        controller: _onboardingController,
                        onComplete: () => _navigateAfterOnboarding(),
                      );
                  }
                },
              );
            },
          );
        },
      ),
    );

    return body;
  }
}
