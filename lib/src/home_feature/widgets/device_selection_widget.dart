import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/home_feature/widgets/device_connecting_indicator.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:shadcn_ui/shadcn_ui.dart';

class DeviceSelectionWidget extends StatefulWidget {
  final DeviceController deviceController;
  final dev.DeviceType deviceType;
  final Function(dev.Device) onDeviceTapped;
  final String? selectedDeviceId;
  final String? preferredDeviceId;
  final Function(String?)? onPreferredChanged;
  final bool showHeader;
  final String? headerText;
  final String? connectingDeviceId;
  final String? errorMessage;

  const DeviceSelectionWidget({
    super.key,
    required this.deviceController,
    required this.deviceType,
    required this.onDeviceTapped,
    this.selectedDeviceId,
    this.preferredDeviceId,
    this.onPreferredChanged,
    this.showHeader = false,
    this.headerText,
    this.connectingDeviceId,
    this.errorMessage,
  });

  @override
  State<DeviceSelectionWidget> createState() => _DeviceSelectionWidgetState();
}

class _DeviceSelectionWidgetState extends State<DeviceSelectionWidget> {
  late StreamSubscription<List<dev.Device>> _discoverySubscription;
  List<dev.Device> _discoveredDevices = [];

  @override
  void initState() {
    super.initState();

    _discoveredDevices = widget.deviceController.devices
        .where((device) => device.type == widget.deviceType)
        .toList();

    _discoverySubscription = widget.deviceController.deviceStream.listen((
      data,
    ) {
      if (mounted) {
        setState(() {
          _discoveredDevices = data
              .where((device) => device.type == widget.deviceType)
              .toList();
        });
      }
    });
  }

  @override
  void dispose() {
    _discoverySubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_discoveredDevices.isEmpty) {
      final label = switch (widget.deviceType) {
        dev.DeviceType.machine => 'machines',
        dev.DeviceType.scale => 'scales',
        dev.DeviceType.sensor => 'devices',
        dev.DeviceType.grinder => 'grinders',
      };
      return Padding(
        padding: const EdgeInsets.all(8.0),
        child: Center(
          child: Text(
            'No $label found.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    final isAnyConnecting = widget.connectingDeviceId != null;

    final listView = ListView.builder(
      shrinkWrap: true,
      itemCount: _discoveredDevices.length,
      itemBuilder: (context, index) {
        final device = _discoveredDevices[index];
        final isPreferred = widget.preferredDeviceId == device.deviceId;
        final isConnecting = widget.connectingDeviceId == device.deviceId;
        final isSelected = widget.selectedDeviceId == device.deviceId;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.0, horizontal: 2.0),
          child: ShadCard(
            padding: EdgeInsets.zero,
            border: isSelected
                ? ShadBorder.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                    dense: true,
                    visualDensity: VisualDensity(horizontal: -4, vertical: -4),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      device.name,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    subtitle: Text(
                      "ID: ${device.deviceId.length > 8 ? device.deviceId.substring(device.deviceId.length - 8) : device.deviceId}",
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    leading: isPreferred
                        ? Icon(
                            LucideIcons.check,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : SizedBox(width: 16),
                    trailing: DeviceConnectingIndicator(
                      isConnecting: isConnecting,
                    ),
                    enabled: !isAnyConnecting,
                    onTap: isAnyConnecting
                        ? null
                        : () => widget.onDeviceTapped(device),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (widget.showHeader) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(
            widget.headerText ?? "Select a machine from the list",
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (widget.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: ShadCard(
                padding: EdgeInsets.all(8),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        LucideIcons.info,
                        size: 14,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.errorMessage!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          listView,
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.errorMessage != null)
          Padding(
            padding: const EdgeInsets.all(4.0),
            child: ShadCard(
              padding: EdgeInsets.all(8),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      LucideIcons.info,
                      size: 14,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.errorMessage!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SizedBox(height: 260, width: 400, child: listView),
      ],
    );
  }
}
