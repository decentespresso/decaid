import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/controllers/charging_logic.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.de1Controller,
    required this.scaleController,
    required this.webUIService,
    this.batteryController,
    this.onQrTap,
    this.readOnly =
        const bool.fromEnvironment('PERSONAL_BUILD') &&
        const bool.fromEnvironment('PERSONAL_READ_ONLY'),
  });

  final De1Controller de1Controller;
  final ScaleController scaleController;
  final BatteryController? batteryController;
  final WebUIService webUIService;
  final VoidCallback? onQrTap;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.card,
        border: Border(bottom: BorderSide(color: colorScheme.border, width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  spacing: 16,
                  children: [
                    _StatusChip(
                      icon: LucideIcons.wrench,
                      label:
                          'LOCAL FORK · ${BuildInfo.branch}@${BuildInfo.commitShort}'
                          '${readOnly ? ' · READ ONLY' : ''}',
                    ),
                    _MachineStatus(de1Controller: de1Controller),
                    _ScaleStatus(scaleController: scaleController),
                    if (batteryController != null)
                      _BatteryStatus(batteryController: batteryController!),
                    _WaterLevel(de1Controller: de1Controller),
                  ],
                ),
              ),
            ),
            _QrButton(webUIService: webUIService, onTap: onQrTap),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Icon(
            icon,
            size: 14,
            color: color ?? theme.colorScheme.mutedForeground,
          ),
          Text(
            label,
            style: theme.textTheme.small.copyWith(
              color: color ?? theme.colorScheme.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _MachineStatus extends StatelessWidget {
  const _MachineStatus({required this.de1Controller});

  final De1Controller de1Controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<De1Interface?>(
      stream: de1Controller.de1,
      builder: (context, de1Snap) {
        final de1 = de1Snap.data;
        if (de1 == null) {
          return _StatusChip(
            icon: LucideIcons.coffee,
            label: 'No machine',
            color: ShadTheme.of(context).colorScheme.mutedForeground,
          );
        }

        return StreamBuilder<MachineSnapshot>(
          stream: de1.currentSnapshot,
          builder: (context, snapshot) {
            final state = snapshot.data?.state.state;
            final stateLabel = state != null
                ? _machineStateLabel(state)
                : 'connecting';
            final color = _machineStateColor(context, state);

            return _StatusChip(
              icon: LucideIcons.coffee,
              label: '${de1.name} · $stateLabel',
              color: color,
            );
          },
        );
      },
    );
  }

  static String _machineStateLabel(MachineState state) {
    return switch (state) {
      MachineState.idle || MachineState.schedIdle => 'idle',
      MachineState.heating || MachineState.preheating => 'heating',
      MachineState.sleeping => 'sleep',
      MachineState.espresso => 'espresso',
      MachineState.hotWater => 'hot water',
      MachineState.flush => 'flush',
      MachineState.steam => 'steam',
      MachineState.steamRinse => 'steam rinse',
      MachineState.needsWater => 'needs water',
      MachineState.error => 'error',
      _ => state.name,
    };
  }

  static Color _machineStateColor(BuildContext context, MachineState? state) {
    if (state == null) {
      return ShadTheme.of(context).colorScheme.mutedForeground;
    }
    return switch (state) {
      MachineState.idle || MachineState.schedIdle => Colors.green,
      MachineState.heating ||
      MachineState.preheating ||
      MachineState.booting ||
      MachineState.busy => Colors.orange,
      MachineState.sleeping => ShadTheme.of(
        context,
      ).colorScheme.mutedForeground,
      MachineState.needsWater => Colors.orange,
      MachineState.error => Colors.red,
      _ => Colors.blue,
    };
  }
}

class _ScaleStatus extends StatelessWidget {
  const _ScaleStatus({required this.scaleController});

  final ScaleController scaleController;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<device.ConnectionState>(
      stream: scaleController.connectionState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final connected = state == device.ConnectionState.connected;

        String label;
        Color color;
        if (connected) {
          try {
            label = scaleController.connectedScale().name;
            color = Colors.green;
          } catch (_) {
            label = 'Connected';
            color = Colors.green;
          }
        } else if (state == device.ConnectionState.connecting) {
          label = 'Connecting';
          color = Colors.orange;
        } else {
          label = 'No scale';
          color = ShadTheme.of(context).colorScheme.mutedForeground;
        }

        return _StatusChip(icon: LucideIcons.scale, label: label, color: color);
      },
    );
  }
}

