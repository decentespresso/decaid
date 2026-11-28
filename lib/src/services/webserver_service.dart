import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Router, Visibility, ConnectionState;
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/utils.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/device/scale_preference.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:reaprime/src/services/webserver/opaque_path_component.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver/data_sync_handler.dart';
import 'package:reaprime/src/services/webserver/firmware_handler.dart';
import 'package:reaprime/src/services/webserver/data_export/profile_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver/data_export/shot_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/steam_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/workflow_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/settings_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/kv_store_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/bean_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/grinder_export_section.dart';
import 'package:reaprime/src/services/webserver/beans_handler.dart';
import 'package:reaprime/src/services/webserver/grinders_handler.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:reaprime/src/services/webserver/steams_handler.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/sleep_timeout_preference.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/util/rot13.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/services/webserver/port_binding.dart';
import 'package:reaprime/src/services/webserver/api_listener.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart' as sws;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/installed_components.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver/proxy_auth_middleware.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver/info_handler.dart';
import 'package:reaprime/src/services/webserver/ble_diagnostics_handler.dart';
import 'package:reaprime/src/services/webserver/debug_handler.dart';
import 'package:reaprime/src/services/firmware/bundled_firmware_catalog.dart';
import 'package:reaprime/src/services/webserver/wifi_scale_handler.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/models/device/device.dart' as device;

import 'webserver/feedback_handler.dart';

part 'webserver/de1handler.dart';
part 'webserver/scale_handler.dart';
part 'webserver/devices_handler.dart';
part 'webserver/grinder_handler.dart';
part 'webserver/settings_handler.dart';
part 'webserver/sensors_handler.dart';
part 'webserver/kv_store_handler.dart';
part 'webserver/plugins_handler.dart';
part 'webserver/profile_handler.dart';
part 'webserver/webui_handler.dart';
part 'webserver/logs_handler.dart';
part 'webserver/webview_logs_handler.dart';
part 'webserver/presence_handler.dart';
part 'webserver/display_handler.dart';
part 'webserver/account_handler.dart';
part 'webserver/account_proxy_handler.dart';
part 'webserver/derek_handler.dart';
part 'webserver/update_handler.dart';
part 'webserver/admission_control.dart';

const _corsExposedResponseHeaders = [
  'ETag',
  'Location',
  'Content-Disposition',
  'Retry-After',
  'X-Request-Id',
];

final log = Logger("Webservice");

