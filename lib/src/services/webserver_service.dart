import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Router, Visibility, ConnectionState;
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/utils.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart' as sws;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/proxy_auth_middleware.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver/info_handler.dart';
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
part 'webserver/grinder_handler.dart';
part 'webserver/devices_handler.dart';
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

Future<void> startWebServer(
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
    de1Controller: de1Controller,
    settingsController: settingsController,
  );
  final grinderHandler = GrinderHandler(controller: connectionManager.grinderController);
  final deviceHandler = DevicesHandler(
    controller: deviceController,
    batteryController: batteryController,
    connectionManager: connectionManager,
    rememberedController: rememberedDevicesController,
    preferredScaleId: () => settingsController.preferredScaleId,
  );
  final settingsHandler = SettingsHandler(
    controller: settingsController,
    service: webUIService,
    webUIStorage: webUIStorage,
    batteryController: batteryController,
  );
  final sensorsHandler = SensorsHandler(controller: sensorController);
  final workflowHandler = WorkflowHandler(
    controller: workflowController,
    de1controller: de1Controller,
  );
  final ShotsHandler shotsHandler = ShotsHandler(
    controller: persistenceController,
    beanStorage: beanStorage,
    pluginManager: pluginService.pluginManager,
  );
  final SteamsHandler steamsHandler = SteamsHandler(
    controller: persistenceController,
  );

  final PluginsHandler pluginsHandler = PluginsHandler(
    pluginManager: pluginService.pluginManager,
    pluginService: pluginService,
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

  final server = await io.serve(
    _init(
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
      dataExportHandler,
      dataSyncHandler,
      beansHandler,
      grindersHandler,
      infoHandler,
      debugHandler,
      wifiScaleHandler,
      updateHandler,
    ),
    '0.0.0.0',
    8080,
  );
  log.info('API Web server running on ${server.address.host}:${server.port}');

  await startApiDocsServer();
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
  DataExportHandler dataExportHandler,
  DataSyncHandler dataSyncHandler,
  BeansHandler? beansHandler,
  GrindersHandler? grindersHandler,
  InfoHandler infoHandler,
  DebugHandler? debugHandler,
  WifiScaleHandler? wifiScaleHandler,
  UpdateHandler? updateHandler,
) {
  log.info("called _init");
  var app = Router().plus;

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
  updateHandler?.addRoutes(app);
  if (debugHandler != null) {
    debugHandler.addRoutes(app);
  }

  return buildWebServerHandler(
    app.call,
    proxyTokenService: proxyTokenService,
    accountProxyAllowedOrigins: accountProxyAllowedOrigins,
  );
}

Set<String> _noAccountProxyOrigins() => const {};

Handler buildWebServerHandler(
  Handler routes, {
  ProxyTokenService? proxyTokenService,
  Set<String> Function() accountProxyAllowedOrigins = _noAccountProxyOrigins,
  AdmissionGate? admissionGate,
}) {
  return const Pipeline()
      .addMiddleware(accountProxyCorsMiddleware(accountProxyAllowedOrigins))
      .addMiddleware(logRequestsWithClientIp())
      .addMiddleware(
        corsHeaders(
          headers: {
            'Access-Control-Expose-Headers': _corsExposedResponseHeaders.join(
              ', ',
            ),
            'Access-Control-Allow-Headers':
                'Accept, Accept-Encoding, Authorization, Content-Type, DNT, Origin, User-Agent, If-None-Match',
          },
        ),
      )
      .addMiddleware(
        proxyTokenService == null
            ? (Handler h) => h
            : proxyAuthMiddleware(proxyTokenService),
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

Future<void> startApiDocsServer() async {
  final tempDir = await getTemporaryDirectory();
  final apiDir = Directory('${tempDir.path}/api');
  if (!apiDir.existsSync()) {
    apiDir.createSync(recursive: true);
  }

  final assetFiles = [
    'assets/api/index.html',
    'assets/api/rest_v1.yml',
    'assets/api/websocket_v1.yml',
  ];

  for (final assetPath in assetFiles) {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final filename = assetPath.split('/').last;
    final file = File('${apiDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
  }

  final apiHandler = createStaticHandler(
    apiDir.path,
    defaultDocument: 'index.html',
    listDirectories: true,
  );

  final apiServer = await io.serve(apiHandler, '0.0.0.0', 4001);
  log.info(
    '✅ API Docs server running at http://${apiServer.address.host}:${apiServer.port}',
  );
}
