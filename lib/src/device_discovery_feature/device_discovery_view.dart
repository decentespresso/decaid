import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/home_feature/widgets/device_selection_widget.dart';
import 'package:reaprime/src/shared/connection_error_banner.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';

class DeviceDiscoveryView extends StatefulWidget {
  final ConnectionManager connectionManager;
  final DeviceController deviceController;
  final SettingsController settingsController;
  final WebUIService webUIService;
  final WebUIStorage webUIStorage;
  final Logger logger;

  const DeviceDiscoveryView({
    super.key,
    required this.connectionManager,
    required this.deviceController,
    required this.settingsController,
    required this.webUIService,
    required this.webUIStorage,
    required this.logger,
  });

  static String getRandomCoffeeMessage() {
    final messages = [
      "Dialing in the grinder...",
      "Preheating the portafilter...",
      "Calibrating the tamp pressure...",
      "Blooming the coffee bed...",
      "Checking water hardness...",
      "Polishing the shower screen...",
      "Degassing freshly roasted beans...",
      "Leveling the distribution tool...",
      "Priming the group head...",
      "Adjusting brew temperature to 0.1\u00b0C...",
      "Consulting the barista championship rules...",
      "Measuring TDS with lab precision...",
      "Perfecting the WDT technique...",
      "Activating bluetooth (please turn it on)...",
      "Weighing beans to 0.01g accuracy...",
      "Cleaning the espresso altar...",
      "Channeling positive vibes (not water)...",
      "Waiting for third wave to arrive...",
      "Updating espresso definitions...",
    ];
    return messages[DateTime.now().millisecondsSinceEpoch % messages.length];
  }

  @override
  State<StatefulWidget> createState() => _DeviceDiscoveryState();
}