Future<ApiListener> startWebServer(
  DeviceController deviceController,
  De1Controller de1Controller,
  ScaleController scaleController,
  SettingsController settingsController,
  SensorController sensorController,
  WorkflowController workflowController,
  PersistenceController persistenceController,
  PluginLoaderService pluginService,
  WebUIService webUIService,
  WebUIStorage webUIStorage,
  ProfileController profileController,
  String logFilePath,
  WebViewLogService webViewLogService,
  BatteryController? batteryController,
  PresenceController? presenceController,
  DisplayController? displayController, {
  BeanStorageService? beanStorage,
  GrinderStorageService? grinderStorage,
  required ConnectionManager connectionManager,
  required BackupDataSources backupSources,
  WifiScaleDiscoveryService? wifiScaleDiscoveryService,
  RememberedDevicesController? rememberedDevicesController,
  DecentAccountService? decentAccountService,
  DecentProxyService? decentProxyService,
  ProxyTokenService? proxyTokenService,
  UpdateCheckService? updateCheckService,
  required PluginSourceService pluginSourceService,
  GithubCredentialProvider? credentials,
}) async {
  log.info("starting webserver");
  final de1Handler = De1Handler(
    controller: de1Controller,
    settingsController: settingsController,
    scaleController: scaleController,
    workflowController: workflowController,
  );
  final firmwareHandler = FirmwareHandler(
    controller: de1Controller,
    catalog: BundledFirmwareCatalog(bundle: rootBundle),
  );
  final scaleHandler = ScaleHandler(
    controller: scaleController,
    auxiliaryScaleRegistry: connectionManager.auxiliaryScaleRegistry,
    de1Controller: de1Controller,
    settingsController: settingsController,
  );
  final grinderHandler = GrinderHandler(
    controller: connectionManager.grinderController,
  );
  final deviceHandler = DevicesHandler(
    controller: deviceController,
    batteryController: batteryController,
    connectionManager: connectionManager,
    rememberedController: rememberedDevicesController,
    preferredScaleId: () => settingsController.preferredScaleId,
    preferredGrinderDeviceId: () => settingsController.preferredGrinderDeviceId,
  );
  final settingsHandler = SettingsHandler(
    controller: settingsController,
    service: webUIService,
    webUIStorage: webUIStorage,
    batteryController: batteryController,
    deviceScanner: deviceController,
  );
  final sensorsHandler = SensorsHandler(controller: sensorController);
  final workflowHandler = WorkflowHandler(
    controller: workflowController,
    de1controller: de1Controller,
  );
  final ShotsHandler shotsHandler = ShotsHandler(
    controller: persistenceController,
    beanStorage: beanStorage,
  );
  final SteamsHandler steamsHandler = SteamsHandler(
    controller: persistenceController,
  );

  final PluginsHandler pluginsHandler = PluginsHandler(
    pluginManager: pluginService.pluginManager,
    pluginService: pluginService,
    pluginSourceService: pluginSourceService,
  );

  final profileHandler = ProfileHandler(controller: profileController);

  final webUIHandler = WebUIHandler(
    storage: webUIStorage,
    service: webUIService,
  );

  final feedbackHandler = FeedbackHandler(
    service: FeedbackService(
      githubToken: rot13(
        const String.fromEnvironment('GITHUB_FEEDBACK_TOKEN', defaultValue: ''),
      ),
      currentSerialNumbers: () => de1Controller.seenSerials,
      installedComponents: () => collectInstalledComponents(
        webUIService: webUIService,
        webUIStorage: webUIStorage,
        pluginService: pluginService,
      ),
      accountService: decentAccountService,
      credentials: credentials,
    ),
  );

  final logsHandler = LogsHandler(logFilePath: logFilePath);
  final accountHandler = decentAccountService == null
      ? null
      : AccountHandler(accountService: decentAccountService);

  final accountProxyHandler = decentProxyService == null
      ? null
      : AccountProxyHandler(proxy: decentProxyService, enableWrites: true);

  final derekHandler = DerekHandler();

  final webViewLogsHandler = WebViewLogsHandler(
    webViewLogService: webViewLogService,
  );

  PresenceHandler? presenceHandler;
  if (presenceController != null) {
    presenceHandler = PresenceHandler(
      presenceController: presenceController,
      settingsController: settingsController,
    );
  }

  DisplayHandler? displayHandler;
  if (displayController != null) {
    displayHandler = DisplayHandler(displayController: displayController);
  }

  BeansHandler? beansHandler;
  if (beanStorage != null) {
    beansHandler = BeansHandler(storage: beanStorage);
  }

  GrindersHandler? grindersHandler;
  if (grinderStorage != null) {
    grindersHandler = GrindersHandler(storage: grinderStorage);
  }

  final kvStoreHandler = KvStoreHandler();
  await kvStoreHandler.store.initialize();

  final dataExportHandler = DataExportHandler(
    sections: [
      ProfileExportSection(controller: profileController),
      ShotExportSection(
        controller: persistenceController,
        pageShots: (limit, {afterTimestamp, afterCreatedAt, afterId}) =>
            backupSources.pageShots(
              limit,
              afterTimestamp: afterTimestamp,
              afterId: afterId,
            ),
      ),
      SteamExportSection(
        controller: persistenceController,
        pageSteams: (limit, {afterTimestamp, afterCreatedAt, afterId}) =>
            backupSources.pageSteams(
              limit,
              afterTimestamp: afterTimestamp,
              afterId: afterId,
            ),
      ),
      WorkflowExportSection(controller: workflowController),
      SettingsExportSection(controller: settingsController),
      KvStoreExportSection(store: kvStoreHandler.store),
      if (beanStorage != null)
        BeanExportSection(
          storage: beanStorage,
          pageBeans: (limit, {afterTimestamp, afterCreatedAt, afterId}) =>
              backupSources.pageBeans(
                limit,
                afterCreatedAt: afterCreatedAt,
                afterId: afterId,
              ),
        ),
      if (grinderStorage != null)
        GrinderExportSection(
          storage: grinderStorage,
          pageGrinders: (limit, {afterTimestamp, afterCreatedAt, afterId}) =>
              backupSources.pageGrinders(
                limit,
                afterCreatedAt: afterCreatedAt,
                afterId: afterId,
              ),
        ),
    ],
  );

  final dataSyncHandler = DataSyncHandler(
    exportHandler: dataExportHandler,
    httpClient: IOClient(
      HttpClient()
        ..connectionTimeout = dataExportHandler.limits.syncHeaderTimeout,
    ),
  );

  final infoHandler = InfoHandler();
  final bleDiagnosticsHandler = BleDiagnosticsHandler(
    deviceController: deviceController,
    connectionManager: connectionManager,
    settingsController: settingsController,
  );

  final updateHandler = updateCheckService == null
      ? null
      : UpdateHandler(service: updateCheckService);

  final wifiScaleHandler = wifiScaleDiscoveryService == null
      ? null
      : WifiScaleHandler(service: wifiScaleDiscoveryService);

  DebugHandler? debugHandler;
  const simulateEnv = String.fromEnvironment("simulate");
  if (simulateEnv.isNotEmpty) {
    debugHandler = DebugHandler(
      scaleController: scaleController,
      de1Controller: de1Controller,
      updateCheckService: updateCheckService,
    );
  }

  int? apiListenerPort;
  String? apiListenerAddress;
  int? apiDocsListenerPort;
  Future<Set<String>> deviceAddresses() =>
      webUIService.currentBrowserOriginAddresses();
  final handler = _init(
    deviceHandler,
    de1Handler,
    firmwareHandler,
    scaleHandler,
    grinderHandler,
    settingsHandler,
    sensorsHandler,
    workflowHandler,
    shotsHandler,
    steamsHandler,
    kvStoreHandler,
    pluginsHandler,
    profileHandler,
    webUIHandler,
    feedbackHandler,
    logsHandler,
    webViewLogsHandler,
    presenceHandler,
    displayHandler,
    accountHandler,
    accountProxyHandler,
    derekHandler,
    proxyTokenService,
    () => accountProxyCorsAllowedOrigins(webUIService),
    () => settingsController.currentRequireExtensionManagementAuthorization(),
    extensionManagementBrowserOrigins(
      webUIService,
      apiListenerPort: () => apiListenerPort,
      docsListenerPort: () => apiDocsListenerPort,
    ),
    BuiltinPageListener(
      listenerPort: () => apiListenerPort,
      deviceAddresses: deviceAddresses,
      listenerAddress: () => apiListenerAddress,
    ),
    dataExportHandler,
    dataSyncHandler,
    beansHandler,
    grindersHandler,
    infoHandler,
    bleDiagnosticsHandler,
    debugHandler,
    wifiScaleHandler,
    updateHandler,
  );
  pluginService.pluginManager.attachLocalApi(handler);
  final apiListener = ApiListener(handler: handler, port: 8080);
  await apiListener.start();
  apiListenerPort = apiListener.port;
  apiListenerAddress = apiListener.addressString;
  log.info(
    'API Web server running on '
    '${apiListener.addressString}:${apiListener.port}',
  );

  final apiDocsServer = await startApiDocsServer(
    deviceAddresses: deviceAddresses,
  );
  apiDocsListenerPort = apiDocsServer?.port;
  return apiListener;
}

