import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/foreground_service.dart';
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../onboarding_controller.dart';

final _log = Logger('InitializationStep');

OnboardingStep createInitializationStep({
  required DeviceController deviceController,
  required De1Controller de1Controller,
  PluginLoaderService? pluginLoaderService,
  required WebUIStorage webUIStorage,
  required WebUIService webUIService,
}) {
  return OnboardingStep(
    id: 'initialization',
    shouldShow: () async => true,
    builder: (controller) => _InitializationStepView(
      onboardingController: controller,
      deviceController: deviceController,
      de1Controller: de1Controller,
      pluginLoaderService: pluginLoaderService,
      webUIStorage: webUIStorage,
      webUIService: webUIService,
    ),
  );
}

class _InitializationStepView extends StatefulWidget {
  final OnboardingController onboardingController;
  final DeviceController deviceController;
  final De1Controller de1Controller;
  final PluginLoaderService? pluginLoaderService;
  final WebUIStorage webUIStorage;
  final WebUIService webUIService;

  const _InitializationStepView({
    required this.onboardingController,
    required this.deviceController,
    required this.de1Controller,
    this.pluginLoaderService,
    required this.webUIStorage,
    required this.webUIService,
  });

  @override
  State<_InitializationStepView> createState() =>
      _InitializationStepViewState();
}

class _InitializationStepViewState extends State<_InitializationStepView> {
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = _initializeServices();
  }

  Future<void> _initializeServices() async {
    BootTiming.mark('init_start');

    final deviceInit = widget.deviceController.initialize();

    _log.info('Initializing WebUI storage...');
    try {
      await widget.webUIStorage.initialize(downloadRemote: false);
      _log.info('WebUI storage initialized successfully');
    } catch (e) {
      _log.severe('Failed to initialize WebUI storage', e);
    }

    final override = widget.webUIService.skinOverride;
    bool served = false;
    if (override.source == SkinSource.path) {
      final path = override.value!;
      if (await _isReadableDirectory(path)) {
        _log.info('Starting WebUI service from --skin-path: $path');
        try {
          await widget.webUIService.serveFolderAtPath(path);
          _log.info('WebUI service started successfully from --skin-path');
          served = true;
        } catch (e) {
          _log.severe('Failed to serve --skin-path: $path', e);
        }
      } else {
        _log.severe('--skin-path not readable or not a directory: $path');
      }
    }
    if (!served) {
      if (override.source == SkinSource.path) {
        _log.info('Falling back to registry default skin');
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
    }

    await deviceInit;
    BootTiming.mark('init_ready');

    if (Platform.isAndroid) {
      await ForegroundTaskService.start();
      ForegroundTaskService.watchMachineConnection(widget.de1Controller.de1);
    }

    BootTiming.mark('scan_start');
    widget.onboardingController.advance();

    final plugins = widget.pluginLoaderService;
    if (plugins != null) {
      unawaited(
        plugins.initialize().catchError(
          (Object e) => _log.warning('Background plugin init failed: $e'),
        ),
      );
    }
    unawaited(
      widget.webUIStorage.downloadRemoteSkinsAndRescan().catchError(
        (Object e) =>
            _log.warning('Background remote-skin download failed: $e'),
      ),
    );
  }

  Future<bool> _isReadableDirectory(String path) async {
    try {
      final dir = Directory(path);
      return await dir.exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      semanticsLabel: 'Starting Decaid',
      body: [
        FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Semantics(
                liveRegion: true,
                child: Text('Error: ${snapshot.error}'),
              );
            }
            return Column(
              spacing: 16,
              children: [
                SizedBox(
                  width: 200,
                  child: Semantics(
                    label: 'Starting Decaid',
                    child: ShadProgress(),
                  ),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Decaid is starting...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