class _BatteryStatus extends StatelessWidget {
  const _BatteryStatus({required this.batteryController});

  final BatteryController batteryController;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChargingState>(
      stream: batteryController.chargingState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) return const SizedBox.shrink();

        final percent = state.batteryPercent;
        final charging = state.usbChargerOn;
        final icon = charging
            ? LucideIcons.batteryCharging
            : percent > 75
            ? LucideIcons.batteryFull
            : percent > 25
            ? LucideIcons.batteryMedium
            : LucideIcons.batteryLow;
        final color = percent <= 15
            ? Colors.red
            : percent <= 25
            ? Colors.orange
            : null;

        return _StatusChip(icon: icon, label: '$percent%', color: color);
      },
    );
  }
}

class _WaterLevel extends StatelessWidget {
  const _WaterLevel({required this.de1Controller});

  final De1Controller de1Controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<De1Interface?>(
      stream: de1Controller.de1,
      builder: (context, de1Snap) {
        final de1 = de1Snap.data;
        if (de1 == null) return const SizedBox.shrink();

        return StreamBuilder<De1WaterLevels>(
          stream: de1.waterLevels,
          builder: (context, snapshot) {
            final levels = snapshot.data;
            if (levels == null) return const SizedBox.shrink();

            final low = levels.currentLevel <= levels.refillLevel;

            return _StatusChip(
              icon: LucideIcons.glassWaterDir,
              label: '${levels.currentLevel.toInt()}mm',
              color: low ? Colors.orange : null,
            );
          },
        );
      },
    );
  }
}

class _QrButton extends StatelessWidget {
  const _QrButton({required this.webUIService, this.onTap});

  final WebUIService webUIService;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Show QR code for WebUI',
      child: ExcludeSemantics(
        child: ShadIconButton.ghost(
          icon: const Icon(LucideIcons.qrCode, size: 18),
          onPressed: onTap ?? () => _showQrDialog(context),
        ),
      ),
    );
  }

  void _showQrDialog(BuildContext context) {
    final deviceIp = webUIService.deviceIp();
    final url =
        'http://$deviceIp:3000/?_=${DateTime.now().millisecondsSinceEpoch}';

    showShadDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Scan to connect'),
        description: Text(url),
        actions: [
          ShadButton.outline(
            child: const Text('Close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
        child: Center(
          child: SizedBox(
            height: 220,
            child: PrettyQrView.data(
              data: url,
              decoration: PrettyQrDecoration(
                quietZone: PrettyQrQuietZone.standard,
                shape: PrettyQrSquaresSymbol(
                  unifiedFinderPattern: true,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@Preview(name: 'Status Bar', group: 'Launcher')
Widget statusBarPreview() {
  return MaterialApp(home: Scaffold(body: _StatusBarPreviewStatic()));
}

class _StatusBarPreviewStatic extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              spacing: 16,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(LucideIcons.coffee, size: 14, color: Colors.green),
                    Text(
                      'DE1 · idle',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(LucideIcons.scale, size: 14, color: Colors.green),
                    Text(
                      'Lunar',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(LucideIcons.batteryMedium, size: 14),
                    Text('73%', style: theme.textTheme.bodySmall),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Icon(LucideIcons.droplets, size: 14),
                    Text('60%', style: theme.textTheme.bodySmall),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.qrCode, size: 18),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}
