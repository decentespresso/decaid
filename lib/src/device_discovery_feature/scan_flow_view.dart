import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/device_discovery_feature/scan_flow_presentation.dart';
import 'package:reaprime/src/home_feature/widgets/device_selection_widget.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:reaprime/src/models/device/scale.dart' as device_scale;
import 'package:reaprime/src/services/telemetry/boot_timing.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../onboarding_feature/widgets/scan_results_summary.dart';
import '../onboarding_feature/widgets/troubleshooting_wizard.dart';

final _log = Logger('ScanFlow');

class ScanFlowView extends StatefulWidget {
  final ConnectionManager connectionManager;
  final DeviceController deviceController;
  final SettingsController settingsController;
  final ScanStateGuardian scanStateGuardian;

  final bool directConnect;

  final VoidCallback? initialConnectionIntent;

  final VoidCallback onConnected;

  final VoidCallback onExit;

  final String exitLabel;

  static const scanTooLongThreshold = Duration(seconds: 16);

  const ScanFlowView({
    super.key,
    required this.connectionManager,
    required this.deviceController,
    required this.settingsController,
    required this.scanStateGuardian,
    this.directConnect = false,
    this.initialConnectionIntent,
    required this.onConnected,
    required this.onExit,
    this.exitLabel = 'Dashboard',
  });

  @override
  State<ScanFlowView> createState() => ScanFlowViewState();
}

class ScanFlowViewState extends State<ScanFlowView> {
  void _skipToDashboard() => widget.onExit();

  void _retry() => widget.connectionManager.scanAndConnect();

  void _tryDemoMode() {
    widget.settingsController.enableSimulatedDevicesForSession({
      SimulatedDevicesTypes.machine,
      SimulatedDevicesTypes.scale,
    });
    widget.connectionManager.scanAndConnect();
  }

  void _tryDemoModeFromNoDevices() {
    widget.settingsController.enableSimulatedDevicesForSession({
      SimulatedDevicesTypes.machine,
      SimulatedDevicesTypes.scale,
    });
    widget.connectionManager.scanAndConnect();
  }

  late StreamSubscription<ConnectionStatus> _statusSubscription;
  late StreamSubscription<ScanStateEvent> _guardianSubscription;
  late StreamSubscription<List<dev.Device>> _deviceSubscription;
  ConnectionStatus _status = const ConnectionStatus(
    phase: ConnectionPhase.scanning,
  );
  bool _hasNavigated = false;
  bool _showTakingTooLong = false;
  bool _showDevicePickerOverride = false;
  Timer? _tooLongTimer;

  bool _directAutoConnected = false;

  List<De1Interface> _discoveredMachines = [];
  List<device_scale.Scale> _discoveredScales = [];

  String? _selectedMachineId;
  String? _selectedScaleId;

  @override
  void initState() {
    super.initState();

    _statusSubscription = widget.connectionManager.status.listen((status) {
      if (!mounted) return;

      if (status.phase != _status.phase) {
        BootTiming.mark('connect_${status.phase.name}');
      }

      if (status.phase == ConnectionPhase.ready &&
          status.pendingAmbiguity == null &&
          !_hasNavigated) {
        _hasNavigated = true;
        _cancelTooLongTimer();
        BootTiming.mark('scan_ready');
        widget.onConnected();
        return;
      }

      if (widget.directConnect && !_directAutoConnected) {
        if (status.pendingAmbiguity == AmbiguityReason.machinePicker &&
            _discoveredMachines.isNotEmpty) {
          _directAutoConnected = true;
          _log.info(
            '--direct: auto-connecting to ${_discoveredMachines.first.name}',
          );
          unawaited(
            widget.connectionManager.selectMachine(_discoveredMachines.first),
          );
          return;
        }
        if (status.pendingAmbiguity == AmbiguityReason.scalePicker &&
            _discoveredScales.isNotEmpty) {
          _directAutoConnected = true;
          _log.info(
            '--direct: auto-connecting to scale ${_discoveredScales.first.name}',
          );
          unawaited(
            widget.connectionManager.selectScale(_discoveredScales.first),
          );
          return;
        }
      }

      if (status.phase != ConnectionPhase.scanning) {
        _cancelTooLongTimer();
      } else {
        _selectedMachineId = null;
        _selectedScaleId = null;
        _showDevicePickerOverride = false;
      }

      if (status.phase == ConnectionPhase.scanning &&
          _status.phase != ConnectionPhase.scanning) {
        _discoveredMachines = [];
        _discoveredScales = [];
        _startTooLongTimer();
      }

      setState(() {
        _status = status;
      });
    });

    _deviceSubscription = widget.deviceController.deviceStream.listen((
      devices,
    ) {
      if (!mounted || _status.phase != ConnectionPhase.scanning) return;
      setState(() {
        _discoveredMachines = devices.whereType<De1Interface>().toList();
        _discoveredScales = devices.whereType<device_scale.Scale>().toList();
      });
    });

    _guardianSubscription = widget.scanStateGuardian.events.listen(
      _onGuardianEvent,
    );

    final intent = widget.initialConnectionIntent;
    if (intent != null) {
      intent();
    } else {
      widget.connectionManager.connect();
    }
    _startTooLongTimer();
  }

