import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/debug_feature/debug_item_details_view.dart';
import 'package:reaprime/src/debug_feature/grinder_debug_view.dart';
import 'package:reaprime/src/debug_feature/scale_debug_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart' hide Scale;

class DebugItemListView extends StatelessWidget {
  const DebugItemListView({
    super.key,
    required this.controller,
    required this.de1Controller,
  });

  static const routeName = '/debug';

  final DeviceController controller;
  final De1Controller de1Controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: controller.scanningStream,
      initialData: controller.isScanning,
      builder: (context, scanningSnapshot) {
        final isScanning = scanningSnapshot.data ?? false;

        return StreamBuilder<List<dev.Device>>(
          stream: controller.deviceStream,
          builder: (context, deviceSnapshot) {
            final devices = deviceSnapshot.data ?? [];
            final isEmpty = devices.isEmpty && !isScanning;

            return Scaffold(
              appBar: AppBar(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Debug Devices'),
                    if (devices.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ShadBadge(child: Text('${devices.length}')),
                    ],
                  ],
                ),
                actions: [
                  if (isScanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Scanning…'),
                        ],
                      ),
                    )
                  else
                    ShadButton.ghost(
                      leading: const Icon(LucideIcons.radar, size: 16),
                      child: const Text('Scan'),
                      onPressed: () => controller.scanForDevices(),
                    ),
                ],
              ),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isScanning) const ShadProgress(),
                  Expanded(
                    child: isEmpty
                        ? _buildEmptyState(context)
                        : _buildGroupedList(context, devices),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.radar,
              size: 48,
              color: theme.colorScheme.mutedForeground,
            ),
            const SizedBox(height: 16),
            Text('No devices discovered', style: theme.textTheme.p),
            const SizedBox(height: 8),
            Text(
              'Tap Scan to search for nearby devices',
              style: theme.textTheme.muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedList(BuildContext context, List<dev.Device> devices) {
    final machines = devices.whereType<De1Interface>().toList();
    final scales = devices.whereType<Scale>().toList();
    final grinders = devices.whereType<Grinder>().toList();
    final sensors = devices
        .where(
          (d) =>
              d.type != dev.DeviceType.machine &&
              d.type != dev.DeviceType.scale &&
              d.type != dev.DeviceType.grinder,
        )
        .toList();

    return ListView(
      children: [
        if (machines.isNotEmpty) ...[
          _buildSectionHeader(context, 'Machines'),
          ...machines.map((m) => _buildDeviceRow(context, m)),
        ],
        if (scales.isNotEmpty) ...[
          _buildSectionHeader(context, 'Scales'),
          ...scales.map((s) => _buildDeviceRow(context, s)),
        ],
        if (grinders.isNotEmpty) ...[
          _buildSectionHeader(context, 'Grinders'),
          ...grinders.map((g) => _buildDeviceRow(context, g)),
        ],
        if (sensors.isNotEmpty) ...[
          _buildSectionHeader(context, 'Sensors'),
          ...sensors.map(
            (s) => _buildDeviceRow(context, s, showConnect: false),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.small.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.mutedForeground,
        ),
      ),
    );
  }

  Widget _buildDeviceRow(
    BuildContext context,
    dev.Device device, {
    bool showConnect = true,
  }) {
    final theme = ShadTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              StreamBuilder<dev.ConnectionState>(
                stream: device.connectionState,
                builder: (context, snapshot) {
                  final cs = snapshot.data;
                  IconData icon;
                  Color? color;
                  if (cs == dev.ConnectionState.connected) {
                    icon = LucideIcons.check;
                    color = theme.colorScheme.primary;
                  } else if (cs == dev.ConnectionState.disconnected) {
                    icon = LucideIcons.x;
                    color = theme.colorScheme.mutedForeground;
                  } else {
                    icon = LucideIcons.scanEye;
                    color = theme.colorScheme.mutedForeground;
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(icon, size: 18, color: color),
                  );
                },
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.small,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      device.deviceId,
                      style: theme.textTheme.muted.copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (showConnect)
                ShadButton(
                  size: ShadButtonSize.sm,
                  child: const Text('Connect'),
                  onPressed: () => _navigateToDebugView(context, device),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigateToDebugView(BuildContext context, dev.Device device) {
    if (device is De1Interface) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              De1DebugView(machine: device, de1Controller: de1Controller),
        ),
      );
    } else if (device is Scale) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ScaleDebugView(scale: device)),
      );
    } else if (device is Grinder) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GrinderDebugView(grinder: device)),
      );
    }
  }
}
