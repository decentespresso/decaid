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
  Timer? _retryTimer;
  double? _lastPushed;
  int? _lastPushedGeneration;
  double? _desired;
  int? _desiredGeneration;
  double? _inFlight;
  bool _pushing = false;
  bool _restartAfterDrain = false;
  bool _disposed = false;

  double? _currentTargetYield() =>
      _workflow.currentWorkflow.context?.targetYield;

  void _clearPending() {
    _desired = null;
    _desiredGeneration = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  void _onWorkflowChange() {
    final next = _currentTargetYield();
    final generation = _de1.connectionGeneration;
    if (next == null) {
      _log.fine('SAW write skipped — workflow carries no target yield');
      _clearPending();
      return;
    }
    if (next == _lastPushed &&
        _lastPushedGeneration == generation &&
        (_inFlight == null || _inFlight == next)) {
      _clearPending();
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
    _retryTimer?.cancel();
    _retryTimer = null;
    final target = _currentTargetYield();
    if (target == null) {
      _log.info(
        'SAW target absent from the workflow — firmware target left as is',
      );
      _clearPending();
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _desired = target;
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
        if (machine is! BengleInterface) {
          _log.fine('SAW write skipped — connected machine is not Bengle');
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
        } on De1WriteQueueFullException catch (e, st) {
          _log.warning('SAW write queue full', e, st);
          if (_isCurrent(machine, generation) &&
              _desired == grams &&
              _desiredGeneration == generation) {
            _scheduleRetry(grams, generation);
          }
          return;
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
      if (!_disposed &&
          restart &&
          _desired != null &&
          _de1.connectedDe1OrNull is BengleInterface) {
        unawaited(_drain());
      }
    }
  }

  void _scheduleRetry(double grams, int generation) {
    if (_retryTimer != null) return;
    _retryTimer = Timer(debounce, () {
      _retryTimer = null;
      if (!_disposed &&
          _desired == grams &&
          _desiredGeneration == generation &&
          _de1.connectedDe1OrNull is BengleInterface) {
        unawaited(_drain());
      }
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _workflow.removeListener(_onWorkflowChange);
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _desired = null;
    _desiredGeneration = null;
    _restartAfterDrain = false;
    await _de1Sub?.cancel();
    _de1Sub = null;
  }
}
