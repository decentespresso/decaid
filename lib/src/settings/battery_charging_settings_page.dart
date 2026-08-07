import 'package:flutter/material.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class BatteryChargingSettingsPage extends StatefulWidget {
  const BatteryChargingSettingsPage({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<BatteryChargingSettingsPage> createState() =>
      _BatteryChargingSettingsPageState();
}

class _BatteryChargingSettingsPageState
    extends State<BatteryChargingSettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Battery & Charging')),
      body: ListenableBuilder(
        listenable: widget.controller,
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
                  _buildChargingModeSection(),
                  _buildNightModeSection(),
                  _buildEmergencyFloorSection(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChargingModeSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Charging Mode',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Smart charging manages the battery level to extend its lifespan. '
            'Instead of always charging to 100%, it keeps the battery within a '
            'target range.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          DropdownButton<ChargingMode>(
            isExpanded: true,
            value: widget.controller.chargingMode,
            onChanged: (mode) {
              if (mode != null) {
                widget.controller.setChargingMode(mode);
              }
            },
            items: const [
              DropdownMenuItem(
                value: ChargingMode.disabled,
                child: Text('Always charge'),
              ),
              DropdownMenuItem(
                value: ChargingMode.longevity,
                child: Text('Maximize battery lifespan (45–55%)'),
              ),
              DropdownMenuItem(
                value: ChargingMode.balanced,
                child: Text('Balanced (40–80%)'),
              ),
              DropdownMenuItem(
                value: ChargingMode.highAvailability,
                child: Text('Always ready (80–95%)'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _chargingModeDescription(widget.controller.chargingMode),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNightModeSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShadSwitch(
            value: widget.controller.nightModeEnabled,
            onChanged: (v) {
              widget.controller.setNightModeEnabled(v);
            },
            label: const Text('Overnight charging'),
            sublabel: const Text(
              'Top up before bedtime, then pause charging overnight to reduce '
              'battery wear.',
            ),
          ),
          if (widget.controller.nightModeEnabled) ...[
            const SizedBox(height: 16),
            _buildTimePicker(
              label: 'Bedtime',
              minutesSinceMidnight: widget.controller.nightModeSleepTime,
              onChanged: (minutes) {
                widget.controller.setNightModeSleepTime(minutes);
              },
            ),
            const SizedBox(height: 8),
            _buildTimePicker(
              label: 'Wake-up time',
              minutesSinceMidnight: widget.controller.nightModeMorningTime,
              onChanged: (minutes) {
                widget.controller.setNightModeMorningTime(minutes);
              },
            ),
            const SizedBox(height: 12),
            Text(
              '2 hours before sleep: hover at 80%. '
              '30 minutes before sleep: charge to 95%. '
              'Sleep to morning: no charging.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            _buildNoChargeWarning(),
          ],
        ],
      ),
    );
  }

  Widget _buildEmergencyFloorSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Low battery protection',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'If the battery drops to 15% or lower, charging turns on '
            'automatically — whatever the settings above say.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildTimePicker({
    required String label,
    required int minutesSinceMidnight,
    required ValueChanged<int> onChanged,
  }) {
    final timeOfDay = TimeOfDay(
      hour: minutesSinceMidnight ~/ 60,
      minute: minutesSinceMidnight % 60,
    );

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(
        timeOfDay.format(context),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: timeOfDay,
        );
        if (picked != null) {
          onChanged(picked.hour * 60 + picked.minute);
        }
      },
    );
  }

  Widget _buildNoChargeWarning() {
    final sleepTime = widget.controller.nightModeSleepTime;
    final morningTime = widget.controller.nightModeMorningTime;

    final int noChargeWindow;
    if (sleepTime < morningTime) {
      noChargeWindow = morningTime - sleepTime;
    } else {
      noChargeWindow = (1440 - sleepTime) + morningTime;
    }

    if (noChargeWindow <= 600) {
      return const SizedBox.shrink();
    }

    final hours = noChargeWindow ~/ 60;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'The no-charge window is $hours hours. The tablet battery may '
                'drain significantly during this period.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _chargingModeDescription(ChargingMode mode) {
    switch (mode) {
      case ChargingMode.disabled:
        return 'The tablet will charge normally whenever connected to power. '
            'No battery management is applied.';
      case ChargingMode.longevity:
        return 'Best for battery lifespan. Keeps the battery between 45% and '
            '55%, minimizing wear from deep cycles.';
      case ChargingMode.balanced:
        return 'A good balance between battery health and availability. '
            'Charges up to 80% and stops until it drops to 40%.';
      case ChargingMode.highAvailability:
        return 'Keeps the battery topped up between 80% and 95%. Best when '
            'the tablet needs to be ready to unplug at any time.';
    }
  }
}
