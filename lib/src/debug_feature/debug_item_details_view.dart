import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

String debugViewTitle(De1Interface machine) =>
    machine is BengleInterface ? 'Bengle Details' : 'DE1 Details';

class De1DebugView extends StatefulWidget {
  const De1DebugView({super.key, required this.machine});

  static const routeName = '/debug_details';

  final De1Interface machine;

  @override
  State<De1DebugView> createState() => _De1DebugViewState();
}

class _De1DebugViewState extends State<De1DebugView> {
  var _lastDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    widget.machine.onConnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(debugViewTitle(widget.machine)),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [_buildStateDropdown(context)],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900;
          if (isWide) {
            return _buildWideLayout(theme);
          }
          return _buildNarrowLayout(theme);
        },
      ),
    );
  }

  Widget _buildStateDropdown(BuildContext context) {
    return ShadSelect<MachineState>(
      placeholder: const Text('Set State'),
      initialValue: null,
      selectedOptionBuilder: (context, state) => Text(state.name),
      onChanged: (state) {
        if (state != null) {
          widget.machine.requestState(state);
        }
      },
      options: MachineState.values
          .map((s) => ShadOption<MachineState>(value: s, child: Text(s.name)))
          .toList(),
    );
  }

  Widget _buildWideLayout(ShadThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildShotSnapshotCard(theme)),
                const SizedBox(width: 12),
                Expanded(child: _buildShotSettingsCard(theme)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildWaterLevelsCard(theme)),
                const SizedBox(width: 12),
                Expanded(child: _buildMachineInfoCard(theme)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrowLayout(ShadThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildShotSnapshotCard(theme),
        const SizedBox(height: 12),
        _buildShotSettingsCard(theme),
        const SizedBox(height: 12),
        _buildWaterLevelsCard(theme),
        const SizedBox(height: 12),
        _buildMachineInfoCard(theme),
      ],
    );
  }

  Widget _buildShotSnapshotCard(ShadThemeData theme) {
    return ShadCard(
      title: const Text('Shot Snapshot'),
      child: StreamBuilder<MachineSnapshot>(
        stream: widget.machine.currentSnapshot,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.active) {
            final diff =
                snapshot.data?.timestamp.difference(_lastDate) ?? Duration.zero;
            _lastDate = snapshot.data?.timestamp ?? DateTime.now();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: _buildMachineStateRows(snapshot, diff),
            );
          } else if (snapshot.connectionState == ConnectionState.waiting) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('Connecting…', style: theme.textTheme.muted),
              ],
            );
          }
          return Text('Waiting for data', style: theme.textTheme.muted);
        },
      ),
    );
  }

  List<Widget> _buildMachineStateRows(
    AsyncSnapshot<MachineSnapshot> snapshot,
    Duration diff,
  ) {
    final data = snapshot.data;
    return [
      _dataRow('State', '${data?.state.state} · ${data?.state.substate}'),
      _dataRow('Steam temp', '${data?.steamTemperature.toStringAsFixed(2)}°'),
      _dataRow('Group temp', '${data?.groupTemperature.toStringAsFixed(2)}°'),
      _dataRow('Flow', data?.flow.toStringAsFixed(2) ?? '—'),
      _dataRow('Pressure', data?.pressure.toStringAsFixed(2) ?? '—'),
      _dataRow(
        'Target mix',
        '${data?.targetMixTemperature.toStringAsFixed(2)}°',
      ),
      _dataRow(
        'Target head',
        '${data?.targetGroupTemperature.toStringAsFixed(2)}°',
      ),
      _dataRow('Target press.', data?.targetPressure.toStringAsFixed(2) ?? '—'),
      _dataRow('Target flow', data?.flow.toStringAsFixed(2) ?? '—'),
      _dataRow('Update freq', '${diff.inMilliseconds}ms'),
    ];
  }

  Widget _dataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: ShadTheme.of(context).textTheme.muted),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildShotSettingsCard(ShadThemeData theme) {
    return ShadCard(
      title: const Text('Shot Settings'),
      child: StreamBuilder<De1ShotSettings>(
        stream: widget.machine.shotSettings,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.active) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _dataRow(
                  'Steam setting',
                  '0x${snapshot.data!.steamSetting.toRadixString(16).padLeft(2, '0')}',
                ),
                _dataRow(
                  'Target group',
                  '${snapshot.data!.groupTemp.toStringAsFixed(1)}°',
                ),
              ],
            );
          }
          return Text('Waiting for data', style: theme.textTheme.muted);
        },
      ),
    );
  }

  Widget _buildWaterLevelsCard(ShadThemeData theme) {
    return ShadCard(
      title: const Text('Water Levels'),
      child: StreamBuilder<De1WaterLevels>(
        stream: widget.machine.waterLevels,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.active) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _dataRow('Water level', '${snapshot.data!.currentLevel}'),
                _dataRow('Threshold', '${snapshot.data!.refillLevel}'),
              ],
            );
          }
          return Text('Waiting for data', style: theme.textTheme.muted);
        },
      ),
    );
  }

  Widget _buildMachineInfoCard(ShadThemeData theme) {
    return ShadCard(
      title: const Text('Machine Info'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadButton.outline(
            size: ShadButtonSize.sm,
            child: const Text('Firmware Update'),
            onPressed: () => _startFirmwareUpdate(),
          ),
          const SizedBox(height: 16),
          _serialComms(),
        ],
      ),
    );
  }

  Future<void> _startFirmwareUpdate() async {
    final result = await FilePicker.pickFiles();
    if (result == null) return;

    final file = File(result.files.single.path!);
    final data = await file.readAsBytes();
    if (!mounted) return;

    final progressNotifier = ValueNotifier<double>(0.0);
    final stopwatch = Stopwatch()..start();
    var cancelled = false;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              cancelled = true;
              widget.machine.cancelFirmwareUpload();
            }
          },
          child: ValueListenableBuilder<double>(
            valueListenable: progressNotifier,
            builder: (context, value, _) {
              String timeRemaining = '';
              if (value > 0.01) {
                final elapsed = stopwatch.elapsedMilliseconds;
                final estimated = elapsed / value * (1.0 - value);
                final remaining = Duration(milliseconds: estimated.round());
                timeRemaining = remaining.inSeconds < 60
                    ? '${remaining.inSeconds}s remaining'
                    : '${remaining.inMinutes}m ${remaining.inSeconds % 60}s remaining';
              }

              return ShadDialog(
                title: const Text('Updating firmware…'),
                description: timeRemaining.isNotEmpty
                    ? Text(timeRemaining)
                    : const Text('Estimating…'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShadProgress(value: value),
                      const SizedBox(height: 12),
                      Text('${(value * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );

    try {
      await widget.machine.updateFirmware(
        data,
        onProgress: (p) => progressNotifier.value = p,
      );
    } on FirmwareUpdateInProgressException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A firmware update is already in progress'),
          ),
        );
      }
      return;
    } catch (e) {
      stopwatch.stop();
      if (cancelled) return;
      if (mounted) {
        Navigator.of(context).pop();
        showShadDialog(
          context: context,
          builder: (context) => ShadDialog(
            title: const Text('Firmware update failed'),
            actions: [
              ShadButton(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
            child: Text(e.toString()),
          ),
        );
      }
      return;
    }

    stopwatch.stop();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  final TextEditingController _serialPayloadController =
      TextEditingController();
  final TextEditingController _serialCharacteristicController =
      TextEditingController();

  Widget _serialComms() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 8.0,
      children: [
        Text('Send raw command:'),
        Text('Characteristic (for BLE):'),
        ShadInput(
          controller: _serialCharacteristicController,
          placeholder: const Text('e.g. 0000ff01-...'),
        ),
        Text('Payload:'),
        ShadInput(
          controller: _serialPayloadController,
          placeholder: const Text('hex or ascii'),
        ),
        ShadButton(
          size: ShadButtonSize.sm,
          child: const Text('Send'),
          onPressed: () {
            widget.machine.sendRawMessage(
              De1RawMessage(
                type: De1RawMessageType.request,
                operation: De1RawOperationType.write,
                characteristicUUID: _serialCharacteristicController.text,
                payload: _serialPayloadController.text,
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _serialPayloadController.dispose();
    _serialCharacteristicController.dispose();
    super.dispose();
  }
}
