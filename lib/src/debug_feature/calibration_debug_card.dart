import 'package:flutter/material.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CalibrationDebugCard extends StatefulWidget {
  const CalibrationDebugCard({super.key, required this.machine});

  final De1Interface machine;

  @override
  State<CalibrationDebugCard> createState() => _CalibrationDebugCardState();
}

class _CalibrationDebugCardState extends State<CalibrationDebugCard>
    with AutomaticKeepAliveClientMixin {
  final _reportedControllers = {
    for (final target in De1CalibrationTarget.values)
      target: TextEditingController(),
  };
  final _measuredControllers = {
    for (final target in De1CalibrationTarget.values)
      target: TextEditingController(),
  };

  Map<De1CalibrationTarget, De1Calibration> _current = const {};
  Map<De1CalibrationTarget, De1Calibration> _factory = const {};
  Set<De1CalibrationTarget> _writing = const {};
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ShadCard(
      title: Row(
        children: [
          const Expanded(child: Text('Calibration')),
          Tooltip(
            message: 'Refresh calibration',
            child: ShadButton.ghost(
              size: ShadButtonSize.sm,
              onPressed: _loading || _writing.isNotEmpty ? null : _refreshAll,
              child: const Icon(LucideIcons.refreshCw, size: 16),
            ),
          ),
        ],
      ),
      child: _loading
          ? const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, target)
                    in De1CalibrationTarget.values.indexed) ...[
                  if (index > 0) const Divider(height: 24),
                  _buildTarget(target),
                ],
              ],
            ),
    );
  }

  Widget _buildTarget(De1CalibrationTarget target) {
    final current = _current[target];
    final factory = _factory[target];
    final busy = _writing.isNotEmpty;
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_targetLabel(target), style: theme.textTheme.small),
        const SizedBox(height: 6),
        Text(_valueLabel('Current', current), style: theme.textTheme.muted),
        Text(_valueLabel('Factory', factory), style: theme.textTheme.muted),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: _buildInput(
                label: 'Reported',
                controller: _reportedControllers[target]!,
                key: Key('calibration-reported-${target.name}'),
                enabled: !busy,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildInput(
                label: 'Measured',
                controller: _measuredControllers[target]!,
                key: Key('calibration-measured-${target.name}'),
                enabled: !busy,
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message:
                  'Write ${_targetLabel(target).toLowerCase()} calibration',
              child: ShadButton(
                key: Key('calibration-write-${target.name}'),
                size: ShadButtonSize.sm,
                onPressed: busy ? null : () => _write(target),
                child: _writing.contains(target)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.save, size: 16),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInput({
    required String label,
    required TextEditingController controller,
    required Key key,
    required bool enabled,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ShadTheme.of(context).textTheme.muted),
        const SizedBox(height: 4),
        ShadInput(
          key: key,
          controller: controller,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
        ),
      ],
    );
  }

  Future<void> _refreshAll() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final reads = await Future.wait([
        for (final target in De1CalibrationTarget.values)
          widget.machine.readCalibration(target),
        for (final target in De1CalibrationTarget.values)
          widget.machine.readCalibration(
            target,
            source: De1CalibrationSource.factory,
          ),
      ]);
      if (!mounted) return;
      final targetCount = De1CalibrationTarget.values.length;
      final current = {
        for (final value in reads.take(targetCount)) value.target: value,
      };
      final factory = {
        for (final value in reads.skip(targetCount)) value.target: value,
      };
      setState(() {
        _current = current;
        _factory = factory;
        _loading = false;
      });
      for (final value in current.values) {
        _setInputValues(value);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showFailure('Calibration read failed', error);
    }
  }

  Future<void> _write(De1CalibrationTarget target) async {
    final reported = double.tryParse(_reportedControllers[target]!.text);
    final measured = double.tryParse(_measuredControllers[target]!.text);
    if (reported == null ||
        measured == null ||
        !reported.isFinite ||
        !measured.isFinite) {
      _showStatus('Enter valid reported and measured values');
      return;
    }

    setState(() => _writing = {target});
    try {
      await widget.machine.writeCalibration(
        De1Calibration(
          target: target,
          de1ReportedValue: reported,
          measuredValue: measured,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _writing = const {});
      _showFailure('Calibration write failed', error);
      return;
    }

    try {
      final current = await widget.machine.readCalibration(target);
      if (!mounted) return;
      setState(() {
        _current = {..._current, target: current};
        _writing = const {};
      });
      _setInputValues(current);
      _showStatus('${_targetLabel(target)} calibration updated');
    } catch (error) {
      if (!mounted) return;
      setState(() => _writing = const {});
      _showFailure('Calibration refresh failed', error);
    }
  }

  void _setInputValues(De1Calibration calibration) {
    _reportedControllers[calibration.target]!.text = calibration.measuredValue
        .toString();
    _measuredControllers[calibration.target]!.text = calibration.measuredValue
        .toString();
  }

  void _showStatus(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFailure(String title, Object error) {
    showShadDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text(title),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
        child: Text(error.toString()),
      ),
    );
  }

  String _valueLabel(String source, De1Calibration? value) => value == null
      ? '$source: unavailable'
      : '$source: reported ${value.de1ReportedValue.toStringAsFixed(4)}, '
            'measured ${value.measuredValue.toStringAsFixed(4)}';

  String _targetLabel(De1CalibrationTarget target) => switch (target) {
    De1CalibrationTarget.flow => 'Flow',
    De1CalibrationTarget.pressure => 'Pressure',
    De1CalibrationTarget.temperature => 'Temperature',
  };

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final controller in _reportedControllers.values) {
      controller.dispose();
    }
    for (final controller in _measuredControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
