import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/settings/common.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/debug_feature/debug_item_list_view.dart';
import 'package:reaprime/src/services/foreground_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'dart:io';

import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/gateway_mode_info_dialog.dart';
import 'package:reaprime/src/skin_feature/simulated_webview_device.dart';

class AdvancedPage extends StatelessWidget {
  const AdvancedPage({super.key, required this.controller});

  static const routeName = '/advanced';

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Advanced')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return ListView(
            children: [
              // Log Level
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('Log Level')),
                    DropdownButton<String>(
                      value: controller.logLevel,
                      onChanged: controller.updateLogLevel,
                      items: const [
                        DropdownMenuItem(
                          value: 'WARNING',
                          child: Text('Warning'),
                        ),
                        DropdownMenuItem(value: 'INFO', child: Text('Info')),
                        DropdownMenuItem(value: 'FINE', child: Text('Fine')),
                        DropdownMenuItem(
                          value: 'FINEST',
                          child: Text('Finest'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SettingsDivider(),

              SettingsTile(
                icon: Icons.settings_remote_outlined,
                label: 'Gateway Mode',
                trailing: Text(_gatewayModeLabel(controller.gatewayMode)),
                onTap: () => _showGatewayModePicker(context),
              ),
              const SettingsDivider(),

              // Experimental Features
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Experimental Features',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: ShadSwitch(
                  value: controller.isFeatureFlagEnabled(
                    FeatureFlag.stepExitArbiter,
                  ),
                  onChanged: (v) async {
                    await controller.setFeatureFlag(
                      FeatureFlag.stepExitArbiter,
                      v,
                    );
                  },
                  label: const Text('Smart Step Advance'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'When a profile step has both a weight and firmware exit condition, '
                  'defer the weight-based advance to avoid racing the DE1 and skipping '
                  'a step. Disable if you experience unexpected step behavior.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SettingsDivider(),
              if (Platform.isIOS || Platform.isMacOS || Platform.isWindows) ...{
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: ShadSwitch(
                    value: controller.isFeatureFlagEnabled(
                      .largeBleMtuNonAndroid,
                    ),
                    onChanged: (v) async {
                      await controller.setFeatureFlag(
                        FeatureFlag.largeBleMtuNonAndroid,
                        v,
                      );
                    },
                    label: const Text('Use MTU value of 517'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Will try to negotiate a larger MTU value '
                    'for Bluetooth connections. ',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SettingsDivider(),
              },

              // Simulated devices
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Simulated Devices',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final type in SimulatedDevicesTypes.values)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: ShadSwitch(
                    value: controller.simulatedDevices.contains(type),
                    onChanged: (v) async {
                      final current = Set<SimulatedDevicesTypes>.from(
                        controller.simulatedDevices,
                      );
                      if (v) {
                        current.add(type);
                      } else {
                        current.remove(type);
                      }
                      await controller.setSimulatedDevices(current);
                    },
                    label: Text(
                      type.name[0].toUpperCase() + type.name.substring(1),
                    ),
                  ),
                ),
              if (Platform.isMacOS ||
                  Platform.isWindows ||
                  Platform.isLinux) ...[
                const SettingsDivider(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: ShadSwitch(
                    value: controller.enableSimulatedWebViews,
                    onChanged: (v) async {
                      await controller.setEnableSimulatedWebViews(v);
                      // Disabling returns to the native WebView so the window
                      // snaps back to its normal size and no device shims linger.
                      if (!v) {
                        await setSimulatedWebViewDevice(null);
                      }
                    },
                    label: const Text('Simulated WebViews'),
                  ),
                ),
                if (controller.enableSimulatedWebViews)
                  ValueListenableBuilder<SimulatedWebViewDevice?>(
                    valueListenable: simulatedWebViewDevice,
                    builder: (context, selected, _) {
                      return SettingsTile(
                        icon: Icons.devices_outlined,
                        label: 'Simulated Device',
                        trailing: Text(selected?.name ?? 'Native WebView'),
                        onTap: () =>
                            _showSimulatedWebViewPicker(context, selected),
                      );
                    },
                  ),
              ],
              const SettingsDivider(),

              // Debug view
              ListTile(
                leading: const Icon(LucideIcons.bug),
                title: const Text('Debug view'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () =>
                    Navigator.pushNamed(context, DebugItemListView.routeName),
              ),
              const SettingsDivider(),

              // Exit
              if (!BuildInfo.appStore)
                ListTile(
                  leading: Icon(
                    LucideIcons.logOut,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Exit Decaid',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () async {
                    if (Platform.isWindows ||
                        Platform.isMacOS ||
                        Platform.isLinux) {
                      await ServicesBinding.instance.exitApplication(
                        AppExitType.cancelable,
                      );
                      return;
                    }
                    if (Platform.isAndroid) {
                      await ForegroundTaskService.stop();
                    }
                    exit(0);
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  void _showSimulatedWebViewPicker(
    BuildContext context,
    SimulatedWebViewDevice? selected,
  ) {
    showShadDialog(
      context: context,
      builder: (dialogContext) {
        return ShadDialog(
          title: const Text('Simulated Device'),
          description: const Text(
            'Resize the window and spoof viewport/touch APIs to preview skins '
            'as they appear on Decent tablets.',
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('Native WebView'),
                  subtitle: Text(
                    'Use this machine\'s real WebView, no spoofing.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: selected == null ? const Icon(Icons.check) : null,
                  onTap: () {
                    setSimulatedWebViewDevice(null);
                    Navigator.of(dialogContext).pop();
                  },
                ),
                ...simulatedWebViewDevices.map((device) {
                  return ListTile(
                    title: Text(device.name),
                    subtitle: Text(
                      '${device.viewportSize.width.toInt()}'
                      '×${device.viewportSize.height.toInt()} @ '
                      '${device.devicePixelRatio.toStringAsFixed(2)}x',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: selected?.id == device.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () {
                      setSimulatedWebViewDevice(device);
                      Navigator.of(dialogContext).pop();
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _gatewayModeLabel(GatewayMode mode) {
    switch (mode) {
      case GatewayMode.full:
        return 'Full';
      case GatewayMode.tracking:
        return 'Tracking';
      case GatewayMode.disabled:
        return 'Disabled';
    }
  }

  void _showGatewayModePicker(BuildContext context) {
    showShadDialog(
      context: context,
      builder: (dialogContext) {
        return ShadDialog(
          title: const Text('Gateway Mode'),
          description: const Text(
            'Control how external skins interact with the machine',
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                showGatewayModeInfoDialog(context);
              },
              icon: const Icon(Icons.info_outline, size: 16),
              label: const Text('Learn more'),
            ),
          ],
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...const [
                  GatewayMode.tracking,
                  GatewayMode.full,
                  GatewayMode.disabled,
                ].map((mode) {
                  String subtitle;
                  switch (mode) {
                    case GatewayMode.tracking:
                      subtitle =
                          'External skins control the machine. This app adds '
                          'weight tracking and stops the shot at your target. '
                          '(Used by most skins.)';
                    case GatewayMode.full:
                      subtitle =
                          'External skins fully control the machine, including '
                          'stopping the shot. This app only displays status.';
                    case GatewayMode.disabled:
                      subtitle =
                          'This app controls the machine directly. External '
                          'skins can\'t. (Legacy.)';
                  }
                  return ListTile(
                    title: Text(
                      mode.name[0].toUpperCase() + mode.name.substring(1),
                    ),
                    subtitle: Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: controller.gatewayMode == mode
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () {
                      controller.updateGatewayMode(mode);
                      Navigator.of(dialogContext).pop();
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}