Handler _init(
  DevicesHandler deviceHandler,
  De1Handler de1Handler,
  FirmwareHandler firmwareHandler,
  ScaleHandler scaleHandler,
  GrinderHandler grinderHandler,
  SettingsHandler settingsHandler,
  SensorsHandler sensorsHandler,
  WorkflowHandler workflowHandler,
  ShotsHandler shotsHandler,
  SteamsHandler steamsHandler,
  KvStoreHandler kvStoreHandler,
  PluginsHandler pluginsHandler,
  ProfileHandler profileHandler,
  WebUIHandler webUIHandler,
  FeedbackHandler feedbackHandler,
  LogsHandler logsHandler,
  WebViewLogsHandler webViewLogsHandler,
  PresenceHandler? presenceHandler,
  DisplayHandler? displayHandler,
  AccountHandler? accountHandler,
  AccountProxyHandler? accountProxyHandler,
  DerekHandler derekHandler,
  ProxyTokenService? proxyTokenService,
  Set<String> Function() accountProxyAllowedOrigins,
  Future<bool> Function() requireExtensionManagementAuthorization,
  ExtensionManagementBrowserOrigins browserOrigins,
  BuiltinPageListener? pageListener,
  DataExportHandler dataExportHandler,
  DataSyncHandler dataSyncHandler,
  BeansHandler? beansHandler,
  GrindersHandler? grindersHandler,
  InfoHandler infoHandler,
  BleDiagnosticsHandler bleDiagnosticsHandler,
  DebugHandler? debugHandler,
  WifiScaleHandler? wifiScaleHandler,
  UpdateHandler? updateHandler,
) {
  log.info("called _init");
  var app = createApiRouter();

  deviceHandler.addRoutes(app);
  wifiScaleHandler?.addRoutes(app);
  de1Handler.addRoutes(app);
  firmwareHandler.addRoutes(app);
  scaleHandler.addRoutes(app);
  grinderHandler.addRoutes(app);
  settingsHandler.addRoutes(app);
  sensorsHandler.addRoutes(app);
  workflowHandler.addRoutes(app);
  shotsHandler.addRoutes(app);
  steamsHandler.addRoutes(app);
  kvStoreHandler.addRoutes(app);
  pluginsHandler.addRoutes(app);
  profileHandler.addRoutes(app);
  webUIHandler.addRoutes(app);
  feedbackHandler.addRoutes(app);
  logsHandler.addRoutes(app);
  webViewLogsHandler.addRoutes(app);
  if (presenceHandler != null) {
    presenceHandler.addRoutes(app);
  }
  if (displayHandler != null) {
    displayHandler.addRoutes(app);
  }
  if (accountHandler != null) {
    accountHandler.addRoutes(app);
  }
  if (accountProxyHandler != null) {
    accountProxyHandler.addRoutes(app);
  }
  derekHandler.addRoutes(app);
  dataExportHandler.addRoutes(app);
  dataSyncHandler.addRoutes(app);
  if (beansHandler != null) {
    beansHandler.addRoutes(app);
  }
  if (grindersHandler != null) {
    grindersHandler.addRoutes(app);
  }
  infoHandler.addRoutes(app);
  bleDiagnosticsHandler.addRoutes(app);
  updateHandler?.addRoutes(app);
  if (debugHandler != null) {
    debugHandler.addRoutes(app);
  }

  return buildWebServerHandler(
    app.call,
    proxyTokenService: proxyTokenService,
    accountProxyAllowedOrigins: accountProxyAllowedOrigins,
    requireExtensionManagementAuthorization:
        requireExtensionManagementAuthorization,
    browserOrigins: browserOrigins,
    pageListener: pageListener,
  );
}

