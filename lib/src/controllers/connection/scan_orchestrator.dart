import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/early_connect_watcher.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart'
    show ConnectionPhase, TransportCondition;
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/errors.dart';

class ScanRunResult {
  final List<De1Interface> machines;

  final List<Scale> scales;

  final List<Grinder> grinders;

  final ScanReportBuilder reportBuilder;

  const ScanRunResult({
    required this.machines,
    required this.scales,
    this.grinders = const [],
    required this.reportBuilder,
  });
}

class ScanOrchestrator {
  static final _log = Logger('ScanOrchestrator');

  final DeviceScanner _scanner;
  final StatusPublisher _statusPublisher;
  final Future<void> Function(De1Interface, ScanReportBuilder)
  _connectMachineTracked;
  final Future<void> Function(Scale, ScanReportBuilder) _connectScaleTracked;
  final bool Function() _isMachineConnected;
  final bool Function() _isScaleConnected;

  ScanOrchestrator({
    required DeviceScanner scanner,
    required StatusPublisher statusPublisher,
    required Future<void> Function(De1Interface, ScanReportBuilder)
    connectMachineTracked,
    required Future<void> Function(Scale, ScanReportBuilder)
    connectScaleTracked,
    required bool Function() isMachineConnected,
    required bool Function() isScaleConnected,
  }) : _scanner = scanner,
       _statusPublisher = statusPublisher,
       _connectMachineTracked = connectMachineTracked,
       _connectScaleTracked = connectScaleTracked,
       _isMachineConnected = isMachineConnected,
       _isScaleConnected = isScaleConnected;

  Future<ScanRunResult?> runScan({
    required String? preferredMachineId,
    required String? preferredScaleId,
    required bool earlyStopEnabled,
    required void Function() onEarlyAttemptComplete,
    required DateTime scanStartTime,
    ScanFilter? scaleFilter,
  }) async {
    final reportBuilder = ScanReportBuilder(scanStartTime: scanStartTime)
      ..recordAdapterStateAtStart(_scanner.currentAdapterState);

    _statusPublisher.publish(
      _statusPublisher.current.copyWith(
        phase: ConnectionPhase.scanning,
        pendingAmbiguity: () => null,
      ),
    );

    final earlyConnect = EarlyConnectWatcher(
      deviceStream: _scanner.deviceStream,
      preferredMachineId: preferredMachineId,
      preferredScaleId: preferredScaleId,
      scanReport: reportBuilder,
      isMachineConnected: _isMachineConnected,
      isScaleConnected: _isScaleConnected,
      connectMachineTracked: _connectMachineTracked,
      connectScaleTracked: _connectScaleTracked,
      onEarlyAttemptComplete: onEarlyAttemptComplete,
    );
    earlyConnect.start();

    final ScanResult scanResult;
    try {
      scanResult = await _scanner.scanForDevices(filter: scaleFilter);
    } catch (e) {
      earlyConnect.stop();
      _emitScanStartError(e);
      return null;
    }
    earlyConnect.stop();
    reportBuilder.recordScanDuration(scanResult.duration);

    _clearStickyScanError();

    await earlyConnect.awaitPending();

    final allDevices = scanResult.matchedDevices;
    for (final d in allDevices) {
      reportBuilder.seed(d);
    }

    final machines = allDevices.whereType<De1Interface>().toList();
    final scales = allDevices.whereType<Scale>().toList();
    final grinders = allDevices.whereType<Grinder>().toList();

    _log.fine(
      'Scan complete: ${machines.length} machines, ${scales.length} scales, '
      '${grinders.length} grinders',
    );

    return ScanRunResult(
      machines: machines,
      scales: scales,
      grinders: grinders,
      reportBuilder: reportBuilder,
    );
  }

  void _emitScanStartError(Object e) {
    final kind = _classifyScanError(e);
    _statusPublisher.publish(
      _statusPublisher.current.copyWith(phase: ConnectionPhase.idle),
    );
    final error = ConnectionError(
      kind: kind,
      severity: ConnectionErrorSeverity.error,
      timestamp: DateTime.now().toUtc(),
      message: kind == ConnectionErrorKind.bluetoothPermissionDenied
          ? 'Bluetooth permission was denied.'
          : 'Failed to start Bluetooth scan.',
      suggestion: kind == ConnectionErrorKind.bluetoothPermissionDenied
          ? 'Grant Bluetooth permission in system settings and retry.'
          : 'Check that Bluetooth is enabled and retry.',
      details: {'exception': e.toString()},
    );
    _statusPublisher.publish(
      _statusPublisher.current.copyWith(
        conditions: [
          ..._statusPublisher.current.conditions.where(
            (condition) => condition.transportType != TransportType.ble,
          ),
          TransportCondition(
            transportType: TransportType.ble,
            affectedDeviceTypes: const {
              DeviceType.machine,
              DeviceType.scale,
              DeviceType.grinder,
            },
            connectionError: error,
          ),
        ],
      ),
    );
    _statusPublisher.emitError(error);
  }

  void _clearStickyScanError() {
    final prevErr = _statusPublisher.current.error;
    if (prevErr != null &&
        (prevErr.kind == ConnectionErrorKind.scanFailed ||
            prevErr.kind == ConnectionErrorKind.bluetoothPermissionDenied)) {
      _statusPublisher.publish(
        _statusPublisher.current.copyWith(
          conditions: _statusPublisher.current.conditions
              .where(
                (condition) =>
                    condition.connectionError.kind !=
                        ConnectionErrorKind.scanFailed &&
                    condition.connectionError.kind !=
                        ConnectionErrorKind.bluetoothPermissionDenied,
              )
              .toList(),
        ),
      );
      _statusPublisher.clearError();
    }
  }

  static String _classifyScanError(Object e) {
    if (e is PermissionDeniedException) {
      return ConnectionErrorKind.bluetoothPermissionDenied;
    }
    final msg = e.toString().toLowerCase();
    if (msg.contains('permission')) {
      return ConnectionErrorKind.bluetoothPermissionDenied;
    }
    return ConnectionErrorKind.scanFailed;
  }
}