  void _startTooLongTimer() {
    _cancelTooLongTimer();
    _showTakingTooLong = false;
    _tooLongTimer = Timer(ScanFlowView.scanTooLongThreshold, () {
      if (mounted && _status.phase == ConnectionPhase.scanning) {
        setState(() {
          _showTakingTooLong = true;
        });
      }
    });
  }

  void _cancelTooLongTimer() {
    _tooLongTimer?.cancel();
    _tooLongTimer = null;
    if (_showTakingTooLong) {
      _showTakingTooLong = false;
    }
  }

  void _onGuardianEvent(ScanStateEvent event) {
    if (!mounted) return;
    if (event == ScanStateEvent.scanStateStale &&
        _status.phase == ConnectionPhase.scanning) {
      _log.info('Stale scan detected, restarting');
      widget.connectionManager.scanAndConnect();
    }
  }

  @override
  void dispose() {
    _cancelTooLongTimer();
    _statusSubscription.cancel();
    _guardianSubscription.cancel();
    _deviceSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blockingCondition = _conditionWithDisposition(
      TransportConditionDisposition.blocking,
    );
    final noticeCondition = _conditionWithDisposition(
      TransportConditionDisposition.notice,
    );
    Widget content;

    if (blockingCondition != null) {
      content = _adapterErrorView(context, blockingCondition.connectionError);
    } else if (_status.pendingAmbiguity == AmbiguityReason.machinePicker ||
        _status.pendingAmbiguity == AmbiguityReason.scalePicker) {
      content = _devicePickerView(context);
    } else if (_status.error != null &&
        _status.phase == ConnectionPhase.idle &&
        !_showDevicePickerOverride) {
      content = _errorView(context);
    } else if (_status.phase == ConnectionPhase.scanning) {
      content = _scanningView(context);
    } else if (_status.phase == ConnectionPhase.connectingMachine ||
        _status.phase == ConnectionPhase.connectingScale) {
      content = _connectingView(context);
    } else if (_status.phase == ConnectionPhase.idle &&
        _status.foundMachines.isEmpty &&
        _status.foundScales.isEmpty) {
      content = _noDevicesFoundView(context);
    } else if (_status.phase == ConnectionPhase.idle &&
        (_status.foundMachines.isNotEmpty || _status.foundScales.isNotEmpty)) {
      content = _devicePickerView(context);
    } else {
      content = _scanningView(context);
    }

    if (blockingCondition == null && noticeCondition != null) {
      content = _withTransportNotice(content);
    }
    return Scaffold(body: content);
  }

  TransportCondition? _conditionWithDisposition(
    TransportConditionDisposition disposition,
  ) {
    for (final condition in _status.conditions) {
      if (resolveTransportCondition(_status, condition) == disposition) {
        return condition;
      }
    }
    return null;
  }

  String? get _operationErrorMessage {
    final error = _status.error;
    if (error == null ||
        _status.conditions.any(
          (condition) => condition.connectionError.kind == error.kind,
        )) {
      return null;
    }
    return error.message;
  }

  bool get _hasDevicesButNotPreferred {
    if (_discoveredMachines.isEmpty && _discoveredScales.isEmpty) return false;
    final preferredMachineId = widget.settingsController.preferredMachineId;
    if (preferredMachineId == null) return false;
    return !_discoveredMachines.any((m) => m.deviceId == preferredMachineId);
  }

  int get _totalDiscovered =>
      _discoveredMachines.length + _discoveredScales.length;

  String _scanningMessage() {
    if (_showTakingTooLong) {
      return 'Scanning is taking longer than usual. Check that the machine is '
          'powered on and in range.';
    }
    if (_totalDiscovered == 0) {
      return 'Scanning for your Decent machine and scale...';
    }
    final plural = _totalDiscovered == 1 ? '' : 's';
    return 'Found $_totalDiscovered device$plural. Still scanning...';
  }