Set<String> _noAccountProxyOrigins() => const {};

const builtinSettingsPagePath = '/api/v1/plugins/settings.reaplugin/ui';

const builtinApiDocsViewerPaths = {'/', '/index.html'};

const builtinPageAddressUnavailableError =
    'This page is only served from the device address';

final class BuiltinPageListener {
  const BuiltinPageListener({
    required this.listenerPort,
    required this.deviceAddresses,
    this.listenerAddress,
  });

  final int? Function() listenerPort;
  final Future<Set<String>> Function() deviceAddresses;
  final String? Function()? listenerAddress;
}

Middleware builtinBrowserCanonicalRedirect({
  required Set<String> pagePaths,
  required BuiltinPageListener listener,
}) {
  return (Handler inner) {
    return (Request request) async {
      if (request.method != 'GET') return inner(request);
      final path = _pageRequestPath(request.url);
      if (!pagePaths.contains(path)) return inner(request);
      final entryHost = _pageHostName(request.headers['host']);
      if (entryHost == null) return _builtinPageAddressRefusal();
      if (!_requiresCanonicalPageHost(entryHost)) return inner(request);
      final refusal = _builtinPageAddressRefusal();
      final connectionInfo = request.context[_pageConnectionInfoKey];
      if (connectionInfo is! HttpConnectionInfo) return refusal;
      final InternetAddress peer;
      try {
        peer = connectionInfo.remoteAddress;
      } catch (error, stackTrace) {
        log.warning('The socket peer is unreadable', error, stackTrace);
        return refusal;
      }
      final port = listener.listenerPort();
      if (port == null || port < 1 || port > 65535) return refusal;
      var addresses = const <String>{};
      if (!peer.isLoopback) {
        try {
          addresses = await listener.deviceAddresses();
        } catch (error, stackTrace) {
          log.warning(
            'Could not enumerate the device addresses; refusing the page entry',
            error,
            stackTrace,
          );
          return refusal;
        }
      }
      final destination = canonicalPageHost(
        peer: peer,
        addresses: addresses,
        boundAddress: listener.listenerAddress?.call(),
      );
      if (destination == null) return refusal;
      return Response.found(
        builtinPageLocation(host: destination, port: port, path: path),
        headers: const {
          'cache-control': 'no-store',
          'referrer-policy': 'no-referrer',
        },
      );
    };
  };
}

