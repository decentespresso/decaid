import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/settings/plugin_device_settings.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

typedef DeviceSettingsLauncher = Future<bool> Function(Uri uri);

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({
    super.key,
    required this.settingsController,
    required this.deviceController,
    this.settingsLauncher,
  });

  static const routeName = '/devices';

  final SettingsController settingsController;
  final DeviceController deviceController;
  final DeviceSettingsLauncher? settingsLauncher;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  late StreamSubscription<List<Device>> _deviceSubscription;
  final List<StreamSubscription<DeviceInformation?>>
  _deviceInformationSubscriptions = [];
  List<Device> _devices = [];

  @override
  void initState() {
    super.initState();
    _devices = widget.deviceController.devices;
    _syncDeviceInformationSubscriptions();
    _deviceSubscription = widget.deviceController.deviceStream.listen((
      devices,
    ) {
      if (mounted) {
        setState(() => _devices = devices);
        _syncDeviceInformationSubscriptions();
      }
    });
  }

  @override
  void dispose() {
    _deviceSubscription.cancel();
    for (final subscription in _deviceInformationSubscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  List<Device> get _machines =>
      _devices.where((d) => d.type == DeviceType.machine).toList();

  List<Device> get _scales =>
      _devices.where((d) => d.type == DeviceType.scale).toList();

  List<Device> get _sensors => _devices
      .where(
        (d) =>
            d.type == DeviceType.sensor &&
            d is DeviceSettingsCapable &&
            d.deviceSettings != null,
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListenableBuilder(
        listenable: widget.settingsController,
        builder: (context, _) {
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  _buildSection(
                    title: 'Auto-connect Machine',
                    icon: Icons.coffee_outlined,
                    devices: _machines,
                    selectedId: widget.settingsController.preferredMachineId,
                    emptyLabel: 'machines',
                    onSelected: (id) async {
                      await widget.settingsController.setPreferredMachineId(id);
                      if (mounted) _showSavedSnackbar();
                    },
                  ),
                  if (_sensors.isNotEmpty)
                    _buildSection(
                      title: 'Sensors',
                      icon: Icons.sensors_outlined,
                      devices: _sensors,
                      selectedId: null,
                      emptyLabel: 'sensors',
                      selectable: false,
                      onSelected: (_) async {},
                    ),
                  _buildSection(
                    title: 'Auto-connect Scale',
                    icon: Icons.scale_outlined,
                    devices: _scales,
                    selectedId: widget.settingsController.preferredScaleId,
                    emptyLabel: 'scales',
                    onSelected: (id) async {
                      await widget.settingsController.setPreferredScaleId(id);
                      if (mounted) _showSavedSnackbar();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Device> devices,
    required String? selectedId,
    required String emptyLabel,
    required Future<void> Function(String?) onSelected,
    bool selectable = true,
  }) {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (selectable)
            _buildDeviceRadio(
              name: 'None',
              subtitle: 'No auto-connect',
              isSelected: selectedId == null,
              onTap: () => onSelected(null),
            ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No $emptyLabel currently known. Connect to devices first, then return here to set a preference.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            )
          else
            ...devices.map(
              (device) => _buildDeviceRadio(
                name: device.name,
                subtitle: _deviceSubtitle(device),
                isSelected: selectable && selectedId == device.deviceId,
                onTap: selectable ? () => onSelected(device.deviceId) : null,
                showSelection: selectable,
                trailing: _settingsButton(device),
              ),
            ),
        ],
      ),
    );
  }

  void _syncDeviceInformationSubscriptions() {
    for (final subscription in _deviceInformationSubscriptions) {
      subscription.cancel();
    }
    _deviceInformationSubscriptions.clear();
    for (final device in _devices.whereType<DeviceInformationCapable>()) {
      _deviceInformationSubscriptions.add(
        device.deviceInformation.skip(1).listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  String _deviceSubtitle(Device device) {
    final lines = <String>[_truncatedId(device.deviceId)];
    if (device case DeviceInformationCapable capable) {
      final firmwareVersion = capable.currentDeviceInformation?.firmwareVersion;
      if (firmwareVersion != null) {
        lines.add('Firmware: $firmwareVersion');
      }
      final batteryLevel = capable.currentDeviceInformation?.batteryLevel;
      if (batteryLevel != null) {
        lines.add('Battery: $batteryLevel% (device-reported)');
      }
    }
    return lines.join(' · ');
  }

  Widget _buildDeviceRadio({
    required String name,
    required String subtitle,
    required bool isSelected,
    required VoidCallback? onTap,
    bool showSelection = true,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            if (showSelection)
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
              )
            else
              const Icon(Icons.sensors_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  Widget? _settingsButton(Device device) {
    if (device is! DeviceSettingsCapable || device.deviceSettings == null) {
      return null;
    }
    return IconButton(
      tooltip: 'Device settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => _openDeviceSettings(device),
    );
  }

  Future<void> _openDeviceSettings(Device device) async {
    if (!widget.deviceController.devices.any(
      (current) => identical(current, device),
    )) {
      _showSettingsError();
      return;
    }
    bool launched = false;
    try {
      final uri = pluginDeviceSettingsUriForDevice(
        device as DeviceSettingsCapable,
      );
      launched =
          await (widget.settingsLauncher?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.inAppBrowserView));
    } catch (_) {
      launched = false;
    }
    if (!mounted) return;
    if (!launched) _showSettingsError();
  }

  String _truncatedId(String id) {
    if (id.length > 8) {
      return 'ID: ...${id.substring(id.length - 8)}';
    }
    return 'ID: $id';
  }

  void _showSavedSnackbar() {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Preference saved. Takes effect on next app start.'),
          duration: Duration(seconds: 3),
        ),
      );
  }

  void _showSettingsError() {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Unable to open device settings.')),
      );
  }
}
