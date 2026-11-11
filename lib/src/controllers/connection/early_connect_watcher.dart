import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';

class EarlyConnectWatcher {
  static final _log = Logger('EarlyConnectWatcher');

  final Stream<List<Device>> _deviceStream;
  final String? _preferredMachineId;
  final String? _preferredScaleId;
  final ScanReportBuilder _scanReport;
  final bool Function() _isMachineConnected;
  final bool Function() _isScaleConnected;
  final Future<void> Function(De1Interface, ScanReportBuilder)
  _connectMachineTracked;
  final Future<void> Function(Scale, ScanReportBuilder) _connectScaleTracked;
  final void Function() _onEarlyAttemptComplete;

  var _machineStarted = false;
  Future<void>? _machinePending;
  var _scaleStarted = false;
  Future<void>? _scalePending;
  StreamSubscription<List<Device>>? _sub;

  EarlyConnectWatcher({
    required this._deviceStream,
    required this._preferredMachineId,
    required this._preferredScaleId,
    required this._scanReport,
    required this._isMachineConnected,
    required this._isScaleConnected,
    required this._connectMachineTracked,
    required this._connectScaleTracked,
    required this._onEarlyAttemptComplete,
  });

  void start() {
    _sub = _deviceStream.skip(1).listen(_onDevicesUpdate);
  }

  void _onDevicesUpdate(List<Device> devices) {
    if (_preferredMachineId != null &&
        !_isMachineConnected() &&
        !_machineStarted) {
      final match = devices
          .whereType<De1Interface>()
          .where((m) => matchesDeviceIdentity(m, _preferredMachineId))
          .firstOrNull;
      if (match != null) {
        _log.fine('Preferred machine found during scan, connecting early');
        _machineStarted = true;
        _scanReport.seed(match);
        _machinePending = _connectMachineTracked(
          match,
          _scanReport,
        ).then((_) => _onEarlyAttemptComplete());
      }
    }

    if (_preferredScaleId != null && !_isScaleConnected() && !_scaleStarted) {
      final match = devices
          .whereType<Scale>()
          .where((s) => s.deviceId == _preferredScaleId)
          .firstOrNull;
      if (match != null) {
        _log.fine('Preferred scale found during scan, connecting early');
        _scaleStarted = true;
        _scanReport.seed(match);
        _scalePending = _connectScaleTracked(
          match,
          _scanReport,
        ).then((_) => _onEarlyAttemptComplete());
      }
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> awaitPending() async {
    if (_machinePending != null) {
      try {
        await _machinePending;
      } catch (e, st) {
        _log.fine('Early machine connect slipped past tracker', e, st);
      }
    }
    if (_scalePending != null) {
      try {
        await _scalePending;
      } catch (e, st) {
        _log.fine('Early scale connect slipped past tracker', e, st);
      }
    }
  }
}