final _pageConnectionInfoKey = 'shelf.io.connection_info';

final _pagePortSuffix = RegExp(r'^:(\d{1,5})$');
const _pageHostLabel = '[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?';
final _pageRegName = RegExp('^$_pageHostLabel(?:\\.$_pageHostLabel)*\\.?\$');

Uri builtinPageLocation({
  required String host,
  required int port,
  required String path,
}) => Uri(scheme: 'http', host: host, port: port, path: path, fragment: '');

String? canonicalPageHost({
  required InternetAddress peer,
  required Set<String> addresses,
  String? boundAddress,
}) {
  final normalizedPeer = _normalizedPageAddress(peer);
  if (normalizedPeer == null) return null;
  if (normalizedPeer.isLoopback) {
    return normalizedPeer.type == InternetAddressType.IPv6
        ? '::1'
        : '127.0.0.1';
  }
  final bound = boundAddress == null ? null : _pageAddress(boundAddress);
  if (bound != null && _isPageCandidate(bound, normalizedPeer)) {
    return bound.address;
  }
  final candidates = <String>{};
  final seen = <String>{};
  for (final address in addresses) {
    final parsed = _pageAddress(address);
    if (parsed == null || !_isPageCandidate(parsed, normalizedPeer)) continue;
    if (!seen.add(_pageAddressKey(parsed))) continue;
    candidates.add(parsed.address);
  }
  return candidates.length == 1 ? candidates.single : null;
}

bool _isPageCandidate(InternetAddress address, InternetAddress peer) =>
    address.type == peer.type &&
    !address.isLoopback &&
    _isPageDestination(address);

String _pageAddressKey(InternetAddress address) =>
    '${address.type.name}:${address.rawAddress.join('.')}';

InternetAddress? _pageAddress(String text) {
  final parsed = InternetAddress.tryParse(text);
  return parsed == null ? null : _normalizedPageAddress(parsed);
}

