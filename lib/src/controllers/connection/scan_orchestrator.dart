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
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/errors.dart';

/// Outcome of [ScanOrchestrator.runScan].
///
/// `null` from the orchestrator means a catastrophic scan failure
/// (bluetoothPermissionDenied / scanFailed) — the orchestrator has
/// already emitted the sticky error and phase=idle on the status
/// stream; the coordinator should bail.
class ScanRunResult {
  /// Machines matched during the scan.
  final List<De1Interface> machines;

  /// Scales matched during the scan.
  final List<Scale> scales;

  /// The per-scan builder. The coordinator feeds connection-attempt
  /// results back into this before calling [emit].
  final ScanReportBuilder reportBuilder;

  const ScanRunResult({
    required this.machines,
    required this.scales,
    required this.reportBuilder,
  });
}

/// Runs one scan cycle and wires the EarlyConnectWatcher, the
/// `DeviceScanner.scanForDevices()` call, sticky-error clearing, and
/// the post-scan ScanReportBuilder seeding. The coordinator stays
/// responsible for applying the policy + emitting the final
/// ScanReport so status-emission ownership remains clear.
///
/// Extracted from ConnectionManager as part of comms-harden Phase 4
/// (roadmap items 15, 16).
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

  /// Publish `phase: scanning`, set up the early-connect watcher,
  /// run the scan, wait for early connects, and return a snapshot
  /// for the coordinator's policy stage.
  ///
  /// Returns `null` if the scan failed catastrophically — in that
  /// case this method has already emitted the classified error +
  /// `phase: idle` and the coordinator should bail without running
  /// the policy stage.
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

    _log.fine(
      'Scan complete: ${machines.length} machines, ${scales.length} scales',
    );

    return ScanRunResult(
      machines: machines,
      scales: scales,
      reportBuilder: reportBuilder,
    );
  }

  /// Classify an exception thrown by `scanForDevices()` into a
  /// ConnectionErrorKind, publish `phase: idle`, and emit the
  /// classified error. Preserves the pre-refactor "DO NOT REORDER"
  /// invariant (publish phase first so the gatekeeper strips any
  /// stale transient, then emit the new sticky error).
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
            affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
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

  /// Map a scan-start exception to a [ConnectionErrorKind]. Checks
  /// the exception type first (for the known [PermissionDeniedException]
  /// type); falls back to a lowercase substring match on the message
  /// so platforms that surface permission failures as generic
  /// exceptions still route to the right kind.
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
