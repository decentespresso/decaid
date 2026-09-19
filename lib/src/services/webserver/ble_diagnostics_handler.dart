import 'dart:async';

import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

final Stopwatch _bleDiagnosticsClock = Stopwatch()..start();

class BleDiagnosticsHandler {
  final DeviceController deviceController;
  final ConnectionManager connectionManager;
  final SettingsController settingsController;
  final Duration deviceStateProbeTimeout;
  final Duration serviceDiagnosticsWaitTimeout;

  Future<List<Map<String, Object?>>>? _servicesDiagnosticsInFlight;
  List<Map<String, Object?>> _lastServicesDiagnostics = const [];
  DateTime? _lastServicesDiagnosticsAt;

  BleDiagnosticsHandler({
    required this.deviceController,
    required this.connectionManager,
    required this.settingsController,
    this.deviceStateProbeTimeout = const Duration(milliseconds: 250),
    this.serviceDiagnosticsWaitTimeout = const Duration(milliseconds: 500),
  });

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/diagnostics/ble', _handleGet);
  }

  Future<Response> _handleGet(Request request) async {
    final sampleStartedAt = DateTime.now().toUtc();
    final sampleStartedMonotonicMs =
        _bleDiagnosticsClock.elapsedMicroseconds ~/ 1000;
    final servicesFuture = _serviceDiagnosticsSnapshot();
    final peersFuture = _deviceSnapshots();

    final services = await servicesFuture;
    final peers = await peersFuture;
    final status = connectionManager.currentStatus;
    final sampledAt = DateTime.now().toUtc();
    final monotonicMs = _bleDiagnosticsClock.elapsedMicroseconds ~/ 1000;

    return jsonOk({
      'diagnosticsVersion': 2,
      'timestamp': sampledAt.toIso8601String(),
      'monotonicMs': monotonicMs,
      'sampling': {
        'startedAt': sampleStartedAt.toIso8601String(),
        'startedMonotonicMs': sampleStartedMonotonicMs,
        'completedAt': sampledAt.toIso8601String(),
        'completedMonotonicMs': monotonicMs,
      },
      'ble': {
        'adapterState': deviceController.currentAdapterState.name,
        'services': services.services,
        'servicesDiagnostics': {
          'complete': services.complete,
          'sampledAt': services.sampledAt?.toIso8601String(),
        },
      },
      'connection': {
        'phase': status.phase.name,
        'intent': status.intent.name,
        'pendingAmbiguity': status.pendingAmbiguity?.name,
        'activeTargetTransport': status.activeTargetTransport?.name,
        'preferredMachineId': settingsController.preferredMachineId,
        'preferredScaleId': settingsController.preferredScaleId,
        'scalePowerMode': settingsController.scalePowerMode.name,
        'shouldRetryPreferredScale':
            connectionManager.shouldRetryPreferredScale,
        'scaleReconnectBlockedByPowerMode':
            connectionManager.scaleReconnectBlockedByPowerMode,
        'scaleReconnectFailures': connectionManager.scaleReconnectFailures,
        'scaleReconnectScheduled': connectionManager.scaleReconnectScheduled,
        'scaleWatch': connectionManager.scaleWatchDiagnostics,
        'stateWatchdogActive': connectionManager.stateWatchdogActive,
        'snapshotStalenessReconnects':
            connectionManager.diagnosticSnapshotStalenessReconnects,
        if (status.error != null) 'error': status.error!.toJson(),
        'conditions': [
          for (final condition in status.conditions)
            {
              'transport': condition.transportType.name,
              'affectedDeviceTypes': condition.affectedDeviceTypes
                  .map((type) => type.name)
                  .toList(growable: false),
              'error': condition.connectionError.toJson(),
            },
        ],
        'peers': peers,
      },
    });
  }

  Future<
    ({List<Map<String, Object?>> services, bool complete, DateTime? sampledAt})
  >
  _serviceDiagnosticsSnapshot() async {
    final future =
        _servicesDiagnosticsInFlight ?? _startServiceDiagnosticsCollection();
    try {
      final services = await future.timeout(serviceDiagnosticsWaitTimeout);
      return (
        services: services,
        complete: true,
        sampledAt: _lastServicesDiagnosticsAt,
      );
    } on TimeoutException {
      return (
        services: _lastServicesDiagnostics,
        complete: false,
        sampledAt: _lastServicesDiagnosticsAt,
      );
    }
  }

  Future<List<Map<String, Object?>>> _startServiceDiagnosticsCollection() {
    late final Future<List<Map<String, Object?>>> future;
    future = deviceController
        .bleDiagnostics()
        .then((services) {
          final snapshot = List<Map<String, Object?>>.unmodifiable(services);
          _lastServicesDiagnostics = snapshot;
          _lastServicesDiagnosticsAt = DateTime.now().toUtc();
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_servicesDiagnosticsInFlight, future)) {
            _servicesDiagnosticsInFlight = null;
          }
        });
    _servicesDiagnosticsInFlight = future;
    return future;
  }

  Future<List<Map<String, Object?>>> _deviceSnapshots() async {
    final devices = deviceController.devices.toList(growable: false);
    return Future.wait(
      devices.map((device) async {
        ConnectionState? state;
        try {
          state = await device.connectionState
              .timeout(deviceStateProbeTimeout)
              .first;
        } catch (_) {}

        final information = device is DeviceInformationCapable
            ? (device as DeviceInformationCapable).currentDeviceInformation
            : null;

        return <String, Object?>{
          'deviceId': device.deviceId,
          'name': device.name,
          'type': device.type.name,
          'transport': device.transportType.name,
          'instanceId': identityHashCode(device),
          'state': state?.name,
          if (device is DeviceDiagnosticsCapable)
            'diagnostics':
                (device as DeviceDiagnosticsCapable).connectionDiagnostics,
          if (information != null && !information.isEmpty)
            'information': information.toJson(),
        };
      }),
    );
  }
}