InternetAddress? _normalizedPageAddress(InternetAddress address) {
  if (address.address.contains('%')) return null;
  final raw = address.rawAddress;
  if (raw.length != 16) return InternetAddress.fromRawAddress(raw);
  var mapped = raw[10] == 0xff && raw[11] == 0xff;
  for (var index = 0; index < 10 && mapped; index++) {
    if (raw[index] != 0) mapped = false;
  }
  if (mapped) return InternetAddress.fromRawAddress(raw.sublist(12));
  return InternetAddress.fromRawAddress(raw, type: InternetAddressType.IPv6);
}

bool _isPageDestination(InternetAddress address) {
  final raw = address.rawAddress;
  if (raw.every((byte) => byte == 0)) return false;
  if (raw.length == 4) {
    if ((raw[0] & 0xf0) == 0xe0) return false;
    return !raw.every((byte) => byte == 0xff);
  }
  if (raw[0] == 0xff) return false;
  return !(raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80);
}

String _pageRequestPath(Uri url) {
  final path = url.path;
  if (path.isEmpty) return '/';
  return path.startsWith('/') ? path : '/$path';
}

bool _requiresCanonicalPageHost(String host) {
  if (host.toLowerCase() == 'localhost') return false;
  return InternetAddress.tryParse(host) == null;
}

String? _pageHostName(String? hostHeader) {
  if (hostHeader == null) return null;
  final value = hostHeader.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('[')) {
    final end = value.indexOf(']');
    if (end < 0) return null;
    final literal = value.substring(1, end);
    if (!_isPageIpv6Literal(literal)) return null;
    if (!_isPagePort(value.substring(end + 1))) return null;
    return literal;
  }
  final colon = value.indexOf(':');
  if (colon < 0) return _pageRegName.hasMatch(value) ? value : null;
  if (!_isPagePort(value.substring(colon))) return null;
  final host = value.substring(0, colon);
  return _pageRegName.hasMatch(host) ? host : null;
}

bool _isPageIpv6Literal(String literal) {
  if (literal.contains('%')) return false;
  return InternetAddress.tryParse(literal)?.type == InternetAddressType.IPv6;
}

bool _isPagePort(String suffix) {
  if (suffix.isEmpty) return true;
  final match = _pagePortSuffix.firstMatch(suffix);
  if (match == null) return false;
  final port = int.parse(match.group(1)!);
  return port >= 1 && port <= 65535;
}

Response _builtinPageAddressRefusal() => Response(
  403,
  body: jsonEncode({'error': builtinPageAddressUnavailableError}),
  headers: const {
    'content-type': 'application/json',
    'cache-control': 'no-store',
  },
);

ExtensionManagementBrowserOrigins extensionManagementBrowserOrigins(
  WebUIService webUIService, {
  required int? Function() apiListenerPort,
  int? Function()? docsListenerPort,
}) => ExtensionManagementBrowserOrigins(
  apiListenerPort: apiListenerPort,
  pagePorts: () => {
    ...webUIService.browserOriginPorts,
    ?docsListenerPort?.call(),
  },
  deviceAddresses: () => webUIService.currentBrowserOriginAddresses(),
);

class ApiDocsConfiguration {
  const ApiDocsConfiguration();

  int get port => 4001;
  String get manifestPath => '/api/v1/manifest';
  String get viewerPath => '/';
  String get openApiPath => '/rest_v1.yml';
  String get asyncApiPath => '/websocket_v1.yml';
  List<String> get assetPaths => [
    'assets/api/index.html',
    'assets/api$openApiPath',
    'assets/api$asyncApiPath',
  ];

  Map<String, Object> get manifest => {
    'api': 'v1',
    'docs': {
      'port': port,
      'viewer': viewerPath,
      'openapi': openApiPath,
      'asyncapi': asyncApiPath,
    },
  };

  String get notFoundHint =>
      'API docs: same host, port $port; viewer $viewerPath; '
      'OpenAPI $openApiPath; AsyncAPI $asyncApiPath';
}

const apiDocsConfiguration = ApiDocsConfiguration();