  Widget _scanningView(BuildContext context) {
    final hasDevicesNotPreferred = _hasDevicesButNotPreferred;
    final deviceCount = _totalDiscovered;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: 'Scanning for devices',
                  child: SizedBox(width: 200, child: ShadProgress()),
                ),
                const SizedBox(height: 16),
                if (hasDevicesNotPreferred && _showTakingTooLong) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '$deviceCount device${deviceCount == 1 ? '' : 's'} found, but not your preferred one.',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      'Still scanning...',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ] else
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _scanningMessage(),
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
        ),
        ExcludeSemantics(
          excluding: !_showTakingTooLong,
          child: AnimatedOpacity(
            opacity: _showTakingTooLong ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 400),
            child: IgnorePointer(
              ignoring: !_showTakingTooLong,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: AccessibleButton(
                  label: hasDevicesNotPreferred
                      ? 'View found devices'
                      : 'This is taking a while...',
                  onTap: _showTakingTooLongSheet,
                  child: ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: _showTakingTooLongSheet,
                    child: Text(
                      hasDevicesNotPreferred
                          ? 'View found devices'
                          : 'This is taking a while...',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectingView(BuildContext context) {
    final label = _status.phase == ConnectionPhase.connectingMachine
        ? 'Connecting to your machine...'
        : 'Connecting to your scale...';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          Semantics(
            label: 'Connecting to device',
            child: SizedBox(width: 200, child: ShadProgress()),
          ),
          Semantics(
            liveRegion: true,
            child: Text(label, style: Theme.of(context).textTheme.titleMedium),
          ),
        ],
      ),
    );
  }

  Widget _devicePickerView(BuildContext context) {
    final isConnecting =
        _status.phase == ConnectionPhase.connectingMachine ||
        _status.phase == ConnectionPhase.connectingScale;

    final preferredMachineId = widget.settingsController.preferredMachineId;
    final preferredScaleId = widget.settingsController.preferredScaleId;

    if (_status.pendingAmbiguity == AmbiguityReason.machinePicker) {
      final preferredMachineNotFound =
          preferredMachineId != null &&
          _status.foundMachines.isNotEmpty &&
          !_status.foundMachines.any((m) => m.deviceId == preferredMachineId);
      return _singlePickerView(
        context: context,
        label: preferredMachineNotFound
            ? "Your preferred machine wasn't found, but we discovered these:"
            : 'Machines',
        devices: _status.foundMachines,
        selectedId: _selectedMachineId,
        onTapped: (id) => setState(() => _selectedMachineId = id),
        onConnect: () {
          final id = _selectedMachineId;
          if (id == null) return;
          final machine = _status.foundMachines.firstWhere(
            (m) => m.deviceId == id,
          );
          widget.connectionManager.selectMachine(machine);
        },
        isConnecting: isConnecting,
        canConnect: _selectedMachineId != null,
        errorMessage: _operationErrorMessage,
      );
    }

    if (_status.pendingAmbiguity == AmbiguityReason.scalePicker) {
      final preferredScaleNotFound =
          preferredScaleId != null &&
          _status.foundScales.isNotEmpty &&
          !_status.foundScales.any((s) => s.deviceId == preferredScaleId);
      return _singlePickerView(
        context: context,
        label: preferredScaleNotFound
            ? "Your preferred scale wasn't found, but we discovered these:"
            : 'Scales',
        devices: _status.foundScales,
        selectedId: _selectedScaleId,
        onTapped: (id) => setState(() => _selectedScaleId = id),
        onConnect: () {
          final id = _selectedScaleId;
          if (id == null) return;
          final scale = _status.foundScales.firstWhere((s) => s.deviceId == id);
          widget.connectionManager.selectScale(scale);
        },
        isConnecting: isConnecting,
        canConnect: _selectedScaleId != null,
        errorMessage: _operationErrorMessage,
      );
    }

    final preferredMachineNotFound =
        preferredMachineId != null &&
        _status.foundMachines.isNotEmpty &&
        !_status.foundMachines.any((m) => m.deviceId == preferredMachineId);

    final preferredScaleNotFound =
        preferredScaleId != null &&
        _status.foundScales.isNotEmpty &&
        !_status.foundScales.any((s) => s.deviceId == preferredScaleId);

    final machineHeader = preferredMachineNotFound
        ? "Your preferred machine wasn't found, but we discovered these:"
        : 'Machines';
    final scaleHeader = preferredScaleNotFound
        ? "Your preferred scale wasn't found, but we discovered these:"
        : 'Scales';

    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 460),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DeviceSelectionWidget(
                      deviceController: widget.deviceController,
                      deviceType: dev.DeviceType.machine,
                      showHeader: true,
                      headerText: machineHeader,
                      connectingDeviceId: isConnecting
                          ? (_status.foundMachines.isNotEmpty
                                ? _status.foundMachines.first.deviceId
                                : null)
                          : null,
                      errorMessage: _operationErrorMessage,
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
                  const SizedBox(width: 8),
                  Expanded(
                    child: DeviceSelectionWidget(
                      deviceController: widget.deviceController,
                      deviceType: dev.DeviceType.scale,
                      showHeader: true,
                      headerText: scaleHeader,
                      selectedDeviceId: null,
                      preferredDeviceId:
                          widget.settingsController.preferredScaleId,
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
                  AccessibleButton(
                    label: 'ReScan',
                    onTap: () => widget.connectionManager.scanAndConnect(),
                    child: ShadButton.outline(
                      size: ShadButtonSize.sm,
                      onPressed: () =>
                          widget.connectionManager.scanAndConnect(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: [
                          const Icon(LucideIcons.refreshCw, size: 14),
                          const Text('ReScan'),
                        ],
                      ),
                    ),
                  ),
                if (!isConnecting)
                  AccessibleButton(
                    label: widget.exitLabel,
                    onTap: _skipToDashboard,
                    child: ShadButton.secondary(
                      size: ShadButtonSize.sm,
                      onPressed: _skipToDashboard,
                      child: Text(widget.exitLabel),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _singlePickerView<T extends dev.Device>({
    required BuildContext context,
    required String label,
    required List<T> devices,
    required String? selectedId,
    required void Function(String id) onTapped,
    required VoidCallback onConnect,
    required bool isConnecting,
    required bool canConnect,
    String? errorMessage,
  }) {
    final theme = ShadTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Text(label, style: theme.textTheme.h3),
            if (errorMessage != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.destructive.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.destructive.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    Icon(
                      LucideIcons.triangleAlert,
                      size: 16,
                      color: theme.colorScheme.destructive,
                    ),
                    Expanded(
                      child: Text(
                        errorMessage,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.destructive,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ...devices.map((device) {
              final id = device.deviceId;
              final name = device.name;
              final isSelected = selectedId == id;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ShadCard(
                  width: double.infinity,
                  child: InkWell(
                    onTap: isConnecting ? null : () => onTapped(id),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name),
                                Text(id, style: theme.textTheme.muted),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Icon(
                              LucideIcons.checkCircle,
                              color: theme.colorScheme.primary,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                if (!isConnecting)
                  ShadButton.outline(
                    size: ShadButtonSize.sm,
                    onPressed: () => widget.connectionManager.scanAndConnect(),
                    child: const Row(
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
                  onPressed: isConnecting || !canConnect ? null : onConnect,
                  child: isConnecting
                      ? const Row(
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
                      : const Text('Connect'),
                ),
                if (!isConnecting)
                  ShadButton.secondary(
                    size: ShadButtonSize.sm,
                    onPressed: _skipToDashboard,
                    child: Text(widget.exitLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    final theme = ShadTheme.of(context);
    final hasFoundDevices =
        _status.foundMachines.isNotEmpty || _status.foundScales.isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          ExcludeSemantics(
            child: Icon(
              LucideIcons.triangleAlert,
              size: 48,
              color: theme.colorScheme.destructive,
            ),
          ),
          Text('Connection Error', style: theme.textTheme.h4),
          Text(
            _status.error?.message ?? 'An unknown error occurred.',
            style: theme.textTheme.muted,
            textAlign: TextAlign.center,
          ),
          AccessibleButton(
            label: 'Retry',
            onTap: () => widget.connectionManager.scanAndConnect(),
            child: ShadButton(
              onPressed: () => widget.connectionManager.scanAndConnect(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  const Icon(LucideIcons.refreshCw, size: 16),
                  const Text('Retry'),
                ],
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              if (hasFoundDevices)
                ShadButton.outline(
                  onPressed: () =>
                      setState(() => _showDevicePickerOverride = true),
                  child: const Text('View found devices'),
                ),
              ShadButton.secondary(
                onPressed: widget.onExit,
                child: Text(widget.exitLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _withTransportNotice(Widget content) {
    return Column(
      children: [
        Expanded(child: content),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ShadAlert(
              icon: const Icon(LucideIcons.bluetoothOff, size: 16),
              title: const Text('Bluetooth unavailable'),
              description: const Text(
                'Bluetooth is unavailable. USB devices remain available.',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _adapterErrorView(BuildContext context, ConnectionError error) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          ExcludeSemantics(
            child: Icon(
              LucideIcons.bluetoothOff,
              size: 48,
              color: theme.colorScheme.destructive,
            ),
          ),
          Text('Bluetooth Unavailable', style: theme.textTheme.h4),
          Text(
            error.message,
            style: theme.textTheme.muted,
            textAlign: TextAlign.center,
          ),
          AccessibleButton(
            label: 'Try Again',
            onTap: _retry,
            child: ShadButton(
              onPressed: _retry,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  const Icon(LucideIcons.refreshCw, size: 16),
                  const Text('Try Again'),
                ],
              ),
            ),
          ),
          AccessibleButton(
            label: 'Try Demo Mode',
            onTap: _tryDemoMode,
            child: ShadButton.outline(
              onPressed: _tryDemoMode,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  const Icon(LucideIcons.gamepad2, size: 16),
                  const Text('Try Demo Mode'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noDevicesFoundView(BuildContext context) {
    final report = widget.connectionManager.lastScanReport;
    if (report == null) {
      return Center(
        child: AccessibleButton(
          label: 'Scan Again',
          onTap: () => widget.connectionManager.scanAndConnect(),
          child: ShadButton(
            onPressed: () => widget.connectionManager.scanAndConnect(),
            child: const Text('Scan Again'),
          ),
        ),
      );
    }

    return Center(
      child: ScanResultsSummary(
        report: report,
        onScanAgain: () => widget.connectionManager.scanAndConnect(),
        onTryDemoMode: _tryDemoModeFromNoDevices,
        onTroubleshoot: () => showTroubleshootingWizard(
          context: context,
          adapterState: widget.scanStateGuardian.currentAdapterState,
        ),
        onExportLogs: _exportLogs,
        onContinueToDashboard: _skipToDashboard,
      ),
    );
  }

  void _stopScanAndShowDevices() {
    widget.deviceController.stopScan();
  }

  void _showTakingTooLongSheet() {
    final hasDevices = _totalDiscovered > 0;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasDevices)
              ListTile(
                leading: const Icon(LucideIcons.list),
                title: Text(
                  'View $_totalDiscovered found device${_totalDiscovered == 1 ? '' : 's'}',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _stopScanAndShowDevices();
                },
              ),
            ListTile(
              leading: const Icon(LucideIcons.refreshCw),
              title: const Text('Re-start scan'),
              onTap: () {
                Navigator.pop(context);
                widget.connectionManager.scanAndConnect();
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.wrench),
              title: const Text('Troubleshoot'),
              onTap: () {
                Navigator.pop(context);
                showTroubleshootingWizard(
                  context: context,
                  adapterState: widget.scanStateGuardian.currentAdapterState,
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.fileText),
              title: const Text('Export logs'),
              onTap: () {
                Navigator.pop(context);
                _exportLogs();
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.layoutDashboard),
              title: Text(
                widget.exitLabel == 'Dashboard'
                    ? 'Continue to Dashboard'
                    : widget.exitLabel,
              ),
              onTap: () {
                Navigator.pop(context);
                _skipToDashboard();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportLogs() async {
    try {
      final logFile = File('${await AppDirectories.logs}/log.txt');

      if (!await logFile.exists()) {
        if (mounted) {
          showShadDialog(
            context: context,
            builder: (context) => ShadDialog(
              title: const Text('No Logs Found'),
              description: const Text('Log file does not exist yet.'),
              actions: [
                AccessibleButton(
                  label: 'OK',
                  onTap: () => Navigator.of(context).pop(),
                  child: ShadButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
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
              title: const Text('Logs Exported'),
              description: Text(
                'Logs have been successfully exported to:\n$outputFile',
              ),
              actions: [
                AccessibleButton(
                  label: 'OK',
                  onTap: () => Navigator.of(context).pop(),
                  child: ShadButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
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
            title: const Text('Export Failed'),
            description: Text('Failed to export logs: $e'),
            actions: [
              AccessibleButton(
                label: 'OK',
                onTap: () => Navigator.of(context).pop(),
                child: ShadButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        );
      }
    }
  }
}
