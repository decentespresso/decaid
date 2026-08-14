import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/errors.dart';

class BengleSawBridge {
  BengleSawBridge({
    required WorkflowController workflowController,
    required De1Controller de1Controller,
    this.debounce = const Duration(milliseconds: 250),
  }) : _workflow = workflowController,
       _de1 = de1Controller {
    _lastPushed = _currentTargetYield();
    _workflow.addListener(_onWorkflowChange);
    _de1Sub = _de1.de1.listen(_onDe1Change);
  }

  final WorkflowController _workflow;
  final De1Controller _de1;
  final Duration debounce;
  final Logger _log = Logger('BengleSawBridge');

  StreamSubscription<De1Interface?>? _de1Sub;
  Timer? _debounceTimer;
  double? _lastPushed;
  int? _lastPushedGeneration;
  double? _desired;
  int? _desiredGeneration;
  double? _inFlight;
  bool _pushing = false;
  bool _restartAfterDrain = false;
  bool _disposed = false;

  double _currentTargetYield() =>
      _workflow.currentWorkflow.context?.targetYield ?? 0.0;

  void _onWorkflowChange() {
    final next = _currentTargetYield();
    final generation = _de1.connectionGeneration;
    if (next == _lastPushed &&
        _lastPushedGeneration == generation &&
        (_inFlight == null || _inFlight == next)) {
      _desired = null;
      _desiredGeneration = null;
      _debounceTimer?.cancel();
      _debounceTimer = null;
      return;
    }
    _desired = next;
    _desiredGeneration = generation;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(_drain());
    });
  }

  void _onDe1Change(De1Interface? device) {
    if (device is! BengleInterface) {
      if (_pushing) _restartAfterDrain = true;
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _desired = _currentTargetYield();
    _desiredGeneration = _de1.connectionGeneration;
    if (_pushing) _restartAfterDrain = true;
    unawaited(_drain());
  }

  bool _isCurrent(De1Interface machine, int generation) =>
      identical(machine, _de1.connectedDe1OrNull) &&
      generation == _de1.connectionGeneration;

  Future<void> _drain() async {
    if (_pushing || _disposed) return;
    _pushing = true;
    try {
      while (!_disposed) {
        final grams = _desired;
        if (grams == null ||
            (grams == _lastPushed &&
                _desiredGeneration == _lastPushedGeneration)) {
          _desired = null;
          _desiredGeneration = null;
          return;
        }
        final machine = _de1.connectedDe1OrNull;
        if (machine is! BengleInterface ||
            !machine.supportsCurrentBengleFirmwareSurface) {
          _log.fine(
            'SAW write skipped — machine lacks the current Bengle surface',
          );
          return;
        }
        final generation = _de1.connectionGeneration;
        _inFlight = grams;
        try {
          await _de1.runDeviceWrite((device) async {
            if (identical(device, machine)) {
              await machine.setStopAtWeightTarget(grams);
            }
          });
          if (_disposed) return;
          if (!_isCurrent(machine, generation)) continue;
          _lastPushed = grams;
          _lastPushedGeneration = generation;
          if (_desired == grams && _desiredGeneration == generation) {
            _desired = null;
            _desiredGeneration = null;
          }
          _log.info('SAW target written: ${grams}g');
        } on DeviceNotConnectedException {
          _log.fine('SAW write aborted — machine disconnected mid-call');
          if (!_isCurrent(machine, generation) ||
              _desired != grams ||
              _desiredGeneration != generation) {
            continue;
          }
          return;
        } catch (e, st) {
          _log.warning('SAW write failed', e, st);
          if (!_isCurrent(machine, generation) ||
              _desired != grams ||
              _desiredGeneration != generation) {
            continue;
          }
          return;
        } finally {
          _inFlight = null;
        }
      }
    } finally {
      final restart = _restartAfterDrain;
      _restartAfterDrain = false;
      _pushing = false;
      final machine = _de1.connectedDe1OrNull;
      if (!_disposed &&
          restart &&
          _desired != null &&
          machine is BengleInterface &&
          machine.supportsCurrentBengleFirmwareSurface) {
        unawaited(_drain());
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _workflow.removeListener(_onWorkflowChange);
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _desired = null;
    _desiredGeneration = null;
    _restartAfterDrain = false;
    await _de1Sub?.cancel();
    _de1Sub = null;
  }
}