RouterPlus createApiRouter() {
  final app = Router(
    notFoundHandler: (request) {
      return jsonNotFound({
        'error': 'Route not found',
        'hint': apiDocsConfiguration.notFoundHint,
      });
    },
  ).plus;
  app.get(apiDocsConfiguration.manifestPath, (request) {
    return jsonOk(apiDocsConfiguration.manifest)
        .change(headers: {'Cache-Control': 'public, max-age=300'});
  });
  return app;
}

Handler buildWebServerHandler(
  Handler routes, {
  ProxyTokenService? proxyTokenService,
  Set<String> Function() accountProxyAllowedOrigins = _noAccountProxyOrigins,
  Future<bool> Function()? requireExtensionManagementAuthorization,
  ExtensionManagementBrowserOrigins? browserOrigins,
  AdmissionGate? admissionGate,
  BuiltinPageListener? pageListener,
}) {
  var pipeline = const Pipeline();
  final listener = pageListener;
  if (listener != null) {
    pipeline = pipeline.addMiddleware(
      builtinBrowserCanonicalRedirect(
        pagePaths: const {builtinSettingsPagePath},
        listener: listener,
      ),
    );
  }
  final origins = browserOrigins;
  if (origins != null) {
    pipeline = pipeline.addMiddleware(
      extensionManagementBrowserOriginMiddleware(origins),
    );
  }
  return pipeline
      .addMiddleware(accountProxyCorsMiddleware(accountProxyAllowedOrigins))
      .addMiddleware(logRequestsWithClientIp())
      .addMiddleware(
        corsHeaders(
          headers: {
            'Access-Control-Expose-Headers': _corsExposedResponseHeaders.join(
              ', ',
            ),
            'Access-Control-Allow-Headers': 'Accept, Accept-Encoding, Authorization, Content-Type, DNT, Origin, User-Agent, If-None-Match',
          },
        ),
      )
      .addMiddleware(
        proxyTokenService == null
            ? (Handler h) => h
            : proxyAuthMiddleware(proxyTokenService),
      )
      .addMiddleware(
        extensionManagementAuthMiddleware(
          proxyTokenService,
          requireExtensionManagementAuthorization:
              requireExtensionManagementAuthorization,
        ),
      )
      .addMiddleware(requestBodyReadMiddleware())
      .addMiddleware(apiAdmissionMiddleware(admissionGate ?? _apiAdmissionGate))
      .addHandler(routes);
}

const _shelfConnectionInfoKey = 'shelf.io.connection_info';

Middleware logRequestsWithClientIp({
  void Function(String message, bool isError)? logger,
}) {
  final write =
      logger ?? (msg, isError) => isError ? log.warning(msg) : log.info(msg);

  return (innerHandler) {
    return (request) {
      final startTime = DateTime.now();
      final watch = Stopwatch()..start();
      final ip = clientIpFromRequest(request);

      return Future.sync(() => innerHandler(request)).then(
        (response) {
          write(
            '${startTime.toIso8601String()} '
            '${watch.elapsed.toString().padLeft(15)} '
            '${request.method.padRight(7)} $ip '
            '[${response.statusCode}] '
            '${request.requestedUri.path}'
            '${_formatQuery(request.requestedUri.query)}',
            false,
          );
          return response;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is HijackException) throw error;

          var chain = Chain.forTrace(stackTrace)
              .foldFrames((frame) => frame.isCore || frame.package == 'shelf')
              .terse;

          write(
            '${startTime.toIso8601String()} '
            '${watch.elapsed.toString().padLeft(15)} '
            '${request.method.padRight(7)} $ip '
            '${request.requestedUri.path}'
            '${_formatQuery(request.requestedUri.query)}\n'
            '$error\n$chain',
            true,
          );

          throw error;
        },
      );
    };
  };
}

String clientIpFromRequest(Request request) {
  final info = request.context[_shelfConnectionInfoKey];
  return info is HttpConnectionInfo ? info.remoteAddress.address : '-';
}

