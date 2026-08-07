import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/device_discovery_feature/device_discovery_view.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/foreground_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

class PermissionsView extends StatefulWidget {
  final DeviceController deviceController;
  final De1Controller de1controller;
  final ScaleController scaleController;
  final PluginLoaderService? pluginLoaderService;
  final WebUIStorage webUIStorage;
  final WebUIService webUIService;
  final SettingsController settingsController;
  final ConnectionManager? connectionManager;

  const PermissionsView({
    super.key,
    required this.deviceController,
    required this.de1controller,
    required this.scaleController,
    this.pluginLoaderService,
    required this.webUIStorage,
    required this.webUIService,
    required this.settingsController,
    this.connectionManager,
  });

  @override
  State<PermissionsView> createState() => _PermissionsViewState();
}

class _PermissionsViewState extends State<PermissionsView> {
  final Logger _log = Logger("PermissionsView");
  late final Future<bool> _permissionsFuture;

  @override
  void initState() {
    super.initState();
    _permissionsFuture = _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Streamline')),
      body: SafeArea(child: _permissions(context)),
    );
  }

  Widget _permissions(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Streamline is starting ...'),
          FutureBuilder(
            future: _permissionsFuture,
            builder: (context, result) {
              switch (result.connectionState) {
                case ConnectionState.none:
                  return Text("Unknown");
                case ConnectionState.waiting:
                  return _initializingView(context);
                case ConnectionState.active:
                case ConnectionState.done:
                  return _devicePicker(context);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _initializingView(BuildContext context) {
    return Column(
      spacing: 16,
      children: [
        SizedBox(width: 200, child: ShadProgress()),
        Text(
          DeviceDiscoveryView.getRandomCoffeeMessage(),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }

  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (Platform.isAndroid) {
        final sdkVersion = await _getAndroidSdkVersion();
        if (sdkVersion >= 31) {
          await Permission.bluetoothScan.request();
          await Permission.bluetoothConnect.request();
        } else {
          await Permission.bluetooth.request();
          await Permission.locationWhenInUse.request();
        }

        await Permission.notification.request();

        await ForegroundTaskService.start();

        ForegroundTaskService.watchMachineConnection(widget.de1controller.de1);

        final batteryOptStatus =
            await Permission.ignoreBatteryOptimizations.status;
        if (!batteryOptStatus.isGranted) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      } else if (Platform.isIOS) {
        await Permission.bluetooth.request();
      }
    } else {
      try {
        await UniversalBle.availabilityStream
            .firstWhere((e) => e == AvailabilityState.poweredOn)
            .timeout(Duration(seconds: 5));
      } on TimeoutException {
        _log.warning(
          'Bluetooth availability check timed out, continuing without BLE',
        );
      }
    }

    // Initialize WebUI storage and service BEFORE device controller
    _log.info('Initializing WebUI storage...');
    try {
      await widget.webUIStorage.initialize();
      _log.info('WebUI storage initialized successfully');
    } catch (e) {
      _log.severe('Failed to initialize WebUI storage', e);
    }

    final defaultSkin = widget.webUIStorage.defaultSkin;
    if (defaultSkin != null) {
      _log.info('Starting WebUI service with skin: ${defaultSkin.name}');
      try {
        await widget.webUIService.serveFolderAtPath(defaultSkin.path);
        _log.info('WebUI service started successfully');
      } catch (e) {
        _log.severe('Failed to start WebUI service', e);
      }
    } else {
      _log.warning('No default skin available, WebUI service not started');
    }

    if (widget.pluginLoaderService != null) {
      try {
        await widget.pluginLoaderService!.initialize();
      } catch (e) {
        _log.warning('Failed to initialize plugins: $e');
      }
    }

    await widget.deviceController.initialize();

    return true;
  }

  Future<int> _getAndroidSdkVersion() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    return androidInfo.version.sdkInt;
  }

  Widget _devicePicker(BuildContext context) {
    return Center(
      child: DeviceDiscoveryView(
        connectionManager: widget.connectionManager!,
        deviceController: widget.deviceController,
        settingsController: widget.settingsController,
        webUIService: widget.webUIService,
        webUIStorage: widget.webUIStorage,
        logger: _log,
      ),
    );
  }
}