class _DeviceDiscoveryState extends State<DeviceDiscoveryView> {
  late StreamSubscription<ConnectionStatus> _statusSubscription;
  ConnectionStatus _status = const ConnectionStatus(
    phase: ConnectionPhase.scanning,
  );
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    // Show telemetry consent dialog once (non-blocking, after frame renders)
    if (!widget.settingsController.telemetryConsentDialogShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTelemetryConsentDialog();
      });
    }

    _statusSubscription = widget.connectionManager.status.listen((status) {
      if (!mounted) return;

      // Navigate when ready (only once — connectMachine and connectScale
      // both emit ready, so guard against double navigation)
      if (status.phase == ConnectionPhase.ready &&
          status.pendingAmbiguity == null &&
          !_navigated) {
        _navigated = true;
        _navigateAfterConnection();
        return;
      }

      setState(() {
        _status = status;
      });
    });

    // Kick off the connection flow.
    // Automatic startup uses `connect()` (remembered-machine quick-connect +
    // early stop). Explicit user/API scans use `scanAndConnect()` instead.
    widget.connectionManager.connect();
  }

  @override
  void dispose() {
    _statusSubscription.cancel();
    super.dispose();
  }

  /// Navigates to the appropriate screen after device connection
  Future<void> _navigateAfterConnection() async {
    final supportedPlatforms =
        Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

    if (!supportedPlatforms) {
      widget.logger.info(
        'Platform not supported for WebView, using Landing page',
      );
      _navigateToRoute(LauncherView.routeName);
      return;
    }

    // Ensure WebUI is ready
    if (!widget.webUIService.isServing) {
      widget.logger.info('WebUI not serving, attempting to start...');

      final defaultSkin = widget.webUIStorage.defaultSkin;
      if (defaultSkin != null) {
        try {
          await widget.webUIService.serveFolderAtPath(defaultSkin.path);
          widget.logger.info('WebUI service started successfully');
        } catch (e) {
          widget.logger.severe('Failed to start WebUI service: $e');
          _navigateToRoute(LauncherView.routeName);
          return;
        }
      } else {
        widget.logger.warning('No default skin available, using Landing page');
        _navigateToRoute(LauncherView.routeName);
        return;
      }
    }

    await Future.delayed(const Duration(milliseconds: 500));

    widget.logger.info('Navigating to SkinView');
    _navigateToRoute(SkinView.routeName);
  }

  /// Helper to navigate to a specific route
  void _navigateToRoute(String route) {
    if (!mounted) return;

    if (route == SkinView.routeName) {
      // Push both routes to stack: LauncherView first, then SkinView on top
      Navigator.popAndPushNamed(context, LauncherView.routeName);
      Navigator.of(context).pushNamed(SkinView.routeName);
    } else {
      Navigator.popAndPushNamed(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConnectionErrorBanner(connectionManager: widget.connectionManager),
        Flexible(child: Center(child: _body(context))),
      ],
    );
  }

  Widget _body(BuildContext context) {
    // Error state is handled by ConnectionErrorBanner above the body.
    // Scanning
    if (_status.phase == ConnectionPhase.scanning) {
      return _searchingView(context);
    }

    if (_status.phase == ConnectionPhase.connectingMachine ||
        _status.phase == ConnectionPhase.connectingScale) {
      return _connectingView(context);
    }

    if (_status.pendingAmbiguity == AmbiguityReason.machinePicker) {
      return _resultsView(context);
    }

    if (_status.pendingAmbiguity == AmbiguityReason.scalePicker) {
      return _resultsView(context);
    }

    if (_status.phase == ConnectionPhase.idle &&
        _status.foundMachines.isEmpty &&
        _status.foundScales.isEmpty) {
      return _noDevicesFoundView(context);
    }

    if (_status.phase == ConnectionPhase.idle &&
        (_status.foundMachines.isNotEmpty || _status.foundScales.isNotEmpty)) {
      return _resultsView(context);
    }

    return _searchingView(context);
  }

  Widget _searchingView(BuildContext context) {
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

  Widget _connectingView(BuildContext context) {
    final label = _status.phase == ConnectionPhase.connectingMachine
        ? 'Connecting to your machine...'
        : 'Connecting to your scale...';
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        SizedBox(width: 200, child: ShadProgress()),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _resultsView(BuildContext context) {
    final isConnecting =
        _status.phase == ConnectionPhase.connectingMachine ||
        _status.phase == ConnectionPhase.connectingScale;
    final connectingDeviceId = isConnecting
        ? (_status.foundMachines.isNotEmpty
              ? _status.foundMachines.first.deviceId
              : null)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: 260, maxWidth: 460),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DeviceSelectionWidget(
                  deviceController: widget.deviceController,
                  deviceType: dev.DeviceType.machine,
                  showHeader: true,
                  headerText: "Machines",
                  connectingDeviceId: connectingDeviceId,
                  errorMessage: _status.error?.message,
                  selectedDeviceId: null,
                  preferredDeviceId:
                      widget.settingsController.preferredMachineId,
                  onPreferredChanged: (id) =>
                      widget.settingsController.setPreferredMachineId(id),
                  onDeviceTapped: (device) {
                    setState(() {});
                    widget.settingsController.setPreferredMachineId(
                      device.deviceId,
                    );
                  },
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: DeviceSelectionWidget(
                  deviceController: widget.deviceController,
                  deviceType: dev.DeviceType.scale,
                  showHeader: true,
                  headerText: "Scales",
                  selectedDeviceId: null,
                  preferredDeviceId: widget.settingsController.preferredScaleId,
                  onPreferredChanged: (id) =>
                      widget.settingsController.setPreferredScaleId(id),
                  onDeviceTapped: (device) {
                    setState(() {});
                    widget.settingsController.setPreferredScaleId(
                      device.deviceId,
                    );
                  },
                ),
              ),
            ],
          ),
        ),

        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (!isConnecting)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: () => widget.connectionManager.scanAndConnect(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Icon(LucideIcons.refreshCw, size: 14),
                    Text('ReScan'),
                  ],
                ),
              ),
            ShadButton(
              size: ShadButtonSize.sm,
              onPressed: isConnecting
                  ? null
                  : widget.settingsController.preferredMachineId != null
                  ? () => widget.connectionManager.scanAndConnect()
                  : null,
              child: isConnecting
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        Text('Connecting...'),
                      ],
                    )
                  : Text(
                      widget.settingsController.preferredMachineId != null
                          ? 'Connect'
                          : 'Select a machine',
                    ),
            ),
            if (!isConnecting)
              ShadButton.secondary(
                size: ShadButtonSize.sm,
                onPressed: () {
                  Navigator.popAndPushNamed(context, LauncherView.routeName);
                },
                child: Text('Dashboard'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _noDevicesFoundView(BuildContext context) {
    final theme = ShadTheme.of(context);
    final isScanning = _status.phase == ConnectionPhase.scanning;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 600),
      child: ShadCard(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: 24,
            children: [
              Icon(
                LucideIcons.searchX,
                size: 64,
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
              ),
              Column(
                spacing: 8,
                children: [
                  Text(
                    'No Decent Machines Found',
                    style: theme.textTheme.h3,
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    'The scan completed but no Decent machines were discovered.',
                    style: theme.textTheme.muted,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
              Column(
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isScanning)
                    ShadButton(
                      onPressed: null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          Text('Scanning...'),
                        ],
                      ),
                    )
                  else
                    ShadButton(
                      onPressed: () =>
                          widget.connectionManager.scanAndConnect(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          Icon(LucideIcons.refreshCw, size: 16),
                          Text('Scan Again'),
                        ],
                      ),
                    ),
                  ShadButton.outline(
                    onPressed: () {
                      widget.settingsController
                          .enableSimulatedDevicesForSession({
                            SimulatedDevicesTypes.machine,
                            SimulatedDevicesTypes.scale,
                          });
                      widget.connectionManager.scanAndConnect();
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: [
                        Icon(LucideIcons.gamepad2, size: 16),
                        Text('Try Demo Mode'),
                      ],
                    ),
                  ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: ShadButton.outline(
                          onPressed: _exportLogs,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: [
                              Icon(LucideIcons.fileText, size: 16),
                              Text('Export Logs'),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: ShadButton.secondary(
                          onPressed: () {
                            Navigator.popAndPushNamed(
                              context,
                              LauncherView.routeName,
                            );
                          },
                          child: Text('Continue to Dashboard'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTelemetryConsentDialog() async {
    final result = await showShadDialog<bool>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Help Improve Streamline'),
        description: const Text(
          'Share anonymous crash reports and diagnostics to help us fix '
          'connectivity issues. No personal data is collected — BLE addresses '
          'and IPs are hashed before sending.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No thanks'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Enable'),
          ),
        ],
      ),
    );

    await widget.settingsController.setTelemetryConsentDialogShown(true);
    if (result == true) {
      await widget.settingsController.setTelemetryConsent(true);
      widget.logger.info('Telemetry consent granted by user');
    } else {
      widget.logger.info('Telemetry consent declined by user');
    }
  }

  Future<void> _exportLogs() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final logFile = File('${docs.path}/log.txt');

      if (!await logFile.exists()) {
        if (mounted) {
          showShadDialog(
            context: context,
            builder: (context) => ShadDialog(
              title: Text('No Logs Found'),
              description: Text('Log file does not exist yet.'),
              actions: [
                ShadButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }

      final bytes = await logFile.readAsBytes();
      final outputFile = await FilePicker.saveFile(
        fileName: 'R1-logs-${DateTime.now().millisecondsSinceEpoch}.txt',
        dialogTitle: 'Choose where to save logs',
        bytes: bytes,
      );

      if (outputFile != null) {
        if (mounted) {
          showShadDialog(
            context: context,
            builder: (context) => ShadDialog(
              title: Text('Logs Exported'),
              description: Text(
                'Logs have been successfully exported to:\n$outputFile',
              ),
              actions: [
                ShadButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showShadDialog(
          context: context,
          builder: (context) => ShadDialog(
            title: Text('Export Failed'),
            description: Text('Failed to export logs: $e'),
            actions: [
              ShadButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }
}
