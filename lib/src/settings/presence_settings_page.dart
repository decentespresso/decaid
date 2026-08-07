import 'package:flutter/material.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PresenceSettingsPage extends StatefulWidget {
  const PresenceSettingsPage({
    super.key,
    required this.controller,
    this.keepAwakeUntil,
  });

  final SettingsController controller;
  final DateTime? keepAwakeUntil;

  @override
  State<PresenceSettingsPage> createState() => _PresenceSettingsPageState();
}

class _PresenceSettingsPageState extends State<PresenceSettingsPage> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  late final TextEditingController _sleepTimeoutTextController;
  late final FocusNode _sleepTimeoutFocusNode;

  @override
  void initState() {
    super.initState();

    _sleepTimeoutTextController = TextEditingController(
      text: widget.controller.sleepTimeoutMinutes.toString(),
    );
    _sleepTimeoutFocusNode = FocusNode();

    widget.controller.addListener(_handleSettingsChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleSettingsChanged);
    _sleepTimeoutTextController.dispose();
    _sleepTimeoutFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PresenceSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleSettingsChanged);
      widget.controller.addListener(_handleSettingsChanged);
      _syncSleepTimeoutText();
    }
  }

  void _handleSettingsChanged() {
    if (!_sleepTimeoutFocusNode.hasFocus) {
      _syncSleepTimeoutText();
    }
  }

  void _syncSleepTimeoutText() {
    final value = widget.controller.sleepTimeoutMinutes.toString();

    if (_sleepTimeoutTextController.text == value) return;

    _sleepTimeoutTextController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  Future<void> _commitSleepTimeout() async {
    final parsed = int.tryParse(_sleepTimeoutTextController.text.trim());

    if (parsed == null) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a number of minutes')),
      );
      return;
    }

    await widget.controller.setSleepTimeoutMinutes(parsed);

    if (!mounted) return;

    _syncSleepTimeoutText();
  }

  List<WakeSchedule> _parseSchedules() {
    final json = widget.controller.wakeSchedules;
    if (json.isEmpty || json == '[]') return [];
    try {
      return WakeSchedule.deserializeList(json);
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveSchedules(List<WakeSchedule> schedules) async {
    await widget.controller.setWakeSchedules(
      WakeSchedule.serializeList(schedules),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sleep & Wake')),
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
                  _buildUserPresenceSection(),
                  if (widget.controller.userPresenceEnabled) ...[
                    _buildSleepTimeoutSection(),
                    _buildWakeSchedulesSection(),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildUserPresenceSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShadSwitch(
            value: widget.controller.userPresenceEnabled,
            onChanged: (v) {
              widget.controller.setUserPresenceEnabled(v);
            },
            label: const Text('Auto sleep & wake'),
            sublabel: const Text(
              'Let the machine sleep when idle and wake on a schedule.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSleepTimeoutSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sleep',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Put the machine to sleep after a period of inactivity (0 = disabled). '
            'The timer resets whenever the machine is used.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 80,
                child: TextFormField(
                  controller: _sleepTimeoutTextController,
                  focusNode: _sleepTimeoutFocusNode,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: false,
                  ),
                  decoration: const InputDecoration(
                    suffixText: 'min',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  onFieldSubmitted: (_) {
                    _commitSleepTimeout();
                  },
                  onTapOutside: (_) {
                    _sleepTimeoutFocusNode.unfocus();
                    _commitSleepTimeout();
                  },
                ),
              ),
              const SizedBox(width: 8),
              ShadButton.outline(
                onPressed: () {
                  _commitSleepTimeout();
                },
                child: const Text('Set'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWakeSchedulesSection() {
    final schedules = _parseSchedules();

    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Wake schedule',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Schedule times for the machine to automatically wake up. '
            'Useful for having the machine ready when you start your day.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          if (widget.keepAwakeUntil != null &&
              widget.keepAwakeUntil!.isAfter(DateTime.now())) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.coffee,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Keeping awake until ${TimeOfDay.fromDateTime(widget.keepAwakeUntil!).format(context)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (schedules.isNotEmpty) ...[
            const SizedBox(height: 16),
            ...schedules.map(
              (schedule) => _buildScheduleRow(schedule, schedules),
            ),
          ],
          const SizedBox(height: 16),
          ShadButton.outline(
            onPressed: () => _addSchedule(schedules),
            child: const Text('Add Schedule'),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleRow(
    WakeSchedule schedule,
    List<WakeSchedule> schedules,
  ) {
    final timeOfDay = TimeOfDay(hour: schedule.hour, minute: schedule.minute);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _editScheduleTime(schedule, schedules),
                child: Text(
                  timeOfDay.format(context),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Spacer(),
              ShadSwitch(
                value: schedule.enabled,
                onChanged: (v) {
                  final updated = schedules.map((s) {
                    if (s.id == schedule.id) return s.copyWith(enabled: v);
                    return s;
                  }).toList();
                  _saveSchedules(updated);
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () {
                  final updated = schedules
                      .where((s) => s.id != schedule.id)
                      .toList();
                  _saveSchedules(updated);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (schedule.daysOfWeek.isEmpty)
                Chip(
                  label: Text(
                    'Every day',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  visualDensity: VisualDensity.compact,
                )
              else
                for (int day = 1; day <= 7; day++)
                  FilterChip(
                    label: Text(
                      _dayLabels[day - 1],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    selected: schedule.daysOfWeek.contains(day),
                    visualDensity: VisualDensity.compact,
                    onSelected: (selected) {
                      _toggleDay(schedule, schedules, day, selected);
                    },
                  ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Text(
                  'Keep awake for',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: schedule.keepAwakeFor?.toString() ?? '',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: '0',
                      suffixText: 'min',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (value) {
                      final minutes = int.tryParse(value);
                      if (minutes != null && minutes > 720) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Maximum is 720 minutes (12 hours)'),
                          ),
                        );
                        return;
                      }
                      final updated = schedules.map((s) {
                        if (s.id == schedule.id) {
                          if (minutes == null || minutes <= 0) {
                            return s.copyWith(clearKeepAwakeFor: true);
                          }
                          return s.copyWith(keepAwakeFor: minutes);
                        }
                        return s;
                      }).toList();
                      _saveSchedules(updated);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              'How long to keep the machine on after waking up, '
              'even if nobody uses it. After this time, the '
              'regular timeout decides when it goes to sleep.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (schedule.daysOfWeek.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: GestureDetector(
                onTap: () {
                  final updated = schedules.map((s) {
                    if (s.id == schedule.id) {
                      return s.copyWith(daysOfWeek: {1, 2, 3, 4, 5, 6, 7});
                    }
                    return s;
                  }).toList();
                  _saveSchedules(updated);
                },
                child: Text(
                  'Tap to select specific days',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          const Divider(),
        ],
      ),
    );
  }

  Future<void> _addSchedule(List<WakeSchedule> schedules) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 6, minute: 0),
    );
    if (picked == null) return;

    final newSchedule = WakeSchedule(
      id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
      hour: picked.hour,
      minute: picked.minute,
      daysOfWeek: const {},
      enabled: true,
    );

    final updated = [...schedules, newSchedule];
    await _saveSchedules(updated);
  }

  Future<void> _editScheduleTime(
    WakeSchedule schedule,
    List<WakeSchedule> schedules,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: schedule.hour, minute: schedule.minute),
    );
    if (picked == null) return;

    final updated = schedules.map((s) {
      if (s.id == schedule.id) {
        return s.copyWith(hour: picked.hour, minute: picked.minute);
      }
      return s;
    }).toList();
    await _saveSchedules(updated);
  }

  void _toggleDay(
    WakeSchedule schedule,
    List<WakeSchedule> schedules,
    int day,
    bool selected,
  ) {
    final newDays = Set<int>.from(schedule.daysOfWeek);
    if (selected) {
      newDays.add(day);
    } else {
      newDays.remove(day);
    }

    final effectiveDays = newDays.length == 7 ? <int>{} : newDays;

    final updated = schedules.map((s) {
      if (s.id == schedule.id) {
        return s.copyWith(daysOfWeek: effectiveDays);
      }
      return s;
    }).toList();
    _saveSchedules(updated);
  }
}