String _formatQuery(String query) {
  return query.isEmpty ? '' : '?$query';
}

Set<String> accountProxyCorsAllowedOrigins(WebUIService webUIService) {
  final port = webUIService.port;
  final origins = <String>{
    'http://localhost:$port',
    'http://127.0.0.1:$port',
    'http://[::1]:$port',
  };

  final deviceIp = webUIService.deviceIp().trim();
  if (deviceIp.isNotEmpty) {
    origins.add('http://$deviceIp:$port');
  }

  return origins;
}

Middleware accountProxyCorsMiddleware(
  Set<String> Function() allowedOrigins, {
  String pathPrefix = '/api/v1/account/proxy/',
}) {
  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      if (!request.requestedUri.path.startsWith(pathPrefix)) {
        return response;
      }

      final headerUpdates = _removeHeaderUpdates(
        response,
        'access-control-allow-origin',
      );

      final origin = request.headers['origin'];
      if (origin != null && allowedOrigins().contains(origin)) {
        headerUpdates.addAll(_removeHeaderUpdates(response, 'vary'));
        headerUpdates['Access-Control-Allow-Origin'] = origin;
        headerUpdates['Vary'] = _appendVary(response.headers['vary'], 'Origin');
      }

      return response.change(headers: headerUpdates);
    };
  };
}

Map<String, Object?> _removeHeaderUpdates(Response response, String name) {
  final lowerName = name.toLowerCase();
  final updates = <String, Object?>{};
  final matchingKeys = response.headersAll.keys.where(
    (key) => key.toLowerCase() == lowerName,
  );
  for (final key in matchingKeys) {
    updates[key] = null;
  }
  return updates;
}

String _appendVary(String? value, String headerName) {
  if (value == null || value.trim().isEmpty) {
    return headerName;
  }
  final values = value.split(',').map((part) => part.trim().toLowerCase());
  if (values.contains(headerName.toLowerCase())) {
    return value;
  }
  return '$value, $headerName';
}

Handler createApiDocsHandler(
  String apiDirectory, {
  BuiltinPageListener? pageListener,
}) {
  final handler = createStaticHandler(
    apiDirectory,
    defaultDocument: 'index.html',
    listDirectories: true,
  );
  final listener = pageListener;
  if (listener == null) return handler;
  return const Pipeline()
      .addMiddleware(
        builtinBrowserCanonicalRedirect(
          pagePaths: builtinApiDocsViewerPaths,
          listener: listener,
        ),
      )
      .addHandler(handler);
}

Future<HttpServer?> startApiDocsServer({
  Future<Set<String>> Function()? deviceAddresses,
}) async {
  final viewerAddresses = deviceAddresses;
  int? viewerListenerPort;
  String? viewerListenerAddress;
  final tempDir = await getTemporaryDirectory();
  final apiDir = Directory('${tempDir.path}/api');
  if (!apiDir.existsSync()) {
    apiDir.createSync(recursive: true);
  }

  for (final assetPath in apiDocsConfiguration.assetPaths) {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final filename = assetPath.split('/').last;
    final file = File('${apiDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
  }

  final apiHandler = createApiDocsHandler(
    apiDir.path,
    pageListener: viewerAddresses == null
        ? null
        : BuiltinPageListener(
            listenerPort: () => viewerListenerPort,
            deviceAddresses: viewerAddresses,
            listenerAddress: () => viewerListenerAddress,
          ),
  );

  final HttpServer apiServer;
  try {
    apiServer = await serveOrReportPortInUse(
      apiHandler,
      '0.0.0.0',
      apiDocsConfiguration.port,
    );
  } on WebServerPortInUse catch (e) {
    log.warning(
      'API docs server not started: port ${e.port} is already in use',
    );
    return null;
  }
  viewerListenerPort = apiServer.port;
  viewerListenerAddress = apiServer.address.address;
  log.info(
    '✅ API Docs server running at http://${apiServer.address.host}:${apiServer.port}',
  );
  return apiServer;
}
