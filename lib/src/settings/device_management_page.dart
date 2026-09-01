import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({
    super.key,
    required this.settingsController,
    required this.deviceController,
  });

  static const routeName = '/devices';

  final SettingsController settingsController;
  final DeviceController deviceController;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  late StreamSubscription<List<Device>> _deviceSubscription;
  List<Device> _devices = [];

  @override
  void initState() {
    super.initState();
    _devices = widget.deviceController.devices;
    _deviceSubscription = widget.deviceController.deviceStream.listen((
      devices,
    ) {
      if (mounted) {
        setState(() => _devices = devices);
      }
    });
  }

  @override
  void dispose() {
    _deviceSubscription.cancel();
    super.dispose();
  }

  List<Device> get _machines =>
      _devices.where((d) => d.type == DeviceType.machine).toList();

  List<Device> get _scales =>
      _devices.where((d) => d.type == DeviceType.scale).toList();

  List<Device> get _grinders =>
      _devices.where((d) => d.type == DeviceType.grinder).toList();

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
                  _buildSection(
                    title: 'Auto-connect Grinder',
                    icon: Icons.blender_outlined,
                    devices: _grinders,
                    selectedId: widget.settingsController.preferredGrinderId,
                    emptyLabel: 'grinders',
                    onSelected: (id) async {
                      await widget.settingsController.setPreferredGrinderId(id);
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
                subtitle: _truncatedId(device.deviceId),
                isSelected: selectedId == device.deviceId,
                onTap: () => onSelected(device.deviceId),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceRadio({
    required String name,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
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
            ),
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
          ],
        ),
      ),
    );
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
}
